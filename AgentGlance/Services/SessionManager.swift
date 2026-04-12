import Foundation
import os

private let logger = Logger(subsystem: "app.agentglance", category: "SessionManager")

@Observable
@MainActor
final class SessionManager {
    private(set) var sessions: [String: Session] = [:]
    private var cleanupTimers: [String: Timer] = [:]
    private var livenessTimer: Timer?

    var onStateChange: ((Session, SessionState) -> Void)?
    /// Called when a non-permission event arrives for a session that has pending decisions.
    /// AppState wires this to HookServer to flush stale pending decisions.
    var onStalePendingDecisions: ((String) -> Void)?

    /// When true, only show sessions with "ss-" prefix IDs (screenshot test sessions)
    var screenshotMode = false

    private static let screenshotPrefix = "ss-"

    var activeSessions: [Session] {
        sessions.values
            .filter { $0.state != .complete }
            .filter { !screenshotMode || $0.id.hasPrefix(Self.screenshotPrefix) }
            .sorted { lhs, rhs in
                let lp = Self.statePriority(lhs.state)
                let rp = Self.statePriority(rhs.state)
                if lp != rp { return lp < rp }
                return lhs.lastActivity > rhs.lastActivity
            }
    }

    var allSessions: [Session] {
        sessions.values
            .filter { !screenshotMode || $0.id.hasPrefix(Self.screenshotPrefix) }
            .sorted { lhs, rhs in
                let lp = Self.statePriority(lhs.state)
                let rp = Self.statePriority(rhs.state)
                if lp != rp { return lp < rp }
                return lhs.lastActivity > rhs.lastActivity
            }
    }

    /// Remove all screenshot test sessions
    func clearScreenshotSessions() {
        let ssKeys = sessions.keys.filter { $0.hasPrefix(Self.screenshotPrefix) }
        for key in ssKeys { sessions.removeValue(forKey: key) }
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
        // Stage 0: Direct match by hook session_id (canonical, most common path)
        if let existing = sessions[event.session_id] {
            existing.lastActivity = Date()
            if !event.cwd.isEmpty { existing.cwd = event.cwd }
            if let mode = event.permission_mode { existing.permissionMode = mode }
            if let name = event.session_name, !name.isEmpty { existing.name = name }
            applyBridgeEnrichment(session: existing, event: event)
            refreshTranscriptData(for: existing)
            return existing
        }

        // Stage 1: Check for a bootstrap session with exact same cwd (pre-hook session)
        let bootstrapped = sessions.values.first { $0.toolCount == 0 && $0.cwd == event.cwd }

        if let bootstrapped {
            logger.info("[match] merged bootstrap \(bootstrapped.id.prefix(8))… → \(event.session_id.prefix(8))…")
            sessions.removeValue(forKey: bootstrapped.id)
            let merged = Session(id: event.session_id, cwd: event.cwd)
            merged.name = event.session_name ?? bootstrapped.name
            merged.startTime = bootstrapped.startTime
            merged.lastActivity = Date()
            merged.processPID = bootstrapped.processPID
            merged.tty = bootstrapped.tty
            merged.terminalBundleId = bootstrapped.terminalBundleId
            merged.permissionMode = event.permission_mode
            applyBridgeEnrichment(session: merged, event: event)
            sessions[event.session_id] = merged
            persistSessionTerminals()
            return merged
        }

        // Stage 2: New session
        let session = Session(id: event.session_id, cwd: event.cwd)
        session.permissionMode = event.permission_mode
        if let name = event.session_name, !name.isEmpty { session.name = name }
        applyBridgeEnrichment(session: session, event: event)
        sessions[event.session_id] = session
        persistSessionTerminals()
        return session
    }

    // MARK: - Bridge Enrichment

    /// Apply terminal environment data injected by the bridge binary
    private func applyBridgeEnrichment(session: Session, event: HookPayload) {
        var changed = false
        if let tty = event._ag_tty, !tty.isEmpty, session.tty == nil {
            session.tty = tty
            changed = true
        }
        if let termProgram = event._ag_term_program, session.terminalBundleId == nil {
            session.terminalBundleId = Self.bundleIdForTermProgram(termProgram)
            changed = true
        }
        if changed {
            persistSessionTerminals()
        }
    }

    private static func bundleIdForTermProgram(_ prog: String) -> String? {
        switch prog.lowercased() {
        case "apple_terminal": return "com.apple.Terminal"
        case "iterm.app", "iterm2": return "com.googlecode.iterm2"
        case "ghostty", "xterm-ghostty": return "com.mitchellh.ghostty"
        case "kitty": return "net.kovidgoyal.kitty"
        case "warpterm": return "dev.warp.Warp-Stable"
        default: return nil
        }
    }

    // MARK: - Session Terminal Persistence

