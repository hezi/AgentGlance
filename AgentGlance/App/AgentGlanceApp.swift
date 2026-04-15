import SwiftUI
import Sparkle

@main
struct AgentGlanceApp: App {
    @State private var appState = AppState()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        // Share the updater with AppState so Settings can trigger checks
        appState.updater = updaterController.updater

        // Sparkle's background-app mode suppresses UI for automatic checks.
        // Run an explicit check so users see the update dialog on launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [updaterController] in
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            Toggle("Prevent Sleep", isOn: Binding(
                get: { appState.sleepPreventionEnabled },
                set: { appState.sleepPreventionEnabled = $0 }
            ))

            Divider()

            Button("Setup Integrations...") {
                appState.showOnboarding()
            }
            Button("Settings...") {
                appState.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Check for Updates...") {
                updaterController.updater.checkForUpdates()
            }
            Button("Report Issue...") {
                reportIssue()
            }

            Divider()

            Button("Quit AgentGlance") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)

        if #available(macOS 15.0, *) {
            SystemChromeNotchScene(appState: appState)
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let state = appState.sessionManager.activeSessions.first?.state

        menuBarIcon(for: state)
            .onReceive(NotificationCenter.default.publisher(for: .openSystemChromeWindow)) { _ in
                // Only open if no system chrome window exists yet
                let alreadyOpen = NSApp.windows.contains { $0.identifier?.rawValue.contains("system-chrome") == true && $0.isVisible }
                if !alreadyOpen {
                    if #available(macOS 15.0, *) {
                        openWindow(id: "system-chrome-notch")
                    }
                }
            }
    }

    @ViewBuilder
    private func menuBarIcon(for state: SessionState?) -> some View {
        switch state {
        case .working:
            MenuBarPulse()
        case .awaitingApproval:
            Image(systemName: "circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.yellow)
        case .ready:
            Image(systemName: "circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.green)
        case .idle:
            Image(systemName: "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary)
        case nil:
            Image(systemName: "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    private func reportIssue() {
        var body = """
        **Describe the issue:**\n\n\n
        **Steps to reproduce:**\n1. \n\n
        **macOS version:** \(ProcessInfo.processInfo.operatingSystemVersionString)\n
        """
        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://github.com/hezi/AgentGlance/issues/new?body=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension Notification.Name {
    static let openSystemChromeWindow = Notification.Name("openSystemChromeWindow")
}

/// Gentle pulsing dot for the menu bar working state.
/// Much less distracting than the spinning arc while still signaling activity.
private struct MenuBarPulse: View {
    @State private var bright = false
    private let size: CGFloat = 18

    var body: some View {
        Image(nsImage: renderDot(opacity: bright ? 1.0 : 0.35))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(800))
                    bright.toggle()
                }
            }
    }

    private func renderDot(opacity: Double) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 4.5

            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(opacity).cgColor)
            ctx.fillEllipse(in: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            return true
        }
        img.isTemplate = false
        return img
    }
}
