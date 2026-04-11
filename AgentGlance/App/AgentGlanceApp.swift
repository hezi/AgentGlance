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
            MenuBarView(appState: appState, updater: updaterController.updater)
            #if DEBUG
            Divider()
            Button("Open Experimental Window") {
                openWindow(id: "experimental-notch")
            }
            #endif
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        if #available(macOS 15.0, *) {
            ExperimentalNotchScene(appState: appState)
        }
        #endif
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let state = appState.sessionManager.activeSessions.first?.state

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
                .foregroundStyle(.primary.opacity(0.5))
        case nil:
            Image(systemName: "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary.opacity(0.3))
        }
    }
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
