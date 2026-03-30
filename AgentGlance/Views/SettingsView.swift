import SwiftUI
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, server, permissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .server: "Server"
        case .permissions: "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .appearance: "textformat.size"
        case .server: "network"
        case .permissions: "lock.shield"
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
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
                case .permissions: PermissionsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var appState: AppState
    @AppStorage(Constants.UserDefaultsKeys.sleepPreventionEnabled) private var sleepPrevention = true
    @AppStorage(Constants.UserDefaultsKeys.soundEnabled) private var soundEnabled = true
    @AppStorage(Constants.UserDefaultsKeys.autoExpandOnApproval) private var autoExpand = false
    @AppStorage(Constants.UserDefaultsKeys.showAllApprovals) private var showAllApprovals = false
    @AppStorage(Constants.UserDefaultsKeys.screenSelectionMode) private var screenMode = "mainScreen"
    @AppStorage(Constants.UserDefaultsKeys.selectedScreenID) private var selectedScreenID = ""
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Display") {
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

            Section("Behavior") {
                Toggle("Prevent sleep while Claude is working", isOn: $sleepPrevention)
                    .onChange(of: sleepPrevention) { _, newValue in
                        appState.sleepPreventionEnabled = newValue
                    }
                Toggle("Play sound on notifications", isOn: $soundEnabled)
                Toggle("Auto-expand notch on approval requests", isOn: $autoExpand)
                Toggle("Show all queued approvals at once", isOn: $showAllApprovals)
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

    private var maxExpandedWidth: Double {
        Double(NSScreen.main?.frame.width ?? 1920) * 0.25
    }

    private var fontScale: NotchFontScale {
        NotchFontScale(rawValue: fontScaleRaw) ?? .m
    }

    var body: some View {
        Form {
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
                    Slider(value: $expandedWidth, in: 280...maxExpandedWidth, step: 10)
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

            Section("Preview") {
                NotchPreview(fontScale: fontScale, fitToText: fitToText, showText: showText, liquidGlass: liquidGlass, glassFrost: glassFrost, expandedWidth: expandedWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
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
    let expandedWidth: Double
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
                Text("Running Bash...")
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
                name: "~/Projects/MyApp",
                detail: "Bash — 12 tools",
                state: .working,
                time: "2m 15s"
            )

            // Awaiting approval
            mockApprovalRow

            // Ready session
            mockRow(
                name: "~/Projects/Backend",
                detail: "Ready for next prompt",
                state: .ready,
                time: "5m 30s"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .modifier(PreviewGlassModifier(cornerRadius: 20, glowColor: .yellow, useGlass: liquidGlass, fillColor: bg, frost: glassFrost))
        .frame(width: expandedWidth)
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
                Text("~/Projects/MyApp")
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
                        Text(appState.hookServer.isRunning
                             ? "Running on port \(appState.hookServer.port)"
                             : "Not running")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Claude Code Integration") {
                Button("Setup Hooks...") {
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
