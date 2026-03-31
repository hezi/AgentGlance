import Foundation
import os

private let logger = Logger(subsystem: "app.agentglance", category: "SessionManager")

@Observable
@MainActor
final class SessionManager {
    private(set) var sessions: [String: Session] = [:]
    private var cleanupTimers: [String: Timer] = [:]

    var onStateChange: ((Session, SessionState) -> Void)?
    /// Called when a non-permission event arrives for a session that has pending decisions.
    /// AppState wires this to HookServer to flush stale pending decisions.
    var onStalePendingDecisions: ((String) -> Void)?

    var activeSessions: [Session] {
        sessions.values
            .filter { $0.state != .complete }
            .sorted { lhs, rhs in
                let lp = Self.statePriority(lhs.state)
                let rp = Self.statePriority(rhs.state)
                if lp != rp { return lp < rp }
                return lhs.lastActivity > rhs.lastActivity
            }
    }

    var allSessions: [Session] {
        sessions.values.sorted { lhs, rhs in
            let lp = Self.statePriority(lhs.state)
            let rp = Self.statePriority(rhs.state)
            if lp != rp { return lp < rp }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    /// Lower = higher priority for display ordering
    private static func statePriority(_ state: SessionState) -> Int {
        switch state {
        case .awaitingApproval: 0
        case .working: 1
        case .ready: 2
        case .idle: 3
        case .complete: 4
        }
    }

    var hasWorkingSessions: Bool {
        sessions.values.contains { $0.state == .working }
    }

    var hasActiveSessionsNeedingAttention: Bool {
        sessions.values.contains { $0.state == .ready || $0.state == .awaitingApproval }
    }

    /// Bootstrap sessions from already-running Claude Code processes
    func bootstrapFromRunningProcesses() {
        let detected = ProcessScanner.detectRunningSessions()
        for info in detected {
            guard sessions[info.sessionId] == nil else { continue }

            let session = Session(id: info.sessionId, cwd: info.cwd)
            session.name = info.name
                ?? ProcessScanner.readTranscriptTitle(sessionId: info.sessionId, cwd: info.cwd)
            session.startTime = Date(timeIntervalSince1970: TimeInterval(info.startedAt) / 1000)
            session.state = .idle
            session.processPID = info.pid
            session.tty = ProcessScanner.getTTY(pid: info.pid)
            session.terminalBundleId = ProcessScanner.getTerminalApp(pid: info.pid)
            sessions[info.sessionId] = session

            logger.info("Bootstrapped session: \(session.name ?? info.sessionId) tty=\(session.tty ?? "?") terminal=\(session.terminalBundleId ?? "?")")
        }

        if !detected.isEmpty {
            onStateChange?(detected.compactMap { sessions[$0.sessionId] }.first!, .idle)
        }
    }

    func handleEvent(_ event: HookPayload) {
        guard let eventType = HookEventType(rawValue: event.hook_event_name) else {
            logger.warning("Unknown event type: \(event.hook_event_name)")
            return
        }

        logger.info("Event: \(event.hook_event_name) session=\(event.session_id)")

        // If a "forward progress" event arrives for a session with pending decisions,
        // those decisions are stale (user handled it in the TUI, or curl timed out).
        // Only flush on events that prove the permission was already resolved:
        let flushEvents: Set<HookEventType> = [.PostToolUse, .Stop, .UserPromptSubmit, .SessionEnd]
        if flushEvents.contains(eventType) {
            onStalePendingDecisions?(event.session_id)
        }

        switch eventType {
        case .SessionStart:
            handleSessionStart(event)
        case .SessionEnd:
            handleSessionEnd(event)
        case .PreToolUse:
            handlePreToolUse(event)
        case .PostToolUse:
            handlePostToolUse(event)
        case .Stop:
            handleStop(event)
        case .Notification:
            handleNotification(event)
        case .PermissionRequest:
            handlePermissionRequest(event)
        case .UserPromptSubmit:
            handleUserPromptSubmit(event)
        }
    }

    private func getOrCreateSession(_ event: HookPayload) -> Session {
        logger.info("[match] getOrCreateSession hook_sid=\(event.session_id) cwd=\(event.cwd) event=\(event.hook_event_name)")

        if let existing = sessions[event.session_id] {
            existing.lastActivity = Date()
            existing.cwd = event.cwd
            if let mode = event.permission_mode { existing.permissionMode = mode }
            // Retry enrichment if missing terminal info or name, but throttle to avoid
            // scanning session files on every event (at most once per 30 seconds)
            if existing.processPID == nil || existing.name == nil {
                let now = Date()
                if existing.lastEnrichmentAttempt == nil ||
                    now.timeIntervalSince(existing.lastEnrichmentAttempt!) > 30 {
                    existing.lastEnrichmentAttempt = now
                    logger.info("[match] found existing session, retrying enrichment (name=\(existing.name ?? "<nil>") pid=\(existing.processPID.map(String.init) ?? "<nil>"))")
                    enrichFromSessionFiles(existing)
                }
            }
            return existing
        }

        // Check if there's a bootstrapped session that matches this hook event.
        // The sessionId from ~/.claude/sessions/*.json often differs from the hook's
        // session_id, and the cwd may differ too (session file has launch dir,
        // hook has project dir). Match by: name, cwd containment, or same leaf dir.
        // Only consider sessions that haven't received any hook events yet (toolCount == 0)
        // to avoid stealing an already-active session.
        let candidates = sessions.values.filter { $0.toolCount == 0 }
        logger.info("[match] no existing session, checking \(candidates.count) bootstrap candidates: \(candidates.map { "\($0.id.prefix(8))… name=\($0.name ?? "<nil>") cwd=\($0.cwd)" }.joined(separator: ", "))")

        let hookProject = (event.cwd as NSString).lastPathComponent

        // Prioritized passes: most specific match first
        let bootstrapped: Session? = {
            // Pass 1: exact cwd match (most specific)
            let exactCwd = candidates.filter { $0.cwd == event.cwd }
            if exactCwd.count == 1 {
                logger.info("[match] ✓ exact cwd match → \(exactCwd[0].id.prefix(8))…")
                return exactCwd[0]
            } else if exactCwd.count > 1 {
                logger.info("[match] ambiguous: \(exactCwd.count) candidates with exact cwd, skipping")
            }

            // Pass 2: session name matches hook's project directory
            let nameMatch = candidates.filter { $0.name != nil && $0.name == hookProject }
            if nameMatch.count == 1 {
                logger.info("[match] ✓ name match → \(nameMatch[0].id.prefix(8))… name=\(nameMatch[0].name ?? "")")
                return nameMatch[0]
            } else if nameMatch.count > 1 {
                logger.info("[match] ambiguous: \(nameMatch.count) candidates with name '\(hookProject)', skipping")
            }

            // Pass 3: hook cwd is inside bootstrapped session's cwd (least specific)
            let parentMatch = candidates.filter { event.cwd.hasPrefix($0.cwd + "/") }
            if parentMatch.count == 1 {
                logger.info("[match] ✓ parent cwd match → \(parentMatch[0].id.prefix(8))… cwd=\(parentMatch[0].cwd)")
                return parentMatch[0]
            } else if parentMatch.count > 1 {
                // Multiple parent matches — prefer the most specific (longest cwd)
                let best = parentMatch.max(by: { $0.cwd.count < $1.cwd.count })!
                let tied = parentMatch.filter { $0.cwd.count == best.cwd.count }
                if tied.count == 1 {
                    logger.info("[match] ✓ best parent cwd match → \(best.id.prefix(8))… cwd=\(best.cwd)")
                    return best
                }
                logger.info("[match] ambiguous: \(parentMatch.count) parent cwd matches, skipping")
            }

            return nil
        }()

        if let bootstrapped {
            // Re-key the bootstrapped session with the hook's session_id
            logger.info("[match] ✓ merged bootstrap \(bootstrapped.id.prefix(8))… → hook sid \(event.session_id.prefix(8))… name=\(bootstrapped.name ?? "<nil>") pid=\(bootstrapped.processPID.map(String.init) ?? "<nil>")")
            sessions.removeValue(forKey: bootstrapped.id)
            let merged = Session(id: event.session_id, cwd: event.cwd)
            merged.name = bootstrapped.name
            merged.startTime = bootstrapped.startTime
            merged.lastActivity = Date()
            // Carry over terminal info from bootstrapped session
            merged.processPID = bootstrapped.processPID
            merged.tty = bootstrapped.tty
            merged.terminalBundleId = bootstrapped.terminalBundleId
            merged.permissionMode = event.permission_mode
            sessions[event.session_id] = merged
            return merged
        }

        logger.info("[match] no bootstrap match, creating new session")
        let session = Session(id: event.session_id, cwd: event.cwd)
        session.permissionMode = event.permission_mode
        enrichFromSessionFiles(session)
        sessions[event.session_id] = session
        return session
    }

    /// Try to find terminal info and name for a session by scanning session files
    private func enrichFromSessionFiles(_ session: Session) {
        let needsTerminal = session.processPID == nil
        let needsName = session.name == nil
        guard needsTerminal || needsName else {
            logger.info("[enrich] skip session \(session.id.prefix(8))… — already has terminal=\(!needsTerminal) name=\(!needsName)")
            return
        }

        logger.info("[enrich] session \(session.id.prefix(8))… needs: \(needsTerminal ? "terminal " : "")\(needsName ? "name" : "") | cwd=\(session.cwd)")

        let detected = ProcessScanner.detectRunningSessions()
        logger.info("[enrich] found \(detected.count) running session files: \(detected.map { "pid=\($0.pid) sid=\($0.sessionId.prefix(8))… name=\($0.name ?? "<nil>") cwd=\($0.cwd)" }.joined(separator: ", "))")

        // PIDs already claimed by other tracked sessions — exclude from fuzzy matching
        let claimedPIDs = Set(sessions.values.compactMap { s -> Int? in
            guard s.id != session.id else { return nil }
            return s.processPID
        })
        let unclaimed = detected.filter { !claimedPIDs.contains($0.pid) }
        if claimedPIDs.count > 0 {
            logger.info("[enrich] claimed PIDs: \(claimedPIDs.sorted()) → \(unclaimed.count) unclaimed session files")
        }

        // Exact sessionId match is always safe (use full list)
        if let m = detected.first(where: { $0.sessionId == session.id }) {
            logger.info("[enrich] ✓ exact sessionId match → pid=\(m.pid) name=\(m.name ?? "<nil>")")
            applyEnrichment(session, from: m, needsTerminal: needsTerminal, needsName: needsName)
            return
        }
        logger.info("[enrich] no exact sessionId match")

        // Fuzzy matches only consider unclaimed session files
        if let m = unclaimed.first(where: { session.cwd.hasPrefix($0.cwd) }) {
            logger.info("[enrich] ✓ cwd prefix match → pid=\(m.pid) name=\(m.name ?? "<nil>") file_cwd=\(m.cwd)")
            applyEnrichment(session, from: m, needsTerminal: needsTerminal, needsName: needsName)
            return
        }

        let leaf = (session.cwd as NSString).lastPathComponent
        if let m = unclaimed.first(where: { $0.name != nil && leaf == $0.name }) {
            logger.info("[enrich] ✓ leaf name match → pid=\(m.pid) name=\(m.name ?? "<nil>") leaf=\(leaf)")
            applyEnrichment(session, from: m, needsTerminal: needsTerminal, needsName: needsName)
            return
        }

        logger.info("[enrich] ✗ no match found for session \(session.id.prefix(8))…")
    }

    private func applyEnrichment(_ session: Session, from match: ClaudeSessionInfo, needsTerminal: Bool, needsName: Bool) {
        if needsTerminal {
            session.processPID = match.pid
            session.tty = ProcessScanner.getTTY(pid: match.pid)
            session.terminalBundleId = ProcessScanner.getTerminalApp(pid: match.pid)
            logger.info("[enrich] set terminal: pid=\(match.pid) tty=\(session.tty ?? "<nil>") terminal=\(session.terminalBundleId ?? "<nil>")")
        }
        if needsName, let name = match.name {
            session.name = name
            logger.info("[enrich] set name: '\(name)' (from session file)")
        } else if needsName {
            // Fallback: read custom-title from the JSONL transcript
            if let title = ProcessScanner.readTranscriptTitle(sessionId: session.id, cwd: session.cwd) {
                session.name = title
                logger.info("[enrich] set name: '\(title)' (from transcript)")
            } else {
                logger.info("[enrich] no name found (session file or transcript)")
            }
        }
    }

    private func handleSessionStart(_ event: HookPayload) {
        cancelCleanup(for: event.session_id)
        let session = getOrCreateSession(event)
        session.pendingToolSummary = nil
        transition(session, to: .idle)
    }

    private func handleSessionEnd(_ event: HookPayload) {
        guard let session = sessions[event.session_id] else { return }
        session.pendingToolSummary = nil
        transition(session, to: .complete)
        scheduleCleanup(for: event.session_id)
    }

    private func handleUserPromptSubmit(_ event: HookPayload) {
        let session = getOrCreateSession(event)
        session.currentTool = nil
        session.pendingToolSummary = nil
        transition(session, to: .working)
    }

    private func handlePreToolUse(_ event: HookPayload) {
        let session = getOrCreateSession(event)
        session.currentTool = event.tool_name
        session.toolCount += 1
        session.pendingToolSummary = Self.extractToolSummary(
            toolName: event.tool_name,
            toolInput: event.tool_input
        )
        logger.info("PreToolUse: tool=\(event.tool_name ?? "?") summary=\(session.pendingToolSummary ?? "nil")")
        transition(session, to: .working)
    }

    private func handlePostToolUse(_ event: HookPayload) {
        let session = getOrCreateSession(event)
        // Keep currentTool and pendingToolSummary visible until the next
        // PreToolUse or Stop event — clearing immediately causes URLs and
        // search queries to flash too briefly to see or click.
        session.lastActivity = Date()
    }

    private func handleStop(_ event: HookPayload) {
        let session = getOrCreateSession(event)
        session.currentTool = nil
        session.pendingToolSummary = nil
        transition(session, to: .ready)
    }

    private func handlePermissionRequest(_ event: HookPayload) {
        let session = getOrCreateSession(event)
        if let toolName = event.tool_name {
            session.currentTool = toolName
            session.pendingToolSummary = Self.extractToolSummary(
                toolName: toolName,
                toolInput: event.tool_input
            ) ?? session.pendingToolSummary
        }

        // Special handling for ExitPlanMode: find and preview the plan file
        if event.tool_name == "ExitPlanMode" {
            session.currentTool = "ExitPlanMode"
            let (preview, full, path) = Self.findLatestPlan()
            session.pendingPlanPreview = preview
            session.pendingPlanFull = full
            session.pendingPlanPath = path
            session.pendingToolSummary = nil
        } else {
            session.pendingPlanPreview = nil
            session.pendingPlanPath = nil
        }

        // Always force update — a PendingDecision was just created, so the UI
        // needs to refresh even if the state was already .awaitingApproval
        // (e.g. Notification(permission_prompt) arrived first)
        session.state = .awaitingApproval
        session.lastActivity = Date()
        onStateChange?(session, .awaitingApproval)
    }

    private func handleNotification(_ event: HookPayload) {
        let session = getOrCreateSession(event)

        if event.notification_type == "permission_prompt" {
            // Fallback: also catch permission prompts from Notification events
            transition(session, to: .awaitingApproval)
        } else {
            onStateChange?(session, session.state)
        }
    }

    private func transition(_ session: Session, to newState: SessionState) {
        let oldState = session.state
        guard oldState != newState else { return }
        session.state = newState
        session.lastActivity = Date()
        onStateChange?(session, newState)
    }

    // MARK: - Plan Detection

    /// Find the most recently modified plan file and return preview, full content, and path
    nonisolated static func findLatestPlan() -> (preview: String?, full: String?, path: String?) {
        let plansDir = NSString("~/.claude/plans").expandingTildeInPath
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(atPath: plansDir) else { return (nil, nil, nil) }

        var latestPath: String?
        var latestDate: Date = .distantPast

        for file in files where file.hasSuffix(".md") {
            let path = (plansDir as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date,
               modified > latestDate {
                latestDate = modified
                latestPath = path
            }
        }

        guard let path = latestPath,
              let data = fm.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return (nil, nil, nil)
        }

        // Strip frontmatter for display
        let lines = content.components(separatedBy: .newlines)
        var contentLines: [String] = []
        var inFrontmatter = false

        for line in lines {
            if contentLines.isEmpty && line.trimmingCharacters(in: .whitespaces) == "---" {
                inFrontmatter = !inFrontmatter
                continue
            }
            if inFrontmatter { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && contentLines.isEmpty { continue }
            contentLines.append(line)
        }

        let full = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = contentLines.prefix(15).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return (preview.isEmpty ? nil : preview, full.isEmpty ? nil : full, path)
    }

    // MARK: - Tool Summary Extraction

    /// Extracts a human-readable summary from tool_input for display in the notch
    nonisolated static func extractToolSummary(toolName: String?, toolInput: JSONValue?) -> String? {
        guard let toolName, let toolInput else { return nil }

        switch toolName {
        case "Bash":
            if case .object(let obj) = toolInput, case .string(let cmd) = obj["command"] {
                let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                // Truncate long commands
                if trimmed.count > 80 {
                    return String(trimmed.prefix(77)) + "..."
                }
                return trimmed
            }

        case "Edit":
            if case .object(let obj) = toolInput, case .string(let path) = obj["file_path"] {
                return shortenPath(path)
            }

        case "Write":
            if case .object(let obj) = toolInput, case .string(let path) = obj["file_path"] {
                return shortenPath(path)
            }

        case "Read":
            if case .object(let obj) = toolInput, case .string(let path) = obj["file_path"] {
                return shortenPath(path)
            }

        case "Glob":
            if case .object(let obj) = toolInput, case .string(let pattern) = obj["pattern"] {
                return pattern
            }

        case "Grep":
            if case .object(let obj) = toolInput, case .string(let pattern) = obj["pattern"] {
                return "grep: \(pattern)"
            }

        case "WebFetch":
            if case .object(let obj) = toolInput, case .string(let url) = obj["url"] {
                return url
            }

        case "WebSearch":
            if case .object(let obj) = toolInput, case .string(let query) = obj["query"] {
                return query
            }

        case "Agent":
            if case .object(let obj) = toolInput, case .string(let desc) = obj["description"] {
                return desc
            }

        case "AskUserQuestion":
            if case .object(let obj) = toolInput, case .string(let question) = obj["question"] {
                return question
            }

        default:
            break
        }

        return nil
    }

    private nonisolated static func shortenPath(_ path: String) -> String {
        let components = (path as NSString).pathComponents
        if components.count <= 3 {
            return path
        }
        // Show .../<last 2 components>
        let last = components.suffix(2).joined(separator: "/")
        return ".../" + last
    }

    // MARK: - Cleanup

    private func scheduleCleanup(for sessionId: String) {
        cleanupTimers[sessionId]?.invalidate()
        cleanupTimers[sessionId] = Timer.scheduledTimer(
            withTimeInterval: Constants.completeFadeDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sessions.removeValue(forKey: sessionId)
                self?.cleanupTimers.removeValue(forKey: sessionId)
            }
        }
    }

    private func cancelCleanup(for sessionId: String) {
        cleanupTimers[sessionId]?.invalidate()
        cleanupTimers.removeValue(forKey: sessionId)
    }
}
