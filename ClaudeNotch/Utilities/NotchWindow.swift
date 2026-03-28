import AppKit
import SwiftUI
import Combine

/// Shared geometry that the SwiftUI overlay writes to and the hosting view reads from.
final class NotchGeometry: ObservableObject {
    /// The pill's frame in SwiftUI .global coordinates (window-relative, top-left origin).
    /// Not @Published — the mouse monitor reads it directly on each event,
    /// and publishing would cause a SwiftUI re-render feedback loop.
    var pillRect: CGRect = .zero
}

final class NotchWindow: NSPanel {
    let geometry = NotchGeometry()
    private var globalMonitor: Any?
    private var localMonitor: Any?

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
        self.ignoresMouseEvents = true
        self.appearance = AppearanceHelper.nsAppearance()

        let wrappedView = contentView
            .environmentObject(geometry)

        let hostingView = NSHostingView(rootView: AnyView(wrappedView))
        self.contentView = hostingView

        positionAtNotch()
        startMouseTracking()
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Mouse Pass-Through

    private func startMouseTracking() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateMousePassthrough()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateMousePassthrough()
            return event
        }
    }

    private func updateMousePassthrough() {
        let pillRect = geometry.pillRect
        guard !pillRect.isEmpty else {
            ignoresMouseEvents = true
            return
        }

        // pillRect is in SwiftUI .global coords = window-relative, top-left origin.
        // Convert mouse from screen coords → window coords → flip Y to top-left.
        let mouseScreen = NSEvent.mouseLocation
        let mouseInWindow = convertPoint(fromScreen: mouseScreen)
        let mouseSwiftUI = NSPoint(x: mouseInWindow.x, y: frame.height - mouseInWindow.y)

        let hitRect = pillRect.insetBy(dx: -20, dy: -20)
        ignoresMouseEvents = !hitRect.contains(mouseSwiftUI)
    }

    // MARK: - Frame

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

// MARK: - Appearance Helper

/// Centralized appearance resolution from UserDefaults.
/// Sets NSAppearance directly on windows — more reliable than
/// SwiftUI's preferredColorScheme which can get stuck.
enum AppearanceHelper {
    static func nsAppearance() -> NSAppearance? {
        let mode = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.appearanceMode) ?? "system"
        switch mode {
        case "dark": return NSAppearance(named: .darkAqua)
        case "light": return NSAppearance(named: .aqua)
        default: return nil // inherit system
        }
    }
}

// MARK: - UserDefaults KVO Key

extension UserDefaults {
    @objc dynamic var appearanceMode: String {
        string(forKey: Constants.UserDefaultsKeys.appearanceMode) ?? "system"
    }
}
