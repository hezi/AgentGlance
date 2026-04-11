import SwiftUI

// MARK: - Experimental SwiftUI-managed window for the notch overlay
// Uses a real macOS window with the NotchHeaderBar as a centered toolbar
// and NotchOverlay content below.

@available(macOS 15.0, *)
struct ExperimentalNotchScene: Scene {
    var appState: AppState

    var body: some Scene {
        WindowGroup(id: "experimental-notch") {
            ExperimentalNotchContent(appState: appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.top)
        .windowLevel(.floating)
    }
}

@available(macOS 15.0, *)
private struct ExperimentalNotchContent: View {
    var appState: AppState
    @StateObject private var geometry = NotchGeometry()
    @AppStorage(Constants.UserDefaultsKeys.notchFontScale) private var fontScaleRaw = NotchFontScale.m.rawValue

    private var fontScale: NotchFontScale {
        NotchFontScale(rawValue: fontScaleRaw) ?? .m
    }

    @State private var isPinned = false
    @State private var isExpanded = false
    @State private var titleBarHeight: CGFloat = 0
    @State private var expandedHeight: CGFloat = 200
    @State private var isResizing = false
    @State private var isAnimating = false
    @AppStorage(Constants.UserDefaultsKeys.liquidGlass) private var liquidGlass = false
    @AppStorage(Constants.UserDefaultsKeys.glassFrost) private var glassFrost = 0.3
    @AppStorage(Constants.UserDefaultsKeys.appearanceMode) private var appearanceMode = "system"
    @Environment(\.colorScheme) private var colorScheme

    private var bg: Color { colorScheme == .dark ? .black : .white }

    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "dark": .dark
        case "light": .light
        default: nil // system
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row: pin (left) — status (center) — settings (right)
            HStack(spacing: 4) {
                Button {
                    isPinned.toggle()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                        .rotationEffect(.degrees(isPinned ? 0 : 45))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                NotchHeaderBar(
                    sessions: appState.sessionManager.activeSessions,
                    fontScale: fontScale
                )
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: 4)

                Button {
                    appState.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: fontScale.barHeight)

            ScrollView {
                NotchOverlay(
                    sessionManager: appState.sessionManager,
                    hookServer: appState.hookServer,
                    appState: appState,
                    useSystemChrome: true
                )
                .environmentObject(geometry)
            }
            .scrollIndicators(.hidden)
            .opacity(isExpanded ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: isExpanded)

            Spacer(minLength: 0)
        }
        .frame(minWidth: 300, idealWidth: 400,
               minHeight: max(0, fontScale.barHeight - titleBarHeight),
               alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !isResizing, !isAnimating else { return }
            // Ignore hover events when mouse is near the resize handle (only when expanded)
            if hovering && isExpanded && isMouseOnResizeHandle() { return }
            if hovering {
                expandWindow()
            } else if !isPinned {
                collapseWindow()
            }
        }
        .clipped()
        .modifier(WindowBackgroundModifier(useGlass: liquidGlass, fillColor: bg, frost: glassFrost))
        .ignoresSafeArea()
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(WindowAccessor(
            titleBarHeight: $titleBarHeight,
            expandedHeight: $expandedHeight,
            isResizing: $isResizing,
            isAnimating: $isAnimating,
            isExpanded: $isExpanded,
            barHeight: fontScale.barHeight
        ))
        .preferredColorScheme(preferredScheme)
    }

    private func isMouseOnResizeHandle() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("experimental") == true }) else { return false }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        // Bottom 6pt of the window is the resize handle zone
        return mouseInWindow.y < 6
    }

    private func expandWindow() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("experimental") == true }) else { return }
        isAnimating = true
        isExpanded = true
        var frame = window.frame
        frame.origin.y -= (expandedHeight - frame.height)
        frame.size.height = expandedHeight
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: {
            isAnimating = false
        })
    }

    private func collapseWindow() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("experimental") == true }) else { return }
        isAnimating = true
        isExpanded = false
        let newHeight = fontScale.barHeight
        var frame = window.frame
        frame.origin.y += (frame.height - newHeight)
        frame.size.height = newHeight
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: {
            isAnimating = false
        })
    }
}