    private static let sessionTerminalsPath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".agentglance/session-terminals.json")
    }()

    private var persistDebounce: DispatchWorkItem?

    /// Write session→terminal mappings to disk (debounced)
    private func persistSessionTerminals() {
        persistDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeSessionTerminals()
        }
        persistDebounce = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeSessionTerminals() {
        var entries: [String: [String: Any]] = [:]
        for (id, session) in sessions where session.state != .complete {
            var entry: [String: Any] = [
                "cwd": session.cwd,
                "updatedAt": Int(Date().timeIntervalSince1970),
            ]
            if let tty = session.tty { entry["tty"] = tty }
            if let bundleId = session.terminalBundleId { entry["terminalBundleId"] = bundleId }
            if let pid = session.processPID { entry["pid"] = pid }
            if let name = session.name { entry["name"] = name }
            entries[id] = entry
        }

        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) else { return }
        let dir = (Self.sessionTerminalsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.sessionTerminalsPath))
    }

    /// Load persisted session→terminal mappings on startup
    func loadPersistedSessions() {
        guard let data = FileManager.default.contents(atPath: Self.sessionTerminalsPath),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }

        let now = Int(Date().timeIntervalSince1970)
        let maxAge = 86400 // 24 hours

        for (id, entry) in entries {
            guard let cwd = entry["cwd"] as? String,
                  let updatedAt = entry["updatedAt"] as? Int,
                  now - updatedAt < maxAge else { continue }

            // Verify PID is still alive if present
            if let pid = entry["pid"] as? Int {
                guard ProcessScanner.isProcessRunning(pid: pid) else { continue }
            }

            guard sessions[id] == nil else { continue }

            let session = Session(id: id, cwd: cwd)
            session.tty = entry["tty"] as? String
            session.terminalBundleId = entry["terminalBundleId"] as? String
            session.processPID = entry["pid"] as? Int
            session.name = entry["name"] as? String
            session.state = .idle
            sessions[id] = session
            logger.info("Restored session from disk: \(session.name ?? id.prefix(8).description) tty=\(session.tty ?? "?")")
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
        session.workingDetail = .thinking
        session.lastAssistantMessage = nil
        session.completionCardVisible = false

        // Feature 10: capture user prompt for context display
        if let prompt = event.tool_input?["prompt"] {
            session.lastUserPrompt = String(prompt.prefix(120))
        }

        transition(session, to: .working)
    }

    private func handlePreToolUse(_ event: HookPayload) {
        let session = getOrCreateSession(event)
        session.currentTool = event.tool_name
        session.toolCount += 1
        session.workingDetail = .runningTool
        session.pendingToolSummary = Self.extractToolSummary(
            toolName: event.tool_name,
            toolInput: event.tool_input
        )

        // Feature 8: track TodoWrite progress
        if event.tool_name == "TodoWrite", let todos = event.tool_input?[jsonKey: "todos"]?.asArray {
            var progress = TodoProgress()
            for todo in todos {
                if let status = todo["status"] {
                    switch status {
                    case "completed": progress.completed += 1
                    case "in_progress": progress.inProgress += 1
                    default: progress.open += 1
                    }
                }
            }
            session.todoProgress = progress
        }

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
        session.workingDetail = nil

        // Feature 7: capture last assistant message for completion card
        if let msg = event.last_assistant_message, !msg.isEmpty {
            session.lastAssistantMessage = msg
            session.completionCardVisible = true
        } else if let msg = event.tool_input?["last_assistant_message"], !msg.isEmpty {
            session.lastAssistantMessage = msg
            session.completionCardVisible = true
        }

        transition(session, to: .ready)
    }

    private func handlePermissionRequest(_ event: HookPayload) {
        let session = getOrCreateSession(event)
        session.workingDetail = nil
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
        } else if event.notification_type == "compact" {
            // Feature 4: compacting context window
            session.workingDetail = .compacting
            onStateChange?(session, session.state)
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

        case "TodoWrite":
            if case .object(let obj) = toolInput, case .array(let todos) = obj["todos"] {
                var done = 0, prog = 0, open = 0
                for todo in todos {
                    if case .object(let t) = todo, case .string(let status) = t["status"] {
                        switch status {
                        case "completed": done += 1
                        case "in_progress": prog += 1
                        default: open += 1
                        }
                    }
                }
                return "\(done) done, \(prog) in progress, \(open) open"
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

    // MARK: - Process Liveness

    /// Start a repeating timer that removes sessions whose backing process has exited
    func startLivenessChecks() {
        livenessTimer?.invalidate()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkProcessLiveness()
            }
        }
    }

    func stopLivenessChecks() {
        livenessTimer?.invalidate()
        livenessTimer = nil
    }

    private func checkProcessLiveness() {
        for (id, session) in sessions where session.state != .complete {
            if let pid = session.processPID {
                // Session has a known PID — check if process is still alive
                if !ProcessScanner.isProcessRunning(pid: pid) {
                    logger.info("Process \(pid) for session \(session.name ?? id.prefix(8).description) is no longer running — marking complete")
                    session.pendingToolSummary = nil
                    transition(session, to: .complete)
                    scheduleCleanup(for: id)
                }
            } else if session.state == .idle || session.state == .ready {
                // No PID and no recent activity — likely a ghost session
                let staleAge: TimeInterval = 120
                if Date().timeIntervalSince(session.lastActivity) > staleAge {
                    logger.info("Session \(session.name ?? id.prefix(8).description) has no PID and is stale — marking complete")
                    session.pendingToolSummary = nil
                    transition(session, to: .complete)
                    scheduleCleanup(for: id)
                }
            }
        }
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

    // MARK: - Transcript Data

    private func refreshTranscriptData(for session: Session) {
        let sessionId = session.id
        let cwd = session.cwd
        DispatchQueue.global(qos: .utility).async {
            guard let usage = TranscriptReader.readUsage(sessionId: sessionId, cwd: cwd) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let session = self?.sessions[sessionId] else { return }
                session.modelName = usage.modelName
                session.inputTokens = usage.inputTokens
                session.outputTokens = usage.outputTokens
            }
        }
    }
}
