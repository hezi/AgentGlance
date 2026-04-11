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

    /// When true, the expanded content should appear above the pill instead of below.
    @Published var expandUpward = false

    /// Which horizontal edge the pill is snapped to, if any. Drives expand/collapse anchor.
    @Published var snappedEdge: HorizontalEdge = .center

    enum HorizontalEdge {
        case leading, center, trailing
    }
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
    private let edgeSnapDistance: CGFloat = 40
    private let defaultSnapDistance: CGFloat = 40
    /// Horizontal padding between window edge and the visible pill (glow + padding).
    private let pillInset: CGFloat = 40
    private var snapIndicatorWindow: NSWindow?
    private var cornerIndicatorWindows: [NSWindow] = []
    /// The pill center and window origin for the snap target, captured at drag start.
    private var snapTargetPillCenter: NSPoint = .zero
    private var snapTargetOrigin: NSPoint = .zero

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
        enforceActiveVibrancy()

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

    private let windowHeight: CGFloat = 900

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
        let h = max(frame.height, windowHeight)
        let savedX = UserDefaults.standard.object(forKey: Constants.UserDefaultsKeys.pillOffsetX) as? Double
        let savedPillTop = UserDefaults.standard.object(forKey: Constants.UserDefaultsKeys.pillOffsetY) as? Double

        var origin: NSPoint
        if let savedX, let savedPillTop {
            // Derive window origin from saved pill top and current height
            origin = NSPoint(x: savedX, y: savedPillTop - h)
        } else {
            let screen = targetScreen()
            origin = NSPoint(
                x: screen.frame.midX - w / 2,
                y: screen.visibleFrame.maxY - h
            )
        }

        // Clamp to screen bounds
        let screen = targetScreen()
        let sf = screen.frame
        origin.x = max(sf.minX, min(origin.x, sf.maxX - w))
        origin.y = max(sf.minY, min(origin.y, screen.visibleFrame.maxY - h))

        setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), display: true)
        updateExpandDirection()
        updateSnappedEdge()
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

    private func draggedOrigin() -> NSPoint {
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - dragStartMouseLocation.x
        let deltaY = currentMouse.y - dragStartMouseLocation.y
        var origin = NSPoint(
            x: dragStartWindowOrigin.x + deltaX,
            y: dragStartWindowOrigin.y + deltaY
        )

        let screen = targetScreen()
        let sf = screen.frame
        let w = frame.width

        // Show snap indicators on first drag movement
        if snapIndicatorWindow == nil {
            showSnapIndicator()
        }

        // Snap to default: check if the mouse is near the snap indicator (both axes)
        let nearDefaultX = abs(currentMouse.x - snapTargetPillCenter.x) < defaultSnapDistance
        let nearDefaultY = abs(currentMouse.y - snapTargetPillCenter.y) < defaultSnapDistance
        let nearDefault = nearDefaultX && nearDefaultY
        updateSnapIndicators(mouse: currentMouse, origin: origin)
        if nearDefault {
            return snapTargetOrigin
        }

        // Snap to top edge: mouse y near the snap indicator y (same height as default)
        // Applied independently so it composes with left/right edge snaps
        if nearDefaultY {
            origin.y = snapTargetOrigin.y
        }

        // Snap to screen edges — use pillInset so the visible pill aligns with the edge
        let pillLeft = origin.x + pillInset
        let pillRight = origin.x + w - pillInset
        if abs(pillLeft - sf.minX) < edgeSnapDistance {
            origin.x = sf.minX - pillInset
        } else if abs(pillRight - sf.maxX) < edgeSnapDistance {
            origin.x = sf.maxX - w + pillInset
        }

        // Bottom: mouse near screen bottom → snap pill bottom to screen bottom.
        // Use the same mouse-based approach as top snap.
        // The pill bottom in screen coords = mouse.y - (mouse grab offset from pill bottom).
        // At drag start the grab offset is constant, so we compute the snap origin
        // by figuring out where origin.y must be to put the pill bottom at sf.minY.
        let pillH = geometry.pillRect.height > 0 ? geometry.pillRect.height : 32
        let snapBottomOriginY = sf.minY - frame.height + 4 + pillH
        // The mouse y when pill bottom is at sf.minY:
        // mouse.y = dragStartMouse.y + (snapBottomOriginY - dragStartOrigin.y)
        let mouseYAtBottom = dragStartMouseLocation.y + (snapBottomOriginY - dragStartWindowOrigin.y)
        if abs(currentMouse.y - mouseYAtBottom) < edgeSnapDistance {
            origin.y = snapBottomOriginY
        }

        return origin
    }

    private func installDragMonitors() {
        ignoresMouseEvents = false // must accept events during drag

        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self, geometry.isDragging else { return event }
            setFrameOrigin(draggedOrigin())
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
            setFrameOrigin(draggedOrigin())
        }

        globalDragUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self, geometry.isDragging else { return }
            finishDrag()
        }
    }

    private func finishDrag() {
        geometry.isDragging = false
        removeDragMonitors()
        hideSnapIndicator()

        // Persist pill position: x is absolute, y is pill top (origin + height)
        let pillTop = Double(frame.origin.y + frame.height)
        UserDefaults.standard.set(Double(frame.origin.x), forKey: Constants.UserDefaultsKeys.pillOffsetX)
        UserDefaults.standard.set(pillTop, forKey: Constants.UserDefaultsKeys.pillOffsetY)

        updateExpandDirection()
        updateSnappedEdge()
    }

    private func updateSnappedEdge() {
        let screen = targetScreen()
        let sf = screen.frame
        let pillLeft = frame.origin.x + pillInset
        let pillRight = frame.origin.x + frame.width - pillInset

        if abs(pillLeft - sf.minX) < 2 {
            geometry.snappedEdge = .leading
        } else if abs(pillRight - sf.maxX) < 2 {
            geometry.snappedEdge = .trailing
        } else {
            geometry.snappedEdge = .center
        }
    }
    
    /// Expand upward only when snapped to the bottom edge.
    func updateExpandDirection() {
        // disable upwards for now
        return
        
        let screen = targetScreen()
        let sf = screen.frame
        let pillH = geometry.pillRect.height > 0 ? geometry.pillRect.height : 32
        let pillBottom = frame.origin.y + frame.height - 4 - pillH
        // Check if pill bottom is at (or very near) the screen bottom — i.e. bottom-snapped
        geometry.expandUpward = abs(pillBottom - sf.minY) < 2
    }

    private func removeDragMonitors() {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        if let m = dragUpMonitor { NSEvent.removeMonitor(m); dragUpMonitor = nil }
        if let m = globalDragMonitor { NSEvent.removeMonitor(m); globalDragMonitor = nil }
        if let m = globalDragUpMonitor { NSEvent.removeMonitor(m); globalDragUpMonitor = nil }
    }

    // MARK: - Snap Target Indicator

    private func makeIndicatorWindow(rect: NSRect, pillW: CGFloat, pillH: CGFloat) -> NSWindow {
        let indicator = NSWindow(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        indicator.level = .statusBar - 1
        indicator.isOpaque = false
        indicator.backgroundColor = .clear
        indicator.hasShadow = false
        indicator.ignoresMouseEvents = true
        indicator.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let liquidGlass = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.liquidGlass)
        let frost = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.glassFrost)
        let ghostView = SnapTargetGhostView(
            width: pillW, height: pillH,
            useGlass: liquidGlass, frost: frost > 0 ? frost : 0.3
        )
        let hostingView = NSHostingView(rootView: ghostView)
        hostingView.frame = NSRect(x: 0, y: 0, width: pillW, height: pillH)
        indicator.contentView = hostingView

        indicator.alphaValue = 0
        indicator.orderFront(nil)
        return indicator
    }

    private func showSnapIndicator() {
        let screen = targetScreen()
        let pillW: CGFloat = 200
        let pillH: CGFloat = 40
        let w = frame.width
        let h = frame.height
        let sf = screen.frame
        let vf = screen.visibleFrame

        // Default position: center-top
        let defaultOriginX = sf.midX - w / 2
        let defaultOriginY = vf.maxY - h
        let defaultPillX = defaultOriginX + (w - pillW) / 2
        let defaultPillY = defaultOriginY + h - pillH - 4

        snapTargetPillCenter = NSPoint(x: defaultPillX + pillW / 2, y: defaultPillY + pillH / 2)
        snapTargetOrigin = NSPoint(x: defaultOriginX, y: defaultOriginY)

        // Create default indicator
        let defaultIndicator = makeIndicatorWindow(
            rect: NSRect(x: defaultPillX, y: defaultPillY, width: pillW, height: pillH),
            pillW: pillW, pillH: pillH
        )
        snapIndicatorWindow = defaultIndicator

        // Corner positions: pill x at left/right edges, pill y at top/bottom
        let leftPillX = sf.minX
        let rightPillX = sf.maxX - pillW
        let topPillY = defaultPillY  // same as default top
        let bottomPillY = sf.minY

        let corners: [NSRect] = [
            NSRect(x: leftPillX, y: topPillY, width: pillW, height: pillH),     // top-left
            NSRect(x: rightPillX, y: topPillY, width: pillW, height: pillH),    // top-right
            NSRect(x: leftPillX, y: bottomPillY, width: pillW, height: pillH),  // bottom-left
            NSRect(x: rightPillX, y: bottomPillY, width: pillW, height: pillH), // bottom-right
        ]

        for rect in corners {
            let corner = makeIndicatorWindow(rect: rect, pillW: pillW, pillH: pillH)
            cornerIndicatorWindows.append(corner)
        }

        // Fade all in
        let allIndicators = [defaultIndicator] + cornerIndicatorWindows
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            for ind in allIndicators {
                ind.animator().alphaValue = 1
            }
        }
    }

    private func hideSnapIndicator() {
        let allIndicators = [snapIndicatorWindow].compactMap { $0 } + cornerIndicatorWindows
        guard !allIndicators.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            for ind in allIndicators {
                ind.animator().alphaValue = 0
            }
        }, completionHandler: {
            for ind in allIndicators {
                ind.orderOut(nil)
            }
        })
        snapIndicatorWindow = nil
        cornerIndicatorWindows.removeAll()
    }

    private func updateSnapIndicators(mouse: NSPoint, origin: NSPoint) {
        let screen = targetScreen()
        let sf = screen.frame
        let w = frame.width

        // Pill edge distances from screen edges (used for corner proximity)
        let pillLeft = origin.x + pillInset
        let pillRight = origin.x + w - pillInset
        let leftDist = abs(pillLeft - sf.minX)
        let rightDist = abs(pillRight - sf.maxX)
        // Top/bottom use mouse-based y proximity to the snap indicator positions
        let topDist = abs(mouse.y - snapTargetPillCenter.y)
        let pillH = geometry.pillRect.height > 0 ? geometry.pillRect.height : 32
        let snapBottomOriginY = sf.minY - frame.height + 4 + pillH
        let mouseYAtBottom = dragStartMouseLocation.y + (snapBottomOriginY - dragStartWindowOrigin.y)
        let bottomDist = abs(mouse.y - mouseYAtBottom)

        let fadeRange: CGFloat = 200

        // Default indicator: mouse proximity
        if let defaultIndicator = snapIndicatorWindow {
            let center = NSPoint(x: defaultIndicator.frame.midX, y: defaultIndicator.frame.midY)
            let dist = hypot(mouse.x - center.x, mouse.y - center.y)
            let proximity = max(0, min(1, 1 - dist / fadeRange))
            applyProximityColor(to: defaultIndicator, proximity: proximity)
        }

        // Corner indicators: proximity based on how close pill edges are to screen edges
        // Order: top-left, top-right, bottom-left, bottom-right
        let cornerProximities: [(CGFloat, CGFloat)] = [
            (leftDist, topDist),
            (rightDist, topDist),
            (leftDist, bottomDist),
            (rightDist, bottomDist),
        ]

        for (i, indicator) in cornerIndicatorWindows.enumerated() {
            guard i < cornerProximities.count else { continue }
            let (xDist, yDist) = cornerProximities[i]
            let maxDist = max(xDist, yDist)
            let proximity = max(0, min(1, 1 - maxDist / fadeRange))
            applyProximityColor(to: indicator, proximity: proximity)
        }
    }

    private func applyProximityColor(to indicator: NSWindow, proximity: CGFloat) {
        guard let view = indicator.contentView else { return }
        view.wantsLayer = true
        view.layer?.borderWidth = 4
        view.layer?.cornerRadius = 18
        // Gray at rest, blending to green as proximity increases
        let r = 0.5 * (1 - proximity)
        let g = 0.5 * (1 - proximity) + proximity
        let b = 0.5 * (1 - proximity)
        view.layer?.borderColor = CGColor(red: r, green: g, blue: b, alpha: 0.4 + proximity * 0.4)
        view.layer?.backgroundColor = CGColor(red: r, green: g, blue: b, alpha: 0.05 + proximity * 0.1)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Liquid Glass Fix

    /// Force all NSVisualEffectViews to stay active (live blur) even when the window isn't key.
    /// Without this, macOS freezes the blur snapshot when the panel loses focus.
    func enforceActiveVibrancy() {
        guard let contentView else { return }
        // Defer slightly so SwiftUI has time to install the visual effect views
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setVibrancyActive(in: contentView)
        }
    }

    private func setVibrancyActive(in view: NSView) {
        if let vev = view as? NSVisualEffectView {
            vev.state = .active
        }
        for subview in view.subviews {
            setVibrancyActive(in: subview)
        }
    }

    override func update() {
        super.update()
        // Re-enforce after SwiftUI view updates (it can recreate visual effect views)
        enforceActiveVibrancy()
    }
}

// MARK: - Snap Target Ghost View

/// A SwiftUI view that uses NotchBackgroundModifier to match the pill's appearance.
private struct SnapTargetGhostView: View {
    let width: CGFloat
    let height: CGFloat
    let useGlass: Bool
    let frost: Double

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .modifier(NotchBackgroundModifier(
                cornerRadius: 18,
                glowColor: .gray,
                glowRadius: 4,
                useGlass: useGlass,
                fillColor: .gray,
                frost: frost * 0.5
            ))
            .opacity(0.5)
    }
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
