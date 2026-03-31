import AppKit
import SwiftUI
import Combine

/// Shared geometry that the SwiftUI overlay writes to and the hosting view reads from.
final class NotchGeometry: ObservableObject {
    /// The pill's frame in SwiftUI .global coordinates (window-relative, top-left origin).
    /// Not @Published — the mouse monitor reads it directly on each event,
    /// and publishing would cause a SwiftUI re-render feedback loop.
    var pillRect: CGRect = .zero

    /// True while the user is dragging the pill. Suppresses hover-expand.
    var isDragging = false
}

final class NotchWindow: NSPanel {
    let geometry = NotchGeometry()

    // Mouse pass-through monitors
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Drag handling
    private var dragMonitor: Any?
    private var dragUpMonitor: Any?
    private var globalDragMonitor: Any?
    private var globalDragUpMonitor: Any?
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero
    private let snapDistance: CGFloat = 150

    // Follow-cursor screen tracking
    private var lastScreenID: CGDirectDisplayID = 0

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

        // Reposition when displays are added/removed/rearranged
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.positionAtNotch()
        }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        removeDragMonitors()
    }

    // MARK: - Screen Selection

    private func targetScreen() -> NSScreen {
        let mode = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.screenSelectionMode) ?? "mainScreen"

        switch mode {
        case "followCursor":
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                ?? NSScreen.main ?? NSScreen.screens.first!

        case "specific":
            let savedID = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.selectedScreenID) ?? ""
            if let id = UInt32(savedID),
               let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                return screen
            }
            return NSScreen.main ?? NSScreen.screens.first!

        default: // "mainScreen"
            return NSScreen.main ?? NSScreen.screens.first!
        }
    }

    // MARK: - Positioning

    /// Window must fit the widest possible pill + padding + glow.
    private var windowWidth: CGFloat {
        let expandedWidth = CGFloat(UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.expandedWidth))
        let pillWidth = max(expandedWidth, 340)
        return pillWidth + 80 // 20 padding + ~20 glow each side
    }

    private let windowHeight: CGFloat = 400

    private func defaultWindowOrigin() -> NSPoint {
        let screen = targetScreen()
        let screenFrame = screen.frame
        let w = windowWidth
        let x = screenFrame.midX - w / 2
        // Use visibleFrame.maxY to position below menu bar + hardware notch
        let y = screen.visibleFrame.maxY - windowHeight
        return NSPoint(x: x, y: y)
    }

    func positionAtNotch() {
        let w = windowWidth
        var origin = defaultWindowOrigin()
        let offsetX = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.pillOffsetX)
        let offsetY = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.pillOffsetY)
        origin.x += offsetX
        origin.y += offsetY

        // Clamp to screen bounds — use visibleFrame so pill can't be dragged behind notch
        let screen = targetScreen()
        let sf = screen.frame
        origin.x = max(sf.minX, min(origin.x, sf.maxX - w))
        origin.y = max(sf.minY, min(origin.y, screen.visibleFrame.maxY - windowHeight))

        setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: windowHeight), display: true)
    }

    // MARK: - Mouse Pass-Through, Follow-Cursor & Drag

    private func startMouseTracking() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateMousePassthrough()
            self?.checkScreenChange()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved {
                updateMousePassthrough()
                checkScreenChange()
            } else if event.type == .leftMouseDown, !geometry.isDragging, event.window === self {
                handleMouseDown(event)
            }
            return event
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        let mouseInWindow = event.locationInWindow
        let mouseSwiftUI = NSPoint(x: mouseInWindow.x, y: frame.height - mouseInWindow.y)
        let pillRect = geometry.pillRect
        guard !pillRect.isEmpty, pillRect.contains(mouseSwiftUI) else { return }

        geometry.isDragging = true
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = frame.origin
        installDragMonitors()
    }

    private func updateMousePassthrough() {
        guard !geometry.isDragging else { return }

        let pillRect = geometry.pillRect
        guard !pillRect.isEmpty else {
            ignoresMouseEvents = true
            return
        }

        let mouseScreen = NSEvent.mouseLocation
        let mouseInWindow = convertPoint(fromScreen: mouseScreen)
        let mouseSwiftUI = NSPoint(x: mouseInWindow.x, y: frame.height - mouseInWindow.y)

        let hitRect = pillRect.insetBy(dx: -20, dy: -20)
        ignoresMouseEvents = !hitRect.contains(mouseSwiftUI)
    }

    private func checkScreenChange() {
        let mode = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.screenSelectionMode) ?? "mainScreen"
        guard mode == "followCursor" else { return }

        let mouseLocation = NSEvent.mouseLocation
        guard let currentScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
        let currentID = currentScreen.displayID

        if currentID != lastScreenID {
            lastScreenID = currentID
            positionAtNotch()
        }
    }

    private func installDragMonitors() {
        ignoresMouseEvents = false // must accept events during drag

        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self, geometry.isDragging else { return event }
            let currentMouse = NSEvent.mouseLocation
            let deltaX = currentMouse.x - dragStartMouseLocation.x
            let deltaY = currentMouse.y - dragStartMouseLocation.y
            setFrameOrigin(NSPoint(
                x: dragStartWindowOrigin.x + deltaX,
                y: dragStartWindowOrigin.y + deltaY
            ))
            return event
        }

        dragUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, geometry.isDragging else { return event }
            finishDrag()
            return event
        }

        // Global monitors for when mouse leaves the window during fast drag
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            guard let self, geometry.isDragging else { return }
            let currentMouse = NSEvent.mouseLocation
            let deltaX = currentMouse.x - dragStartMouseLocation.x
            let deltaY = currentMouse.y - dragStartMouseLocation.y
            setFrameOrigin(NSPoint(
                x: dragStartWindowOrigin.x + deltaX,
                y: dragStartWindowOrigin.y + deltaY
            ))
        }

        globalDragUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self, geometry.isDragging else { return }
            finishDrag()
        }
    }

    private func finishDrag() {
        geometry.isDragging = false
        removeDragMonitors()

        let defaultOrigin = defaultWindowOrigin()
        let currentOrigin = frame.origin
        let distance = hypot(currentOrigin.x - defaultOrigin.x, currentOrigin.y - defaultOrigin.y)

        if distance < snapDistance {
            // Snap back to default with animation
            UserDefaults.standard.set(0.0, forKey: Constants.UserDefaultsKeys.pillOffsetX)
            UserDefaults.standard.set(0.0, forKey: Constants.UserDefaultsKeys.pillOffsetY)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrameOrigin(defaultOrigin)
            }
        } else {
            // Persist custom offset
            let offsetX = currentOrigin.x - defaultOrigin.x
            let offsetY = currentOrigin.y - defaultOrigin.y
            UserDefaults.standard.set(offsetX, forKey: Constants.UserDefaultsKeys.pillOffsetX)
            UserDefaults.standard.set(offsetY, forKey: Constants.UserDefaultsKeys.pillOffsetY)
        }
    }

    private func removeDragMonitors() {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        if let m = dragUpMonitor { NSEvent.removeMonitor(m); dragUpMonitor = nil }
        if let m = globalDragMonitor { NSEvent.removeMonitor(m); globalDragMonitor = nil }
        if let m = globalDragUpMonitor { NSEvent.removeMonitor(m); globalDragUpMonitor = nil }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - NSScreen Extension

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}

// MARK: - Appearance Helper

enum AppearanceHelper {
    static func nsAppearance() -> NSAppearance? {
        let mode = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.appearanceMode) ?? "system"
        switch mode {
        case "dark": return NSAppearance(named: .darkAqua)
        case "light": return NSAppearance(named: .aqua)
        default: return nil
        }
    }
}

// MARK: - UserDefaults KVO Keys

extension UserDefaults {
    @objc dynamic var appearanceMode: String {
        string(forKey: Constants.UserDefaultsKeys.appearanceMode) ?? "system"
    }

    @objc dynamic var screenSelectionMode: String {
        string(forKey: Constants.UserDefaultsKeys.screenSelectionMode) ?? "mainScreen"
    }
}
