import SwiftUI
import AppKit
import Combine
import KeyboardShortcuts

@Observable
@MainActor
final class AppState {
    let hookServer: HookServer
    let sessionManager = SessionManager()
    let sleepManager = SleepManager()
    let notificationManager = NotificationManager()
    let hookConfigWatcher = HookConfigWatcher()

    var sleepPreventionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sleepPreventionEnabled, forKey: Constants.UserDefaultsKeys.sleepPreventionEnabled)
            updateSleepPrevention()
        }
    }

    private var notchWindow: NotchWindow?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var appearanceObserver: AnyCancellable?
    private var screenModeObserver: AnyCancellable?

    /// Posted when the notch should auto-expand (e.g. approval came in)
    var shouldAutoExpand = false

    /// Keyboard navigation is active (overlay is focused and receiving key events)
    var isKeyboardNavActive = false
    var focusedRowIndex: Int?
    var focusedActionIndex: Int?

    func actionsForFocusedRow() -> [RowAction] {
        guard let rowIndex = focusedRowIndex,
              rowIndex < sessionManager.activeSessions.count else { return [] }
        let session = sessionManager.activeSessions[rowIndex]

        switch session.state {
        case .awaitingApproval where session.currentTool == "AskUserQuestion":
            // Each question option becomes an action
            guard let pending = hookServer.nextPending(for: session.id) else { return [] }
            let questions = pending.questions
            var actions: [RowAction] = []
            for q in questions {
                for option in q.options {
                    actions.append(RowAction(label: option, icon: nil) {
                        self.hookServer.answerQuestion(sessionId: session.id, answers: [q.questionText: option])
                    })
                }
            }
            return actions
        case .awaitingApproval where session.currentTool == "ExitPlanMode":
            var actions = [
                RowAction(label: "Approve", icon: "checkmark") {
                    self.hookServer.allowPermission(sessionId: session.id)
                },
                RowAction(label: "Reject", icon: "xmark") {
                    self.hookServer.denyPermission(sessionId: session.id, message: "Plan rejected")
                },
            ]
            if session.pendingPlanPath != nil {
                actions.append(RowAction(label: "Open", icon: "arrow.up.right.square") {
                    if let path = session.pendingPlanPath {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                })
            }
            return actions
        case .awaitingApproval:
            return [
                RowAction(label: "Allow", icon: "checkmark") {
                    self.hookServer.allowPermission(sessionId: session.id)
                },
                RowAction(label: "Always", icon: nil) {
                    self.hookServer.allowAlwaysPermission(sessionId: session.id)
                },
                RowAction(label: "Deny", icon: "xmark") {
                    self.hookServer.denyPermission(sessionId: session.id)
                },
                RowAction(label: "Skip", icon: nil) {
                    self.hookServer.dismissPermission(sessionId: session.id)
                },
            ]
        default:
            return [
                RowAction(label: "Terminal", icon: "apple.terminal") {
                    TerminalActivator.activate(session: session)
                },
                RowAction(label: "Folder", icon: "folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
                },
            ]
        }
    }

    init() {
        // Ignore SIGPIPE globally — socket clients may disconnect before we respond
        signal(SIGPIPE, SIG_IGN)

        let port = UInt16(UserDefaults.standard.integer(forKey: Constants.UserDefaultsKeys.port))
        hookServer = HookServer(port: port > 0 ? port : Constants.defaultPort)
        sleepPreventionEnabled = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.sleepPreventionEnabled)

        setupBindings()
        hookServer.start()
        installBridgeLauncher()
        hookConfigWatcher.startWatching()
        notificationManager.setupCategories()
        sessionManager.loadPersistedSessions()
        sessionManager.bootstrapFromRunningProcesses()
        createNotchWindow()
        registerGlobalHotkey()
        observeAppearanceChanges()
        observeScreenModeChanges()

        // First launch: show onboarding and request permissions
        if !UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.hasCompletedOnboarding) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showOnboarding()
                // Request automation permission (triggers macOS consent dialog)
                TerminalActivator.requestAutomationPermission()
            }
        }
    }

    private func setupBindings() {
        hookServer.onEvent = { [weak self] payload in
            self?.sessionManager.handleEvent(payload)
        }

        sessionManager.onStalePendingDecisions = { [weak self] sessionId in
            self?.hookServer.flushPendingDecisions(for: sessionId)
        }

        hookServer.onDecision = { [weak self] sessionId, allowed in
            guard let self, let session = sessionManager.sessions[sessionId] else { return }

            // If more approvals are queued, stay in awaitingApproval and update the display
            if hookServer.pendingCount(for: sessionId) > 0,
               let next = hookServer.nextPending(for: sessionId) {
                session.currentTool = next.toolName
                session.pendingToolSummary = next.toolSummary
                // state stays .awaitingApproval
            } else {
                session.state = allowed ? .working : .idle
                session.pendingToolSummary = nil
                if !allowed { session.currentTool = nil }
            }
        }

        sessionManager.onStateChange = { [weak self] session, newState in
            guard let self else { return }

            switch newState {
            case .awaitingApproval:
                notificationManager.notifyAwaitingApproval(session: session)
                playAlertSound()
                if UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.autoExpandOnApproval) {
                    // Feature 5: suppress expansion if user is already in the agent's terminal
                    if UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.suppressExpansionWhenInTerminal),
                       isUserInSessionTerminal(session) {
                        // User is looking at the right terminal — don't interrupt
                    } else {
                        shouldAutoExpand = true
                    }
                }
            case .ready:
                notificationManager.notifyReady(session: session)
                playAlertSound()
            case .complete:
                notificationManager.notifyComplete(session: session)
            case .working, .idle:
                break
            }

            updateSleepPrevention()
            updateNotchVisibility()
        }
    }

    // MARK: - Bridge Installation

    /// Install or update the bridge launcher script at ~/.agentglance/bin/agentglance-bridge
    private func installBridgeLauncher() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".agentglance/bin")
        let path = (dir as NSString).appendingPathComponent("agentglance-bridge")
        let fm = FileManager.default

        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let script = """
        #!/bin/bash
        H=/Contents/Helpers/agentglance-bridge
        for P in "/Applications/AgentGlance.app" "$HOME/Applications/AgentGlance.app"; do
            [ -x "${P}${H}" ] && exec "${P}${H}" "$@"
        done
        # App not found — fall back to curl (silent, don't block Claude)
        INPUT=$(cat)
        EVENT=$(echo "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
        PORT=${AG_PORT:-7483}
        if [ "$EVENT" = "PermissionRequest" ]; then
            echo "$INPUT" | curl -s --max-time 120 -X POST -H 'Content-Type: application/json' -d @- "http://localhost:${PORT}/hook/${EVENT}" 2>/dev/null
        else
            echo "$INPUT" | curl -s --connect-timeout 1 -X POST -H 'Content-Type: application/json' -d @- "http://localhost:${PORT}/hook/${EVENT}" 2>/dev/null || true
        fi
        """

        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    // MARK: - Terminal Focus Detection

    /// Returns true if the user's frontmost app is the terminal where this session runs
    private func isUserInSessionTerminal(_ session: Session) -> Bool {
        guard let termBundleId = session.terminalBundleId,
              let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return false }
        return frontmost == termBundleId
    }

    // MARK: - Sleep Prevention

    private func updateSleepPrevention() {
        if sleepPreventionEnabled && sessionManager.hasWorkingSessions {
            sleepManager.preventSleep()
        } else {
            sleepManager.allowSleep()
        }
    }

    // MARK: - Notch Window

    private func updateNotchVisibility() {
        if notchWindow == nil {
            createNotchWindow()
        }
        // Always keep notch visible — it shows/hides content based on sessions
        notchWindow?.orderFront(nil)
    }

    private func createNotchWindow() {
        // Always close the old window first — NSPanels stay visible
        // even after dropping the reference until explicitly closed.
        notchWindow?.close()
        let overlay = NotchOverlay(sessionManager: sessionManager, hookServer: hookServer, appState: self)
        notchWindow = NotchWindow(contentView: overlay)
        notchWindow?.orderFront(nil)
    }

    func refreshNotchWindow() {
        notchWindow?.close()
        notchWindow = nil
        if !sessionManager.activeSessions.isEmpty {
            createNotchWindow()
        }
    }

    // MARK: - Testing

    private struct TestSession {
        let id: String
        let cwd: String
        let name: String

        static let claude = TestSession(id: "test-claude", cwd: "/Users/demo/Projects/MyApp", name: "MyApp")
        static let codex = TestSession(id: "test-codex", cwd: "/Users/demo/Projects/Backend", name: "Backend")
        static let gemini = TestSession(id: "test-gemini", cwd: "/Users/demo/Projects/Frontend", name: "Frontend")
    }

    func sendTestEvent(_ eventName: String, toolName: String? = nil) {
        var toolInput: JSONValue? = nil
        if let toolName {
            switch toolName {
            case "Bash":
                toolInput = .object(["command": .string("npm run build && npm test")])
            case "Edit":
                toolInput = .object(["file_path": .string("/Users/demo/Projects/MyApp/src/components/Header.swift")])
            case "Write":
                toolInput = .object(["file_path": .string("/Users/demo/Projects/MyApp/README.md")])
            default:
                break
            }
        }

        let payload = HookPayload(
            session_id: TestSession.claude.id,
            cwd: TestSession.claude.cwd,
            hook_event_name: eventName,
            tool_name: toolName,
            tool_input: toolInput
        )
        sessionManager.handleEvent(payload)
    }

    func sendTestNotification(type: String) {
        let payload = HookPayload(
            session_id: TestSession.claude.id,
            cwd: TestSession.claude.cwd,
            hook_event_name: "Notification",
            notification_type: type
        )
        sessionManager.handleEvent(payload)
    }

    func sendTestApproval(toolName: String) {
        let session = TestSession.claude
        var toolInput: JSONValue? = nil
        var toolSummary: String? = nil
        switch toolName {
        case "Bash":
            toolInput = .object(["command": .string("npm run build && npm test")])
            toolSummary = "npm run build && npm test"
        case "Edit":
            toolInput = .object(["file_path": .string("/Users/demo/Projects/MyApp/src/components/Header.swift")])
            toolSummary = ".../components/Header.swift"
        default:
            break
        }

        let payload = HookPayload(
            session_id: session.id,
            cwd: session.cwd,
            hook_event_name: "PermissionRequest",
            tool_name: toolName,
            tool_input: toolInput
        )
        sessionManager.handleEvent(payload)
        hookServer.addMockPending(
            sessionId: session.id,
            toolName: toolName,
            toolInput: toolInput,
            toolSummary: toolSummary
        )
    }

    func sendTestQuestion() {
        let session = TestSession.codex
        let toolInput: JSONValue = .object([
            "questions": .array([
                .object([
                    "question": .string("Which database should we use?"),
                    "header": .string("Database"),
                    "options": .array([
                        .object(["label": .string("PostgreSQL"), "description": .string("Relational, battle-tested")]),
                        .object(["label": .string("SQLite"), "description": .string("Embedded, zero config")]),
                        .object(["label": .string("MongoDB"), "description": .string("Document store")]),
                        .object(["label": .string("Redis"), "description": .string("In-memory, fast")])
                    ]),
                    "multiSelect": .bool(false)
                ])
            ]),
            "answers": .object([:])
        ])

        let payload = HookPayload(
            session_id: session.id,
            cwd: session.cwd,
            hook_event_name: "PermissionRequest",
            tool_name: "AskUserQuestion",
            tool_input: toolInput
        )
        sessionManager.handleEvent(payload)
        hookServer.addMockPending(
            sessionId: session.id,
            toolName: "AskUserQuestion",
            toolInput: toolInput,
            toolSummary: "Which database should we use?"
        )
    }

    func sendTestPlanReview() {
        let session = TestSession.gemini
        let payload = HookPayload(
            session_id: session.id,
            cwd: session.cwd,
            hook_event_name: "PermissionRequest",
            tool_name: "ExitPlanMode"
        )
        sessionManager.handleEvent(payload)
        hookServer.addMockPending(
            sessionId: session.id,
            toolName: "ExitPlanMode",
            toolInput: nil,
            toolSummary: nil
        )

        // Ensure plan data is set (handlePermissionRequest may have been called
        // before the session was observable by the UI)
        if let s = sessionManager.sessions[session.id] {
            let (preview, full, path) = SessionManager.findLatestPlan()
            s.pendingPlanPreview = preview
            s.pendingPlanFull = full
            s.pendingPlanPath = path
        }
    }

    // MARK: - Sound

    private func playAlertSound() {
        guard UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.soundEnabled) else { return }
        NSSound.beep()
    }

    // MARK: - Windows

    func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView(appState: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Setup Claude Code Hooks"
        window.isReleasedWhenClosed = false
        window.appearance = AppearanceHelper.nsAppearance()
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
    }

    func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Global Hotkey (via KeyboardShortcuts)

    func registerGlobalHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleOverlay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.activateOverlayWithKeyboard()
            }
        }
    }

    func activateOverlayWithKeyboard() {
        guard !sessionManager.activeSessions.isEmpty else { return }
        shouldAutoExpand = true
        isKeyboardNavActive = true
        let navMode = KeyboardNavMode(rawValue:
            UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.keyboardNavMode) ?? "arrows"
        ) ?? .arrows
        // Arrow mode starts with first row focused; number mode starts with no row (shows badges)
        focusedRowIndex = navMode == .arrows ? 0 : nil
        focusedActionIndex = nil
        NSApp.activate(ignoringOtherApps: true)
        notchWindow?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func deactivateKeyboardNav() {
        isKeyboardNavActive = false
        focusedRowIndex = nil
        focusedActionIndex = nil
        removeKeyMonitor()
        NSApp.deactivate()
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isKeyboardNavActive else { return event }
            // Don't intercept keys when settings or other windows are key
            if let keyWindow = NSApp.keyWindow, keyWindow !== self.notchWindow {
                return event
            }
            if self.handleKeyEvent(event) { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let key = event.keyCode
        let navMode = KeyboardNavMode(rawValue:
            UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.keyboardNavMode) ?? "arrows"
        ) ?? .arrows

        // Escape — cascade back
        if key == 53 {
            if focusedActionIndex != nil {
                focusedActionIndex = nil
            } else if focusedRowIndex != nil {
                focusedRowIndex = nil
            } else {
                shouldAutoExpand = false
                deactivateKeyboardNav()
            }
            return true
        }

        switch navMode {
        case .arrows: return handleArrowMode(keyCode: key)
        case .numbers: return handleNumberMode(event: event)
        }
    }

    private func handleArrowMode(keyCode: UInt16) -> Bool {
        let count = sessionManager.activeSessions.count
        guard count > 0 else { return false }

        switch keyCode {
        case 126: // Up
            if let idx = focusedRowIndex {
                focusedRowIndex = max(0, idx - 1)
                focusedActionIndex = nil
            } else {
                focusedRowIndex = count - 1
            }
            return true

        case 125: // Down
            if let idx = focusedRowIndex {
                focusedRowIndex = min(count - 1, idx + 1)
                focusedActionIndex = nil
            } else {
                focusedRowIndex = 0
            }
            return true

        case 123: // Left
            if focusedRowIndex != nil {
                let actionCount = actionsForFocusedRow().count
                if let idx = focusedActionIndex {
                    focusedActionIndex = max(0, idx - 1)
                } else if actionCount > 0 {
                    focusedActionIndex = actionCount - 1
                }
            }
            return true

        case 124: // Right
            if focusedRowIndex != nil {
                let actionCount = actionsForFocusedRow().count
                if let idx = focusedActionIndex {
                    focusedActionIndex = min(actionCount - 1, idx + 1)
                } else if actionCount > 0 {
                    focusedActionIndex = 0
                }
            }
            return true

        case 36: // Return
            if let actionIdx = focusedActionIndex {
                let actions = actionsForFocusedRow()
                if actionIdx < actions.count {
                    actions[actionIdx].execute()
                    shouldAutoExpand = false
                    deactivateKeyboardNav()
                }
            } else if focusedRowIndex != nil {
                focusedActionIndex = 0
            }
            return true

        default:
            return false
        }
    }

    private func handleNumberMode(event: NSEvent) -> Bool {
        guard let char = event.charactersIgnoringModifiers,
              let num = Int(char), num >= 1, num <= 9 else { return false }

        let index = num - 1

        if focusedRowIndex == nil {
            if index < sessionManager.activeSessions.count {
                focusedRowIndex = index
                focusedActionIndex = nil
            }
        } else {
            let actions = actionsForFocusedRow()
            if index < actions.count {
                actions[index].execute()
                shouldAutoExpand = false
                deactivateKeyboardNav()
            }
        }
        return true
    }

    private func observeAppearanceChanges() {
        appearanceObserver = UserDefaults.standard.publisher(
            for: \.appearanceMode
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyAppearanceToAllWindows()
            }
        }
    }

    private func applyAppearanceToAllWindows() {
        let appearance = AppearanceHelper.nsAppearance()
        notchWindow?.appearance = appearance
        settingsWindow?.appearance = appearance
        onboardingWindow?.appearance = appearance
    }

    private func observeScreenModeChanges() {
        screenModeObserver = UserDefaults.standard.publisher(
            for: \.screenSelectionMode
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.notchWindow?.positionAtNotch()
            }
        }
    }

    func resetPillPosition() {
        UserDefaults.standard.set(0.0, forKey: Constants.UserDefaultsKeys.pillOffsetX)
        UserDefaults.standard.set(0.0, forKey: Constants.UserDefaultsKeys.pillOffsetY)
        notchWindow?.positionAtNotch()
    }


    func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(appState: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentGlance Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 300)
        window.appearance = AppearanceHelper.nsAppearance()
        window.contentView = NSHostingView(rootView: view)
        window.center()

        // Show in cmd+tab while settings is open
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        window.makeKeyAndOrderFront(nil)
        settingsWindow = window

        // Watch for close to hide from cmd+tab again
        let closeDelegate = WindowCloseDelegate { [weak self] in
            self?.settingsWindow = nil
            // Defer activation policy change — changing during window close crashes AppKit
            DispatchQueue.main.async {
                if self?.onboardingWindow == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        // Store the delegate so it stays alive as long as the window
        objc_setAssociatedObject(window, "closeDelegate", closeDelegate, .OBJC_ASSOCIATION_RETAIN)
        window.delegate = closeDelegate
    }
}

// MARK: - Window close delegate helper

private class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
