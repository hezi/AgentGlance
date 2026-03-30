import SwiftUI
import AppKit
import Combine

@Observable
@MainActor
final class AppState {
    let hookServer: HookServer
    let sessionManager = SessionManager()
    let sleepManager = SleepManager()
    let notificationManager = NotificationManager()

    var sleepPreventionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sleepPreventionEnabled, forKey: Constants.UserDefaultsKeys.sleepPreventionEnabled)
            updateSleepPrevention()
        }
    }

    private var notchWindow: NotchWindow?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var globalHotkeyMonitor: Any?
    private var appearanceObserver: AnyCancellable?
    private var screenModeObserver: AnyCancellable?

    /// Posted when the notch should auto-expand (e.g. approval came in)
    var shouldAutoExpand = false

    init() {
        let port = UInt16(UserDefaults.standard.integer(forKey: Constants.UserDefaultsKeys.port))
        hookServer = HookServer(port: port > 0 ? port : Constants.defaultPort)
        sleepPreventionEnabled = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.sleepPreventionEnabled)

        setupBindings()
        hookServer.start()
        notificationManager.setupCategories()
        sessionManager.bootstrapFromRunningProcesses()
        createNotchWindow()
        registerGlobalHotkey()
        observeAppearanceChanges()
        observeScreenModeChanges()
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
                    shouldAutoExpand = true
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

    func sendTestEvent(_ eventName: String, toolName: String? = nil) {
        // Build realistic tool_input for testing
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
            session_id: "test-session",
            cwd: "/Users/demo/Projects/MyApp",
            hook_event_name: eventName,
            tool_name: toolName,
            tool_input: toolInput
        )
        sessionManager.handleEvent(payload)
    }

    func sendTestNotification(type: String) {
        let payload = HookPayload(
            session_id: "test-session",
            cwd: "/Users/demo/Projects/MyApp",
            hook_event_name: "Notification",
            notification_type: type
        )
        sessionManager.handleEvent(payload)
    }

    /// Simulate a full approval request: sets the session state and queues a mock
    /// PendingDecision so Allow/Deny buttons appear in the UI.
    func sendTestApproval(toolName: String) {
        var toolInput: JSONValue? = nil
        var toolSummary: String? = nil
        switch toolName {
        case "Bash":
            toolInput = .object(["command": .string("npm run build && npm test")])
            toolSummary = "npm run build && npm test"
        case "Edit":
            toolInput = .object(["file_path": .string("/Users/demo/Projects/MyApp/src/components/Header.swift")])
            toolSummary = ".../components/Header.swift"
        case "Write":
            toolInput = .object(["file_path": .string("/Users/demo/Projects/MyApp/README.md")])
            toolSummary = ".../MyApp/README.md"
        default:
            break
        }

        let payload = HookPayload(
            session_id: "test-session",
            cwd: "/Users/demo/Projects/MyApp",
            hook_event_name: "PermissionRequest",
            tool_name: toolName,
            tool_input: toolInput
        )
        sessionManager.handleEvent(payload)
        hookServer.addMockPending(
            sessionId: "test-session",
            toolName: toolName,
            toolInput: toolInput,
            toolSummary: toolSummary
        )
    }

    func sendTestQuestion() {
        let toolInput: JSONValue = .object([
            "questions": .array([
                .object([
                    "question": .string("Which database should we use?"),
                    "header": .string("Database"),
                    "options": .array([
                        .object(["label": .string("PostgreSQL"), "description": .string("Relational, battle-tested")]),
                        .object(["label": .string("SQLite"), "description": .string("Embedded, zero config")]),
                        .object(["label": .string("MongoDB"), "description": .string("Document store")])
                    ]),
                    "multiSelect": .bool(false)
                ])
            ]),
            "answers": .object([:])
        ])

        let payload = HookPayload(
            session_id: "test-session",
            cwd: "/Users/demo/Projects/MyApp",
            hook_event_name: "PermissionRequest",
            tool_name: "AskUserQuestion",
            tool_input: toolInput
        )
        sessionManager.handleEvent(payload)
        hookServer.addMockPending(
            sessionId: "test-session",
            toolName: "AskUserQuestion",
            toolInput: toolInput,
            toolSummary: "Which database should we use?"
        )
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

    // MARK: - Global Hotkey (⌥⇧C)

    private func registerGlobalHotkey() {
        // ⌥⇧C → jump to the most urgent session's terminal
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Check for ⌥⇧C (option + shift + C)
            guard event.modifierFlags.contains([.option, .shift]),
                  event.charactersIgnoringModifiers?.lowercased() == "c" else { return }

            Task { @MainActor [weak self] in
                self?.jumpToMostUrgentSession()
            }
        }
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

    private func jumpToMostUrgentSession() {
        guard let session = sessionManager.activeSessions.first else { return }
        TerminalActivator.activate(session: session)
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
