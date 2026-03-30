import SwiftUI

@main
struct AgentGlanceApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let state = appState.sessionManager.activeSessions.first?.state

        switch state {
        case .working:
            MenuBarSpinner()
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

/// Renders the same arc spinner used in the notch as a rasterized NSImage for the menu bar.
/// MenuBarExtra labels only display Image/Text, so we render SpinnerView frames manually.
private struct MenuBarSpinner: View {
    @State private var frame: Int = 0
    private let frameCount = 12
    private let size: CGFloat = 18

    var body: some View {
        Image(nsImage: renderFrame(angle: Double(frame) * (360.0 / Double(frameCount))))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    frame = (frame + 1) % frameCount
                }
            }
    }

    private func renderFrame(angle: Double) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = (min(rect.width, rect.height) - 2) / 2

            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: -angle * .pi / 180)
            ctx.translateBy(x: -center.x, y: -center.y)

            let path = CGMutablePath()
            // 70% arc, matching SpinnerView's .trim(from: 0, to: 0.7)
            path.addArc(center: center, radius: radius,
                        startAngle: 0, endAngle: .pi * 2 * 0.7,
                        clockwise: false)

            ctx.setStrokeColor(NSColor.systemGreen.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.addPath(path)
            ctx.strokePath()
            return true
        }
        img.isTemplate = false
        return img
    }
}
