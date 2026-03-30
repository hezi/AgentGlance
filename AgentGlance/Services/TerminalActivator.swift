import AppKit
import os

private let logger = Logger(subsystem: "app.agentglance", category: "TerminalActivator")

enum TerminalActivator {
    /// Activate the terminal tab/window running the given session
    static func activate(session: Session) {
        guard let bundleId = session.terminalBundleId else {
            logger.info("No terminal detected for session \(session.id)")
            return
        }

        logger.info("Activating \(bundleId) for session \(session.projectName) (tty: \(session.tty ?? "?"), cwd: \(session.cwd), pid: \(session.processPID.map(String.init) ?? "?"), name: \(session.name ?? "nil"))")

        switch bundleId {
        case "com.apple.Terminal":
            activateTerminalApp(tty: session.tty, bundleId: bundleId)
        case "com.googlecode.iterm2":
            activateITerm2(tty: session.tty, bundleId: bundleId)
        case "net.kovidgoyal.kitty":
            activateKitty(pid: session.processPID, bundleId: bundleId)
        case "com.mitchellh.ghostty":
            activateGhostty(session: session)
        default:
            activateApp(bundleId: bundleId)
        }
    }

    /// Request automation permission by running a trivial AppleScript against Terminal.
    /// Call this once from settings to trigger the macOS consent dialog.
    static func requestAutomationPermission() {
        // Use osascript which handles TCC prompts more reliably than NSAppleScript
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            tell application "System Events" to return name of first process
        """]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
                logger.info("Automation permission request completed (exit: \(process.terminationStatus))")
            } catch {
                logger.error("Failed to request automation permission: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Terminal.app

    private static func activateTerminalApp(tty: String?, bundleId: String) {
        guard let tty else {
            activateApp(bundleId: bundleId)
            return
        }

        // Use osascript for more reliable TCC handling
        let script = """
            tell application "Terminal"
                activate
                set targetTTY to "/dev/\(tty)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is targetTTY then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
        """

        runOsascript(script)
    }

    // MARK: - iTerm2

    private static func activateITerm2(tty: String?, bundleId: String) {
        guard let tty else {
            activateApp(bundleId: bundleId)
            return
        }

        let script = """
            tell application "iTerm2"
                activate
                set targetTTY to "/dev/\(tty)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is targetTTY then
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        """

        runOsascript(script)
    }

    // MARK: - Kitty

    private static func activateKitty(pid: Int?, bundleId: String) {
        guard let pid else {
            activateApp(bundleId: bundleId)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Try homebrew path first (most common on Apple Silicon), then /usr/local
            for path in ["/opt/homebrew/bin/kitten", "/usr/local/bin/kitten"] {
                guard FileManager.default.fileExists(atPath: path) else { continue }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["@", "focus-window", "--match", "pid:\(pid)"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continue
                }
                break
            }

            DispatchQueue.main.async {
                activateApp(bundleId: bundleId)
            }
        }
    }

    // MARK: - Ghostty

    /// Cached TTY→tab index mapping for Ghostty. Invalidated when tab count changes.
    private static var ghosttyTTYCache: [String: Int] = [:]  // tty → tab index (1-based)
    private static var ghosttyCacheTabCount: Int = 0
    private static var ghosttyCacheTime: Date = .distantPast

    private static func activateGhostty(session: Session) {
        // Strategy: find the Ghostty tab index that owns this session's TTY,
        // then focus that tab via AppleScript.
        //
        // Each Ghostty tab spawns a login process as a direct child of the Ghostty
        // main process. We can enumerate these login PIDs, find each one's TTY via ps,
        // and match against the session's known TTY. The tab order in AppleScript
        // corresponds to creation order (= login PID order within each window).
        //
        // Future: once Ghostty exposes `tty` on the terminal AppleScript class,
        // we can match directly without the ps workaround.

        // Capture session info for use on background queue
        let sessionName = session.name ?? ""
        let cwdLeaf = (session.cwd as NSString).lastPathComponent
        let cwd = session.cwd
        let tty = session.tty ?? ""

        // Run on background queue to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Try to resolve the target tab index via TTY matching.
            // Query AppleScript for tab list, then correlate with process TTYs from Swift.
            let resolvedIndex = !tty.isEmpty ? resolveGhosttyTabByTTY(targetTTY: tty) : nil
            logger.info("Ghostty activate: name=\(sessionName) tty=\(tty) cwd=\(cwd) resolvedTab=\(resolvedIndex.map(String.init) ?? "nil")")

            // Step 2: Focus the tab via AppleScript
            let script = """
                tell application "Ghostty"
                    activate
                    try
                        set targetSessionName to "\(sessionName)"
                        set targetCwdLeaf to "\(cwdLeaf)"
                        set targetCwd to "\(cwd)"
                        set resolvedTabIndex to \(resolvedIndex ?? -1)
                        set allWindows to every window

                        -- Pass 1: use resolved tab index from TTY matching
                        if resolvedTabIndex > 0 then
                            set tabIndex to 0
                            repeat with w in allWindows
                                repeat with t in tabs of w
                                    set tabIndex to tabIndex + 1
                                    if tabIndex is resolvedTabIndex then
                                        log "  MATCH by TTY (resolved tab " & tabIndex & ")"
                                        select tab t
                                        set index of w to 1
                                        return
                                    end if
                                end repeat
                            end repeat
                        end if

                        -- Pass 2: try tty property on terminal (future Ghostty versions)
                        set targetTTY to "\(tty)"
                        if targetTTY is not "" then
                            repeat with w in allWindows
                                repeat with t in tabs of w
                                    try
                                        if (tty of (focused terminal of t)) contains targetTTY then
                                            log "  MATCH by tty property"
                                            select tab t
                                            set index of w to 1
                                            return
                                        end if
                                    end try
                                end repeat
                            end repeat
                        end if

                        -- Pass 3: match by session name in tab name
                        if targetSessionName is not "" then
                            repeat with w in allWindows
                                repeat with t in tabs of w
                                    if (name of t) contains targetSessionName then
                                        log "  MATCH by session name: " & (name of t)
                                        select tab t
                                        set index of w to 1
                                        return
                                    end if
                                end repeat
                            end repeat
                        end if

                        -- Pass 4: match by exact cwd
                        repeat with w in allWindows
                            repeat with t in tabs of w
                                if (working directory of (focused terminal of t)) is targetCwd then
                                    log "  MATCH by exact cwd"
                                    select tab t
                                    set index of w to 1
                                    return
                                end if
                            end repeat
                        end repeat

                        -- Pass 5: match by cwd leaf in tab name
                        repeat with w in allWindows
                            repeat with t in tabs of w
                                if (name of t) contains targetCwdLeaf then
                                    log "  MATCH by cwd leaf: " & (name of t)
                                    select tab t
                                    set index of w to 1
                                    return
                                end if
                            end repeat
                        end repeat

                        log "No match found"
                    end try
                end tell
            """

            runOsascriptSync(script)
        }
    }

    /// Resolve which Ghostty tab (1-based index in AppleScript iteration order) owns the target TTY.
    /// Queries AppleScript for tab name+cwd per tab, then correlates with process tree info.
    private static func resolveGhosttyTabByTTY(targetTTY: String) -> Int? {
        // Check cache first (valid for 30 seconds)
        let cacheAge = Date().timeIntervalSince(ghosttyCacheTime)
        if cacheAge < 30, let cached = ghosttyTTYCache[targetTTY] {
            logger.info("Ghostty TTY resolve: cache hit → tab \(cached) (age: \(Int(cacheAge))s)")
            return cached
        }

        // Cache miss or stale — rebuild
        rebuildGhosttyTTYCache()
        return ghosttyTTYCache[targetTTY]
    }

    private static func rebuildGhosttyTTYCache() {
        ghosttyTTYCache.removeAll()
        ghosttyCacheTime = Date()

        // Step 1: Single ps call for all process info
        guard let ghosttyApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first else { return }
        let ghosttyPID = Int(ghosttyApp.processIdentifier)

        let psProcess = Process()
        psProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
        psProcess.arguments = ["-eo", "pid,ppid,tty"]
        let psPipe = Pipe()
        psProcess.standardOutput = psPipe
        psProcess.standardError = FileHandle.nullDevice
        do { try psProcess.run() } catch { return }
        let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
        psProcess.waitUntilExit()
        guard let psOutput = String(data: psData, encoding: .utf8) else { return }

        // Find Ghostty's login children and their shell children
        var loginPIDs: [(pid: Int, tty: String)] = []
        for line in psOutput.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 3, let pid = Int(parts[0]), let ppid = Int(parts[1]),
                  ppid == ghosttyPID, parts[2] != "??" else { continue }
            let tty = parts[2].hasPrefix("s") ? "tty" + parts[2] : parts[2]
            loginPIDs.append((pid, tty))
        }
        guard !loginPIDs.isEmpty else { return }

        // Find shell child of each login (from same ps output)
        var shellPIDs: [Int] = []
        var ttyForShell: [Int: String] = [:] // shellPID → tty
        for login in loginPIDs {
            for line in psOutput.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard parts.count >= 2, let pid = Int(parts[0]), let ppid = Int(parts[1]),
                      ppid == login.pid else { continue }
                shellPIDs.append(pid)
                ttyForShell[pid] = login.tty
                break
            }
        }

        // Step 2: Single batched lsof call for all shell cwds
        var ttyToCwd: [String: String] = [:]
        if !shellPIDs.isEmpty {
            let pidArgs = shellPIDs.map(String.init).joined(separator: ",")
            let lsofProcess = Process()
            lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsofProcess.arguments = ["-a", "-p", pidArgs, "-d", "cwd", "-Fn"]
            let lsofPipe = Pipe()
            lsofProcess.standardOutput = lsofPipe
            lsofProcess.standardError = FileHandle.nullDevice
            do { try lsofProcess.run() } catch { /* continue */ }
            let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
            lsofProcess.waitUntilExit()

            if let lsofOutput = String(data: lsofData, encoding: .utf8) {
                var currentPID: Int?
                for line in lsofOutput.components(separatedBy: .newlines) {
                    if line.hasPrefix("p"), let pid = Int(line.dropFirst(1)) {
                        currentPID = pid
                    } else if line.hasPrefix("n/"), let pid = currentPID, let tty = ttyForShell[pid] {
                        ttyToCwd[tty] = String(line.dropFirst(1))
                    }
                }
            }
        }

        // Step 3: Get tab list from AppleScript (single call)
        let queryScript = """
            tell application "Ghostty"
                set output to ""
                repeat with w in every window
                    repeat with t in tabs of w
                        set term to focused terminal of t
                        set output to output & (working directory of term) & "\\t" & (name of t) & linefeed
                    end repeat
                end repeat
                return output
            end tell
        """

        let queryProcess = Process()
        queryProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        queryProcess.arguments = ["-e", queryScript]
        let queryPipe = Pipe()
        let queryErrPipe = Pipe()
        queryProcess.standardOutput = queryPipe
        queryProcess.standardError = queryErrPipe

        do { try queryProcess.run() } catch { return }
        let queryData = queryPipe.fileHandleForReading.readDataToEndOfFile()
        queryProcess.waitUntilExit()
        guard queryProcess.terminationStatus == 0,
              let tabList = String(data: queryData, encoding: .utf8) else { return }

        struct GhosttyTab {
            let index: Int // 1-based
            let cwd: String
            let name: String
        }

        let tabs = tabList.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .enumerated()
            .map { (i, line) -> GhosttyTab in
                let parts = line.components(separatedBy: "\t")
                return GhosttyTab(
                    index: i + 1,
                    cwd: parts.first ?? "",
                    name: parts.count > 1 ? parts[1] : ""
                )
            }

        guard !tabs.isEmpty else { return }

        // Step 4: Correlate tabs with TTYs
        var unassignedTTYs = ttyToCwd
        var result: [String: Int] = [:]

        // Pass 1: exact cwd match
        for tab in tabs {
            let matches = unassignedTTYs.filter { $0.value == tab.cwd }
            if matches.count == 1, let m = matches.first {
                result[m.key] = tab.index
                unassignedTTYs.removeValue(forKey: m.key)
            }
        }

        // Pass 2: tab name contains cwd leaf
        for tab in tabs where !result.values.contains(tab.index) {
            for (tty, shellCwd) in unassignedTTYs {
                let leaf = (shellCwd as NSString).lastPathComponent
                if tab.name.contains(leaf) {
                    let others = unassignedTTYs.filter { tab.name.contains(($0.value as NSString).lastPathComponent) }
                    if others.count == 1 {
                        result[tty] = tab.index
                        unassignedTTYs.removeValue(forKey: tty)
                        break
                    }
                }
            }
        }

        // Pass 3: process of elimination
        let unassignedTabIndices = Set(tabs.map(\.index)).subtracting(result.values)
        if unassignedTabIndices.count == 1 && unassignedTTYs.count == 1 {
            result[unassignedTTYs.keys.first!] = unassignedTabIndices.first!
        }

        ghosttyTTYCache = result
        ghosttyCacheTabCount = tabs.count
        logger.info("Ghostty TTY cache rebuilt: \(result.map { "\($0.key)→tab\($0.value)" }.joined(separator: ", ")) (\(tabs.count) tabs)")
    }

    // MARK: - Generic App Activation

    private static func activateApp(bundleId: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            // App not running — try to open it
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            return
        }
        app.activate()
    }

    // MARK: - osascript Helper

    /// Run osascript on a background queue (non-blocking from main thread)
    private static func runOsascript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            runOsascriptSync(script)
        }
    }

    /// Run osascript synchronously (must be called from a background queue)
    private static func runOsascriptSync(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                logger.error("osascript failed (\(process.terminationStatus)): \(errStr)")
            } else if !errStr.isEmpty {
                // log statements in AppleScript go to stderr
                logger.info("osascript output: \(errStr)")
            }
        } catch {
            logger.error("Failed to run osascript: \(error.localizedDescription)")
        }
    }
}