// MARK: - Window Accessor

/// Bridges into the NSWindow to hide traffic lights and programmatically
/// set the window height below the OS-enforced minimum.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var titleBarHeight: CGFloat
    @Binding var expandedHeight: CGFloat
    @Binding var isResizing: Bool
    @Binding var isAnimating: Bool
    @Binding var isExpanded: Bool
    var barHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(expandedHeight: $expandedHeight, isResizing: $isResizing, isAnimating: $isAnimating)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.minSize = CGSize(width: 0, height: 0)
            window.backgroundColor = .clear
            titleBarHeight = window.frame.height - window.contentLayoutRect.height

            // Restore saved frame
            if let data = UserDefaults.standard.data(forKey: "experimentalWindowFrame"),
               let rect = try? JSONDecoder().decode(CodableRect.self, from: data) {
                window.setFrame(rect.nsRect, display: true)
                expandedHeight = rect.nsRect.height
                isExpanded = rect.nsRect.height > barHeight
            }

            context.coordinator.observeWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class Coordinator: NSObject {
        @Binding var expandedHeight: CGFloat
        @Binding var isResizing: Bool
        @Binding var isAnimating: Bool

        // Drag & snap state
        private weak var window: NSWindow?
        private var isDragging = false
        private var dragStartMouseLocation: NSPoint = .zero
        private var dragStartWindowOrigin: NSPoint = .zero
        private var dragMonitor: Any?
        private var dragUpMonitor: Any?
        private var globalDragMonitor: Any?
        private var globalDragUpMonitor: Any?

        // Snap indicators
        private var snapIndicatorWindow: NSWindow?
        private var cornerIndicatorWindows: [NSWindow] = []
        private var snapTargetPillCenter: NSPoint = .zero
        private var snapTargetOrigin: NSPoint = .zero
        private let edgeSnapDistance: CGFloat = 40
        private let defaultSnapDistance: CGFloat = 40

        init(expandedHeight: Binding<CGFloat>, isResizing: Binding<Bool>, isAnimating: Binding<Bool>) {
            _expandedHeight = expandedHeight
            _isResizing = isResizing
            _isAnimating = isAnimating
        }

        func observeWindow(_ window: NSWindow) {
            self.window = window
            // Disable native drag — we handle it ourselves for snapping
            window.isMovableByWindowBackground = false

            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillResize),
                name: NSWindow.willStartLiveResizeNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResize),
                name: NSWindow.didEndLiveResizeNotification, object: window
            )

            // Install mouse down monitor for drag initiation
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event)
                return event
            }

        }

        // MARK: - Drag Handling

        private func handleMouseDown(_ event: NSEvent) {
            guard let window, event.window === window, !isDragging else { return }
            // Don't drag from resize handle zone (bottom 6pt)
            let mouseInWindow = event.locationInWindow
            guard mouseInWindow.y > 6 else { return }

            isDragging = true
            dragStartMouseLocation = NSEvent.mouseLocation
            dragStartWindowOrigin = window.frame.origin
            showSnapIndicators()
            installDragMonitors()
        }

        private func installDragMonitors() {
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                self?.handleDrag()
                return event
            }
            dragUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.finishDrag()
                return event
            }
            globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
                self?.handleDrag()
            }
            globalDragUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                self?.finishDrag()
            }
        }

        private func handleDrag() {
            guard isDragging, let window else { return }
            let origin = draggedOrigin()
            window.setFrameOrigin(origin)
        }

        private func finishDrag() {
            isDragging = false
            removeDragMonitors()
            hideSnapIndicators()
            if let window {
                saveFrame(window)
            }
        }

        private func removeDragMonitors() {
            if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
            if let m = dragUpMonitor { NSEvent.removeMonitor(m); dragUpMonitor = nil }
            if let m = globalDragMonitor { NSEvent.removeMonitor(m); globalDragMonitor = nil }
            if let m = globalDragUpMonitor { NSEvent.removeMonitor(m); globalDragUpMonitor = nil }
        }

        // MARK: - Snap Logic

        private func draggedOrigin() -> NSPoint {
            guard let window else { return .zero }
            let currentMouse = NSEvent.mouseLocation
            let deltaX = currentMouse.x - dragStartMouseLocation.x
            let deltaY = currentMouse.y - dragStartMouseLocation.y
            var origin = NSPoint(
                x: dragStartWindowOrigin.x + deltaX,
                y: dragStartWindowOrigin.y + deltaY
            )

            guard let screen = NSScreen.main else { return origin }
            let sf = screen.frame
            let w = window.frame.width

            // Snap to default position
            let nearDefaultX = abs(currentMouse.x - snapTargetPillCenter.x) < defaultSnapDistance
            let nearDefaultY = abs(currentMouse.y - snapTargetPillCenter.y) < defaultSnapDistance
            updateSnapIndicatorColors(mouse: currentMouse, origin: origin)
            if nearDefaultX && nearDefaultY {
                return snapTargetOrigin
            }

            // Snap to top edge (same y as default)
            if nearDefaultY {
                origin.y = snapTargetOrigin.y
            }

            // Snap to left/right screen edges
            if abs(origin.x - sf.minX) < edgeSnapDistance {
                origin.x = sf.minX
            } else if abs(origin.x + w - sf.maxX) < edgeSnapDistance {
                origin.x = sf.maxX - w
            }

            // Snap to bottom
            if abs(origin.y - sf.minY) < edgeSnapDistance {
                origin.y = sf.minY
            }

            return origin
        }

        // MARK: - Snap Indicators

        private func showSnapIndicators() {
            guard let window, let screen = NSScreen.main else { return }
            let pillW: CGFloat = window.frame.width
            let pillH: CGFloat = 40
            let w = window.frame.width
            let h = window.frame.height
            let sf = screen.frame
            let vf = screen.visibleFrame

            // Default: center-top
            let defaultOriginX = sf.midX - w / 2
            let defaultOriginY = vf.maxY - h
            let defaultPillX = defaultOriginX
            let defaultPillY = defaultOriginY + h - pillH

            snapTargetPillCenter = NSPoint(x: defaultPillX + pillW / 2, y: defaultPillY + pillH / 2)
            snapTargetOrigin = NSPoint(x: defaultOriginX, y: defaultOriginY)

            let defaultIndicator = makeIndicatorWindow(
                rect: NSRect(x: defaultPillX, y: defaultPillY, width: pillW, height: pillH),
                pillW: pillW, pillH: pillH
            )
            snapIndicatorWindow = defaultIndicator

            // Corners
            let corners: [NSRect] = [
                NSRect(x: sf.minX, y: defaultPillY, width: pillW, height: pillH),
                NSRect(x: sf.maxX - pillW, y: defaultPillY, width: pillW, height: pillH),
                NSRect(x: sf.minX, y: sf.minY, width: pillW, height: pillH),
                NSRect(x: sf.maxX - pillW, y: sf.minY, width: pillW, height: pillH),
            ]

            for rect in corners {
                cornerIndicatorWindows.append(makeIndicatorWindow(rect: rect, pillW: pillW, pillH: pillH))
            }

            let all = [defaultIndicator] + cornerIndicatorWindows
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                for ind in all { ind.animator().alphaValue = 1 }
            }
        }

        private func hideSnapIndicators() {
            let all = [snapIndicatorWindow].compactMap { $0 } + cornerIndicatorWindows
            guard !all.isEmpty else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                for ind in all { ind.animator().alphaValue = 0 }
            }, completionHandler: {
                for ind in all { ind.orderOut(nil) }
            })
            snapIndicatorWindow = nil
            cornerIndicatorWindows.removeAll()
        }

        private func makeIndicatorWindow(rect: NSRect, pillW: CGFloat, pillH: CGFloat) -> NSWindow {
            let indicator = NSWindow(
                contentRect: rect, styleMask: .borderless,
                backing: .buffered, defer: false
            )
            indicator.level = .floating - 1
            indicator.isOpaque = false
            indicator.backgroundColor = .clear
            indicator.hasShadow = false
            indicator.ignoresMouseEvents = true
            indicator.collectionBehavior = [.canJoinAllSpaces, .stationary]

            let shapeView = NSView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
            shapeView.wantsLayer = true
            shapeView.layer?.cornerRadius = 12
            shapeView.layer?.borderWidth = 4
            shapeView.layer?.borderColor = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.4)
            shapeView.layer?.backgroundColor = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.05)
            indicator.contentView = shapeView

            indicator.alphaValue = 0
            indicator.orderFront(nil)
            return indicator
        }

        private func updateSnapIndicatorColors(mouse: NSPoint, origin: NSPoint) {
            guard let window, let screen = NSScreen.main else { return }
            let sf = screen.frame
            let w = window.frame.width
            let leftDist = abs(origin.x - sf.minX)
            let rightDist = abs(origin.x + w - sf.maxX)
            let topDist = abs(mouse.y - snapTargetPillCenter.y)
            let bottomDist = abs(origin.y - sf.minY)
            let fadeRange: CGFloat = 200

            if let ind = snapIndicatorWindow {
                let center = NSPoint(x: ind.frame.midX, y: ind.frame.midY)
                let dist = hypot(mouse.x - center.x, mouse.y - center.y)
                let prox = max(0, min(1, 1 - dist / fadeRange))
                applyProximityColor(to: ind, proximity: prox)
            }

            let cornerDists: [(CGFloat, CGFloat)] = [
                (leftDist, topDist), (rightDist, topDist),
                (leftDist, bottomDist), (rightDist, bottomDist),
            ]
            for (i, ind) in cornerIndicatorWindows.enumerated() {
                guard i < cornerDists.count else { continue }
                let maxDist = max(cornerDists[i].0, cornerDists[i].1)
                let prox = max(0, min(1, 1 - maxDist / fadeRange))
                applyProximityColor(to: ind, proximity: prox)
            }
        }

        private func applyProximityColor(to indicator: NSWindow, proximity: CGFloat) {
            guard let view = indicator.contentView else { return }
            view.wantsLayer = true
            let r = 0.5 * (1 - proximity)
            let g = 0.5 * (1 - proximity) + proximity
            let b = 0.5 * (1 - proximity)
            view.layer?.borderColor = CGColor(red: r, green: g, blue: b, alpha: 0.4 + proximity * 0.4)
            view.layer?.backgroundColor = CGColor(red: r, green: g, blue: b, alpha: 0.05 + proximity * 0.1)
        }

        // MARK: - Resize Notifications

        @objc private func windowWillResize(_ notification: Notification) {
            guard !isAnimating else { return }
            isResizing = true
        }

        @objc private func windowDidResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            guard !isAnimating else { return }
            isResizing = false
            expandedHeight = window.frame.height
            saveFrame(window)
        }

        private func saveFrame(_ window: NSWindow) {
            let rect = CodableRect(nsRect: window.frame)
            if let data = try? JSONEncoder().encode(rect) {
                UserDefaults.standard.set(data, forKey: "experimentalWindowFrame")
            }
        }
    }
}

// MARK: - Codable NSRect

private struct CodableRect: Codable {
    let x, y, width, height: CGFloat

    var nsRect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }

    init(nsRect: NSRect) {
        x = nsRect.origin.x
        y = nsRect.origin.y
        width = nsRect.size.width
        height = nsRect.size.height
    }
}

// MARK: - Window Background

/// Applies the appropriate background based on appearance settings.
private struct WindowBackgroundModifier: ViewModifier {
    let useGlass: Bool
    let fillColor: Color
    let frost: Double

    func body(content: Content) -> some View {
        if useGlass {
            if #available(macOS 26, *) {
                content
                    .background(fillColor.opacity(frost))
                    .glassEffect(in: .rect)
            } else {
                content
                    .background(.ultraThinMaterial)
                    .overlay(fillColor.opacity(frost))
            }
        } else {
            content
                .background(fillColor)
        }
    }
}
