import AppKit
import SwiftUI
import Combine

/// Shared geometry that the SwiftUI overlay writes to and the hosting view reads from.
final class NotchGeometry: ObservableObject {
    /// The pill's frame in the hosting view's coordinate system
    @Published var pillRect: CGRect = .zero
}

final class NotchWindow: NSPanel {
    let geometry = NotchGeometry()

    init(contentView: some View) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
        self.ignoresMouseEvents = false

        let wrappedView = contentView
            .environmentObject(geometry)

        let hostingView = ClickThroughHostingView(rootView: AnyView(wrappedView))
        hostingView.geometry = geometry
        self.contentView = hostingView

        positionAtNotch()
    }

    func positionAtNotch() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        let windowWidth: CGFloat = 500
        let windowHeight: CGFloat = 400

        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.maxY - windowHeight

        setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that passes clicks through to windows behind when the click
/// lands outside the pill's reported bounds.
final class ClickThroughHostingView: NSHostingView<AnyView> {
    weak var geometry: NotchGeometry?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let geometry else {
            // No geometry yet — allow all events so SwiftUI can render
            return super.hitTest(point)
        }

        let pillRect = geometry.pillRect
        if pillRect.isEmpty {
            // Geometry not reported yet — allow all events
            return super.hitTest(point)
        }

        // Add padding for hover detection near edges
        let hitRect = pillRect.insetBy(dx: -12, dy: -12)

        if hitRect.contains(point) {
            return super.hitTest(point)
        }

        // Outside the pill — pass through to windows behind
        return nil
    }
}
