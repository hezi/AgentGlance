import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import Sparkle

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, server, remote, permissions, about
    #if DEBUG
    case debug
    #endif

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .server: "Integrations"
        case .remote: "Remote"
        case .permissions: "Permissions"
        case .about: "About"
        #if DEBUG
        case .debug: "Debug"
        #endif
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .appearance: "textformat.size"
        case .server: "network"
        case .remote: "iphone"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        #if DEBUG
        case .debug: "ant"
        #endif
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
    var updater: SPUUpdater? = nil
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            Divider()

            Group {
                switch selectedTab {
                case .general: GeneralPane(appState: appState)
                case .appearance: AppearancePane()
                case .server: ServerPane(appState: appState)
                case .remote: RemotePane(appState: appState)
                case .permissions: PermissionsPane()
                case .about: AboutPane(updater: updater)
                #if DEBUG
                case .debug: DebugPane(appState: appState)
                #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            // Defer so the window exists
            DispatchQueue.main.async {
                resizeWindow(for: selectedTab)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            resizeWindow(for: tab)
        }
    }

    private func resizeWindow(for tab: SettingsTab) {
        guard let window = NSApp.windows.first(where: { $0.title == "AgentGlance Settings" }) else { return }

        let idealHeight: CGFloat = switch tab {
        case .general: 700
        case .appearance: 580
        case .server: 300
        case .remote: 500
        case .permissions: 300
        case .about: 460
        #if DEBUG
        case .debug: 500
        #endif
        }

        // Cap to 80% of screen height
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) * 0.8
        let newHeight = min(idealHeight, maxHeight)

        var frame = window.frame
        // Resize from the top (adjust origin so top edge stays put)
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var appState: AppState
    @AppStorage(Constants.UserDefaultsKeys.sleepPreventionEnabled) private var sleepPrevention = true
    @AppStorage(Constants.UserDefaultsKeys.soundEnabled) private var soundEnabled = true
    @AppStorage(Constants.UserDefaultsKeys.osNotificationsEnabled) private var osNotificationsEnabled = true
    @AppStorage(Constants.UserDefaultsKeys.autoExpandOnApproval) private var autoExpand = false
    @AppStorage(Constants.UserDefaultsKeys.suppressExpansionWhenInTerminal) private var suppressInTerminal = false
    @AppStorage(Constants.UserDefaultsKeys.showAllApprovals) private var showAllApprovals = false
    @AppStorage(Constants.UserDefaultsKeys.screenSelectionMode) private var screenMode = "mainScreen"
    @AppStorage(Constants.UserDefaultsKeys.selectedScreenID) private var selectedScreenID = ""
    @AppStorage(Constants.UserDefaultsKeys.keyboardNavMode) private var navMode = KeyboardNavMode.arrows.rawValue
    @AppStorage(Constants.UserDefaultsKeys.sessionGroupMode) private var groupModeRaw = SessionGroupMode.none.rawValue
    @AppStorage(Constants.UserDefaultsKeys.groupSortMode) private var sortModeRaw = GroupSortMode.lastUpdated.rawValue
    @AppStorage(Constants.UserDefaultsKeys.windowMode) private var windowMode = "systemChrome"
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Display") {
                Picker("Window mode", selection: $windowMode) {
                    Text("Classic (Notch Overlay)").tag("classic")
                    Text("System Chrome").tag("systemChrome")
                }
                .onChange(of: windowMode) { _, _ in
                    appState.refreshNotchWindow()
                }
                Picker("Show notch on", selection: $screenMode) {
                    Text("Main Screen").tag("mainScreen")
                    Text("Follow Cursor").tag("followCursor")
                    Text("Specific Screen").tag("specific")
                }

                if screenMode == "specific" {
                    Picker("Screen", selection: $selectedScreenID) {
                        ForEach(NSScreen.screens, id: \.displayID) { screen in
                            Text(screen.localizedName).tag(String(screen.displayID))
                        }
                    }
                    .onChange(of: selectedScreenID) { _, _ in
                        appState.resetPillPosition()
                    }
                }

                Button("Reset Position") {
                    appState.resetPillPosition()
                }
                .controlSize(.small)
            }

            Section("Session Grouping") {
                Picker("Group by", selection: $groupModeRaw) {
                    ForEach(SessionGroupMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                if SessionGroupMode(rawValue: groupModeRaw) != SessionGroupMode.none {
                    Picker("Sort groups", selection: $sortModeRaw) {
                        ForEach(GroupSortMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                }
            }

            Section("Behavior") {
                Toggle("Prevent sleep while an agent is working", isOn: $sleepPrevention)
                    .onChange(of: sleepPrevention) { _, newValue in
                        appState.sleepPreventionEnabled = newValue
                    }
                Toggle("Show system notifications", isOn: $osNotificationsEnabled)
                Toggle("Play sound on notifications", isOn: $soundEnabled)
                Toggle("Auto-expand notch on approval requests", isOn: $autoExpand)
                if autoExpand {
                    Toggle("Don't auto-expand when terminal is focused", isOn: $suppressInTerminal)
                        .padding(.leading, 16)
                }
                Toggle("Show all queued approvals at once", isOn: $showAllApprovals)
            }

            Section("Hotkey") {
                LabeledContent("Global hotkey") {
                    HStack(spacing: 8) {
                        KeyboardShortcuts.Recorder(for: .toggleOverlay)

                        if KeyboardShortcuts.getShortcut(for: .toggleOverlay) != KeyboardShortcuts.Name.toggleOverlay.defaultShortcut {
                            Button("Reset") {
                                KeyboardShortcuts.reset(.toggleOverlay)
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Picker("Keyboard navigation", selection: $navMode) {
                    ForEach(KeyboardNavMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                Text(KeyboardNavMode(rawValue: navMode)?.description ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @AppStorage(Constants.UserDefaultsKeys.showTextInNotch) private var showText = true
    @AppStorage(Constants.UserDefaultsKeys.fitNotchToText) private var fitToText = false
    @AppStorage(Constants.UserDefaultsKeys.notchFontScale) private var fontScaleRaw = NotchFontScale.m.rawValue
    @AppStorage(Constants.UserDefaultsKeys.liquidGlass) private var liquidGlass = false
    @AppStorage(Constants.UserDefaultsKeys.glassFrost) private var glassFrost = 0.3
    @AppStorage(Constants.UserDefaultsKeys.expandedWidth) private var expandedWidth = 340.0
    @AppStorage(Constants.UserDefaultsKeys.appearanceMode) private var appearanceMode = "system"
    @State private var headerTemplate = DisplayTemplate.load(
        forKey: Constants.UserDefaultsKeys.headerTemplate,
        default: .defaultHeader
    )
    @State private var rowTitleTemplate = DisplayTemplate.load(
        forKey: Constants.UserDefaultsKeys.rowTitleTemplate,
        default: .defaultRowTitle
    )
    @State private var rowDetailTemplate = DisplayTemplate.load(
        forKey: Constants.UserDefaultsKeys.rowDetailTemplate,
        default: .defaultRowDetail
    )

    private var maxExpandedWidth: Double {
        Double(NSScreen.main?.frame.width ?? 1920) * 0.25
    }

    private var fontScale: NotchFontScale {
        NotchFontScale(rawValue: fontScaleRaw) ?? .m
    }

    var body: some View {
        Form {
            Section("Preview") {
                NotchPreview(fontScale: fontScale, fitToText: fitToText, showText: showText, liquidGlass: liquidGlass, glassFrost: glassFrost, headerTemplate: headerTemplate, rowTitleTemplate: rowTitleTemplate, rowDetailTemplate: rowDetailTemplate)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }

            Section("Theme") {
                Picker("Appearance", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
            }

            Section("Notch Pill") {
                Toggle("Show status text", isOn: $showText)
                Toggle("Fit width to text", isOn: $fitToText)
                Toggle("Liquid Glass", isOn: $liquidGlass)
                if liquidGlass {
                    LabeledContent("Frost") {
                        Slider(value: $glassFrost, in: 0...0.7, step: 0.05)
                            .frame(width: 160)
                    }
                }
            }

            Section("Expanded View") {
                LabeledContent("Width: \(Int(expandedWidth))px") {
                    Slider(value: $expandedWidth, in: 280...maxExpandedWidth+280, step: 10)
                        .frame(width: 180)
                }
            }

            Section("Font Size") {
                Picker("Scale", selection: $fontScaleRaw) {
                    ForEach(NotchFontScale.allCases) { scale in
                        Text(scale.label).tag(scale.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Display Format") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Header")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TokenEditorView(
                        template: $headerTemplate,
                        defaultTemplate: .defaultHeader
                    )
                    .onChange(of: headerTemplate) { _, newValue in
                        newValue.save(forKey: Constants.UserDefaultsKeys.headerTemplate)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Row")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TokenEditorView(
                        template: $rowTitleTemplate,
                        defaultTemplate: .defaultRowTitle
                    )
                    .onChange(of: rowTitleTemplate) { _, newValue in
                        newValue.save(forKey: Constants.UserDefaultsKeys.rowTitleTemplate)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TokenEditorView(
                        template: $rowDetailTemplate,
                        defaultTemplate: .defaultRowDetail
                    )
                    .onChange(of: rowDetailTemplate) { _, newValue in
                        newValue.save(forKey: Constants.UserDefaultsKeys.rowDetailTemplate)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Live Notch Preview (mock data)

private struct NotchPreview: View {
    let fontScale: NotchFontScale
    let fitToText: Bool
    let showText: Bool
    let liquidGlass: Bool
    let glassFrost: Double
    var headerTemplate: DisplayTemplate = .defaultHeader
    var rowTitleTemplate: DisplayTemplate = .defaultRowTitle
    var rowDetailTemplate: DisplayTemplate = .defaultRowDetail
    @Environment(\.colorScheme) private var colorScheme

    private var fg: Color { colorScheme == .dark ? .white : .black }
    private var bg: Color { colorScheme == .dark ? .black : .white }

    private func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if fontScale == .system {
            switch weight {
            case .semibold, .bold: return .subheadline.weight(weight)
            case .medium: return .caption.weight(weight)
            default: return .caption2
            }
        }
        return .system(size: size, weight: weight, design: design)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Collapsed pill preview
            collapsedPill

            // Expanded preview with mock sessions
            expandedPreview
        }
    }

    private var collapsedPill: some View {
        HStack(spacing: 8) {
            SpinnerView(color: .green)
                .frame(width: 10, height: 10)

            if showText {
                Text(headerTemplate.resolve(
                    cwdPath: "~/Projects/MyApp",
                    sessionName: "feature",
                    stateText: "Running Bash...",
                    currentTool: "Bash",
                    detailText: "Bash — 12 tools",
                    elapsedTime: "2m 15s",
                    toolCount: 12
                ))
                    .font(font(size: fontScale.bodySize, weight: .medium))
                    .foregroundStyle(fg.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: fontScale.barHeight)
        .frame(width: fitToText ? nil : 200)
        .fixedSize(horizontal: fitToText, vertical: false)
        .modifier(PreviewGlassModifier(cornerRadius: 18, glowColor: .green, useGlass: liquidGlass, fillColor: bg, frost: glassFrost))
    }

    private var expandedPreview: some View {
        VStack(spacing: 4) {
            // Working session
            mockRow(
                name: rowTitleTemplate.resolve(
                    cwdPath: "~/Projects/MyApp", sessionName: "feature",
                    stateText: "Running Bash...", currentTool: "Bash",
                    detailText: "Bash — 12 tools", elapsedTime: "2m 15s", toolCount: 12
                ),
                detail: rowDetailTemplate.resolve(
                    cwdPath: "~/Projects/MyApp", sessionName: "feature",
                    stateText: "Running Bash...", currentTool: "Bash",
                    detailText: "Bash — 12 tools", elapsedTime: "2m 15s", toolCount: 12
                ),
                state: .working,
                time: "2m 15s"
            )

            // Awaiting approval
            mockApprovalRow

            // Ready session
            mockRow(
                name: rowTitleTemplate.resolve(
                    cwdPath: "~/Projects/Backend", sessionName: nil,
                    stateText: "Finished", currentTool: nil,
                    detailText: "Ready for next prompt", elapsedTime: "5m 30s", toolCount: 8
                ),
                detail: rowDetailTemplate.resolve(
                    cwdPath: "~/Projects/Backend", sessionName: nil,
                    stateText: "Finished", currentTool: nil,
                    detailText: "Ready for next prompt", elapsedTime: "5m 30s", toolCount: 8
                ),
                state: .ready,
                time: "5m 30s"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .modifier(PreviewGlassModifier(cornerRadius: 20, glowColor: .yellow, useGlass: liquidGlass, fillColor: bg, frost: glassFrost))
        .frame(width: 340)
    }

    private func mockRow(name: String, detail: String, state: SessionState, time: String) -> some View {
        HStack(spacing: 8) {
            stateIndicator(state)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(font(size: fontScale.bodySize, weight: .medium))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                Text(detail)
                    .font(font(size: fontScale.detailSize))
                    .foregroundStyle(fg.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer()

            Text(time)
                .font(font(size: fontScale.monoSize, design: .monospaced))
                .foregroundStyle(fg.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fg.opacity(0.06))
        )
    }

    private var mockApprovalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PulseView(color: .yellow)
                    .frame(width: 8, height: 8)
                Text(rowTitleTemplate.resolve(
                    cwdPath: "~/Projects/MyApp", sessionName: "feature",
                    stateText: "Approve Bash?", currentTool: "Bash",
                    detailText: "Waiting for approval", elapsedTime: "1m 30s", toolCount: 5
                ))
                    .font(font(size: fontScale.bodySize, weight: .semibold))
                    .foregroundStyle(fg)
                Spacer()
                Text("Bash")
                    .font(font(size: fontScale.badgeSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.yellow.opacity(0.15)))
            }

            Text("rm -rf node_modules && npm install")
                .font(font(size: fontScale.monoSize, design: .monospaced))
                .foregroundStyle(fg.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(fg.opacity(0.04))
                )

            HStack(spacing: 6) {
                Text("Allow")
                    .font(font(size: fontScale.monoSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.green.opacity(0.7)))

                Text("Always")
                    .font(font(size: fontScale.monoSize, weight: .medium))
                    .foregroundStyle(.green.opacity(0.8))

                Text("Deny")
                    .font(font(size: fontScale.monoSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.red.opacity(0.5)))

                Spacer()

                Text("Skip")
                    .font(font(size: fontScale.badgeSize, weight: .medium))
                    .foregroundStyle(fg.opacity(0.4))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.yellow.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.yellow.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func stateIndicator(_ state: SessionState) -> some View {
        switch state {
        case .working: SpinnerView(color: .green)
        case .awaitingApproval: PulseView(color: .yellow)
        case .ready: PulseView(color: .red)
        case .idle: Circle().fill(.gray)
        case .complete: Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
        }
    }
}

private struct PreviewGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let glowColor: Color
    let useGlass: Bool
    var fillColor: Color = .black
    var frost: Double = 0.3

    func body(content: Content) -> some View {
        if useGlass {
            if #available(macOS 26, *) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(fillColor.opacity(frost))
                            .shadow(color: glowColor.opacity(0.2), radius: 8)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .shadow(color: glowColor.opacity(0.2), radius: 8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(fillColor.opacity(frost))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fillColor)
                        .shadow(color: glowColor.opacity(0.3), radius: 8)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

// MARK: - Hotkey Recorder

// MARK: - Server

private struct ServerPane: View {
    @Bindable var appState: AppState
    @AppStorage(Constants.UserDefaultsKeys.port) private var port: Int = Int(Constants.defaultPort)
    @State private var portText = ""

    var body: some View {
        Form {
            Section("Hook Server") {
                LabeledContent("Port") {
                    HStack(spacing: 6) {
                        TextField("", text: $portText)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                        Button("Apply") {
                            if let newPort = UInt16(portText) {
                                port = Int(newPort)
                                appState.hookServer.restart(on: newPort)
                            }
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.hookServer.isRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(verbatim: appState.hookServer.isRunning
                             ? "Running on port \(appState.hookServer.port)"
                             : "Not running")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Claude Code Integration") {
                Button("Setup Integrations...") {
                    appState.showOnboarding()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(port)
        }
    }
}

// MARK: - Remote

private struct RemotePane: View {
    @Bindable var appState: AppState
    @AppStorage(Constants.UserDefaultsKeys.localRemoteEnabled) private var localRemoteEnabled = false
    @State private var addresses: [(label: String, url: String)] = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable mobile remote access", isOn: $localRemoteEnabled)
                    .onChange(of: localRemoteEnabled) { _, newValue in
                        appState.toggleWebRemote(enabled: newValue)
                        if newValue {
                            if appState.pairingManager.currentCode == nil {
                                appState.pairingManager.generatePairCode()
                            }
                            refreshAddresses()
                        } else {
                            appState.pairingManager.stopCodeTimer()
                        }
                    }
                if !localRemoteEnabled {
                    Text("Access your sessions and approve permissions from your phone over the local network or Tailscale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.webRemoteServer != nil ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(verbatim: appState.webRemoteServer != nil
                                 ? "Running on port \(Constants.webRemotePort)"
                                 : "Not running")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if localRemoteEnabled {
                Section("Pairing") {
                    if let code = appState.pairingManager.currentCode {
                        HStack(spacing: 12) {
                            Text(code)
                                .font(.system(size: 32, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

                            Spacer()

                            // Countdown ring
                            ZStack {
                                Circle()
                                    .stroke(.secondary.opacity(0.2), lineWidth: 3)
                                Circle()
                                    .trim(from: 0, to: CGFloat(appState.pairingManager.codeSecondsRemaining) / CGFloat(PairingManager.codeLifetime))
                                    .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 1), value: appState.pairingManager.codeSecondsRemaining)
                                Text("\(appState.pairingManager.codeSecondsRemaining)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 36, height: 36)
                        }
                        .padding(.vertical, 4)
                    }

                    Text("Enter this code on your phone to pair. A new code is generated automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Reachable Addresses") {
                    if addresses.isEmpty {
                        Text("No network interfaces found")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(addresses, id: \.url) { addr in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(addr.label)
                                        .font(.subheadline)
                                    Text(addr.url)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }

                                Spacer()

                                ShareLink(item: URL(string: addr.url)!) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Share this address")
                            }
                        }
                    }

                    Button("Refresh") {
                        refreshAddresses()
                    }
                    .controlSize(.small)
                }

                Section("Paired Devices") {
                    let devices = appState.pairingManager.pairedDevices
                    if devices.isEmpty {
                        Text("No paired devices")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(devices) { device in
                            HStack(spacing: 8) {
                                Image(systemName: deviceIcon(device.deviceName))
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.deviceName)
                                        .font(.subheadline.weight(.medium))
                                    Text("Last used \(device.lastUsed, style: .relative) ago")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    appState.pairingManager.revokeDevice(device)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .help("Revoke this device")
                            }
                        }

                        Button("Revoke All") {
                            appState.pairingManager.revokeAll()
                        }
                        .foregroundStyle(.red)
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if localRemoteEnabled {
                if appState.pairingManager.currentCode == nil {
                    appState.pairingManager.generatePairCode()
                }
                refreshAddresses()
            }
        }
    }

    private func refreshAddresses() {
        addresses = WebRemoteServer.reachableAddresses(port: Constants.webRemotePort)
    }

    private func deviceIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("android") { return "smartphone" }
        if n.contains("mac") { return "laptopcomputer" }
        if n.contains("windows") || n.contains("linux") { return "desktopcomputer" }
        return "globe"
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    var body: some View {
        Form {
            Section {
                Text("AgentGlance needs these permissions to focus terminal tabs and send notifications.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Automation") {
                LabeledContent {
                    HStack(spacing: 6) {
                        Button("Request Access") {
                            TerminalActivator.requestAutomationPermission()
                        }
                        .controlSize(.small)
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                } label: {
                    Label("Terminal Control", systemImage: "applescript")
                }
            }

            Section("Notifications") {
                LabeledContent {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                } label: {
                    Label("Session Alerts", systemImage: "bell.badge")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Debug (DEBUG builds only)

#if DEBUG
private struct DebugPane: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section("Screenshot Mode") {
                Toggle("Screenshot Mode", isOn: Binding(
                    get: { appState.sessionManager.screenshotMode },
                    set: { newValue in
                        appState.sessionManager.screenshotMode = newValue
                        if !newValue {
                            appState.sessionManager.clearScreenshotSessions()
                        }
                    }
                ))
                Text("Hides real sessions. Only shows test sessions from the buttons below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Screenshot Scenarios") {
                Button("Hero (multi-session)") { appState.screenshotHero() }
                Button("Edit Diff Approval") { appState.screenshotEditDiff() }
                Button("Completion + Todos") { appState.screenshotCompletionAndTodos() }
                Divider()
                Button("State: Thinking") { appState.screenshotThinkingState() }
                Button("State: Running") { appState.screenshotRunningState() }
                Button("State: Compacting") { appState.screenshotCompactingState() }
                Divider()
                Button("Clear Screenshot Sessions") {
                    appState.sessionManager.clearScreenshotSessions()
                }
            }

            Section("Test Sessions") {
                Button("Working (Bash)") { appState.sendTestEvent("PreToolUse", toolName: "Bash") }
                Button("Working (Edit)") { appState.sendTestEvent("PreToolUse", toolName: "Edit") }
                Button("New Session") { appState.sendTestEvent("SessionStart") }
            }

            Section("Test Approvals") {
                Button("Approval (Bash)") { appState.sendTestApproval(toolName: "Bash") }
                Button("Approval (Edit)") { appState.sendTestApproval(toolName: "Edit") }
            }

            Section("Test Interactions") {
                Button("Question") { appState.sendTestQuestion() }
                Button("Plan Review") { appState.sendTestPlanReview() }
            }

            Section("Test State Changes") {
                Button("Ready (Stop)") { appState.sendTestEvent("Stop") }
                Button("Complete (SessionEnd)") { appState.sendTestEvent("SessionEnd") }
            }

            Section("Server") {
                LabeledContent("Port") {
                    Text("\(appState.hookServer.port)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.hookServer.isRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(appState.hookServer.isRunning ? "Running" : "Not running")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Active sessions") {
                    Text("\(appState.sessionManager.activeSessions.count)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Pending decisions") {
                    Text("\(appState.hookServer.pendingDecisions.values.flatMap { $0 }.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif

// MARK: - Previews

#if DEBUG
#Preview("Settings") {
    SettingsView(appState: AppState())
        .frame(width: 580, height: 400)
}

#Preview("ModeBadge") {
    HStack(spacing: 8) {
        ModeBadge(mode: "plan")
        ModeBadge(mode: "auto")
        ModeBadge(mode: "acceptEdits")
        ModeBadge(mode: "bypassPermissions")
        ModeBadge(mode: "default")
    }
    .padding()
}
#endif

// MARK: - About

private struct AboutPane: View {
    var updater: SPUUpdater? = nil

    private let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    private let macOSVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AgentGlance")
                            .font(.title2.bold())
                        Text("Version \(appVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("macOS \(macOSVersion)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)

                Button("Check for Updates...") {
                    updater?.checkForUpdates()
                }
                .controlSize(.small)
            }

            Section {
                LabeledContent("Website") {
                    Link("agentglance.app", destination: URL(string: "https://agentglance.app")!)
                }
                LabeledContent("GitHub") {
                    Link("hezi/AgentGlance", destination: URL(string: "https://github.com/hezi/AgentGlance")!)
                }
                LabeledContent("Issues") {
                    Link("Report a bug", destination: URL(string: "https://github.com/hezi/AgentGlance/issues")!)
                }
            }

            Section("Acknowledgements") {
                LabeledContent("Sparkle") {
                    Link("sparkle-project.org", destination: URL(string: "https://sparkle-project.org")!)
                }
                LabeledContent("KeyboardShortcuts") {
                    Link("sindresorhus/KeyboardShortcuts", destination: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}
