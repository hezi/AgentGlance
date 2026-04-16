import SwiftUI
import Sparkle

struct MenuBarView: View {
    @Bindable var appState: AppState
    var updater: SPUUpdater? = nil
    @AppStorage(Constants.UserDefaultsKeys.sessionGroupMode) private var groupModeRaw = SessionGroupMode.none.rawValue
    @AppStorage(Constants.UserDefaultsKeys.groupSortMode) private var sortModeRaw = GroupSortMode.lastUpdated.rawValue
    @State private var collapsedGroups: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Constants.UserDefaultsKeys.collapsedGroups) ?? [])

    private var groupMode: SessionGroupMode {
        SessionGroupMode(rawValue: groupModeRaw) ?? .none
    }

    private var sortMode: GroupSortMode {
        GroupSortMode(rawValue: sortModeRaw) ?? .lastUpdated
    }

    private var sessionGroups: [SessionGroup] {
        SessionGrouper.group(
            sessions: appState.sessionManager.allSessions,
            by: groupMode,
            sortedBy: sortMode
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.sessionManager.allSessions.isEmpty {
                Text("No active sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
            } else if groupMode == .none {
                ForEach(appState.sessionManager.allSessions, id: \.id) { session in
                    sessionItem(session)
                    Divider()
                }
            } else {
                ForEach(sessionGroups) { group in
                    groupHeader(group)
                    if !collapsedGroups.contains(group.id) {
                        ForEach(group.sessions, id: \.id) { session in
                            sessionItem(session)
                        }
                    }
                    Divider()
                }
            }

            Divider()

            serverStatus

            if let server = appState.webRemoteServer, server.isRunning {
                webRemoteStatus
            }

            Divider()

            // Native-style menu items
            VStack(spacing: 0) {
                menuItem("Prevent Sleep", icon: appState.sleepPreventionEnabled ? "checkmark" : nil) {
                    appState.sleepPreventionEnabled.toggle()
                }

                Divider().padding(.vertical, 2)

                #if DEBUG
                Menu("Test Events") {
                    Button("Working (Bash)") { appState.sendTestEvent("PreToolUse", toolName: "Bash") }
                    Button("Working (Edit)") { appState.sendTestEvent("PreToolUse", toolName: "Edit") }
                    Button("Awaiting Approval (Bash)") { appState.sendTestApproval(toolName: "Bash") }
                    Button("Awaiting Approval (Edit)") { appState.sendTestApproval(toolName: "Edit") }
                    Button("Question") { appState.sendTestQuestion() }
                    Button("Plan Review") { appState.sendTestPlanReview() }
                    Divider()
                    Button("Needs Input") { appState.sendTestEvent("Stop") }
                    Button("Complete") { appState.sendTestEvent("SessionEnd") }
                    Divider()
                    Button("New Session") { appState.sendTestEvent("SessionStart") }
                    Divider()
                    Menu("Screenshots") {
                        Button("Hero (multi-session)") { appState.screenshotHero() }
                        Button("Edit Diff Approval") { appState.screenshotEditDiff() }
                        Button("Completion + Todos") { appState.screenshotCompletionAndTodos() }
                        Divider()
                        Button("State: Thinking") { appState.screenshotThinkingState() }
                        Button("State: Running") { appState.screenshotRunningState() }
                        Button("State: Compacting") { appState.screenshotCompactingState() }
                    }
                }
                .menuItemStyle()

                Divider().padding(.vertical, 2)
                #endif

                menuItem("Setup Integrations...", icon: "link") {
                    appState.showOnboarding()
                }
                menuItem("Settings...", icon: "gearshape", shortcut: "⌘,") {
                    appState.showSettings()
                }

                Divider().padding(.vertical, 2)

                menuItem("Check for Updates...", icon: "arrow.triangle.2.circlepath") {
                    updater?.checkForUpdates()
                }
                menuItem("Report Issue...", icon: "ladybug") {
                    reportIssue()
                }

                Divider().padding(.vertical, 2)

                menuItem("Quit AgentGlance", icon: "power", shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .frame(width: 300)
    }

    // MARK: - Session Item Dispatch

    @ViewBuilder
    private func sessionItem(_ session: Session) -> some View {
        if session.state == .awaitingApproval && session.currentTool == "ExitPlanMode" {
            planReviewItem(session)
        } else if session.state == .awaitingApproval && session.currentTool == "AskUserQuestion" {
            questionItem(session)
        } else if session.state == .awaitingApproval {
            approvalItem(session)
        } else {
            sessionRow(session)
        }
    }

    // MARK: - Group Header

    private func groupHeader(_ group: SessionGroup) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if collapsedGroups.contains(group.id) {
                    collapsedGroups.remove(group.id)
                } else {
                    collapsedGroups.insert(group.id)
                }
                UserDefaults.standard.set(Array(collapsedGroups), forKey: Constants.UserDefaultsKeys.collapsedGroups)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsedGroups.contains(group.id) ? 0 : 90))

                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(group.sessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.15)))

                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Session Row (clickable → navigate to terminal)

    private func sessionRow(_ session: Session) -> some View {
        Button {
            TerminalActivator.activate(session: session)
        } label: {
            HStack(spacing: 8) {
                stateIcon(session.state)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))

                    HStack(spacing: 4) {
                        Text(stateLabel(session.state))
                            .font(.system(size: 11))
                            .foregroundStyle(stateColor(session.state))

                        if let tool = session.currentTool {
                            Text("(\(tool))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                ModeBadge(mode: session.permissionMode)

                Text(session.elapsedFormatted)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button { TerminalActivator.activate(session: session) } label: {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Open in terminal")

                Button { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Open folder in Finder")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Approval Item (Allow/Deny/Skip)

    private func approvalItem(_ session: Session) -> some View {
        let pending = appState.hookServer.nextPending(for: session.id)
        let hasPending = pending != nil
        let toolName = pending?.toolName ?? session.currentTool
        let summary = pending?.toolSummary ?? session.pendingToolSummary

        return VStack(alignment: .leading, spacing: 6) {
            // Header: clickable to navigate
            Button { TerminalActivator.activate(session: session) } label: {
                HStack(spacing: 6) {
                    stateIcon(.awaitingApproval)
                        .frame(width: 16)

                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))

                    Spacer()

                    if let toolName {
                        Text(toolName)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(.yellow.opacity(0.12))
                            )
                    }
                }
            }
            .buttonStyle(.plain)

            // Tool summary
            if let summary {
                Text(summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Action buttons
            if hasPending {
                HStack(spacing: 6) {
                    Button {
                        appState.hookServer.allowPermission(sessionId: session.id)
                    } label: {
                        Label("Allow", systemImage: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)

                    Button("Always") {
                        appState.hookServer.allowAlwaysPermission(sessionId: session.id)
                    }
                    .font(.system(size: 10))
                    .tint(.green)
                    .controlSize(.small)

                    Button {
                        appState.hookServer.denyPermission(sessionId: session.id)
                    } label: {
                        Label("Deny", systemImage: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)

                    Spacer()

                    Button("Skip") {
                        appState.hookServer.dismissPermission(sessionId: session.id)
                    }
                    .font(.system(size: 10))
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Question Item (AskUserQuestion)

    private func questionItem(_ session: Session) -> some View {
        let pending = appState.hookServer.nextPending(for: session.id)
        let question = pending?.toolSummary ?? session.pendingToolSummary

        return VStack(alignment: .leading, spacing: 6) {
            // Header: clickable to navigate
            Button { TerminalActivator.activate(session: session) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                        .frame(width: 16)

                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))

                    Spacer()

                    Text("Question")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(.blue.opacity(0.12))
                        )
                }
            }
            .buttonStyle(.plain)

            // Question text
            if let question {
                Text(question)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Plan Review Item

    private func planReviewItem(_ session: Session) -> some View {
        let hasPending = appState.hookServer.nextPending(for: session.id) != nil

        return VStack(alignment: .leading, spacing: 6) {
            // Header
            Button { TerminalActivator.activate(session: session) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                        .frame(width: 16)

                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))

                    Spacer()

                    Text("Plan Review")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(.blue.opacity(0.12))
                        )
                }
            }
            .buttonStyle(.plain)

            // Plan preview
            if let preview = session.pendingPlanPreview {
                Text(preview)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            // Action buttons
            if hasPending {
                HStack(spacing: 6) {
                    Button {
                        appState.hookServer.allowPermission(sessionId: session.id)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)

                    Button {
                        appState.hookServer.denyPermission(sessionId: session.id, message: "Plan rejected from AgentGlance")
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)

                    Spacer()

                    if session.pendingPlanPath != nil {
                        Button {
                            if let path = session.pendingPlanPath {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        } label: {
                            Label("Open", systemImage: "arrow.up.right.square")
                                .font(.system(size: 10))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Server Status

    private var serverStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appState.hookServer.isRunning ? .green : .red)
                .frame(width: 6, height: 6)

            Text(appState.hookServer.isRunning
                 ? "Listening on port \(appState.hookServer.port)"
                 : "Server not running")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            if appState.sleepManager.isPreventingSleep {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Sleep prevention active")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Web Remote Status

    private var webRemoteStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone")
                .font(.system(size: 10))
                .foregroundStyle(.blue)

            Text("Remote on :\(Constants.webRemotePort)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            if let code = appState.pairingManager.currentCode {
                Text(code)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.blue)

                Text("\(appState.pairingManager.codeSecondsRemaining)s")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    // MARK: - Native-style menu item

    @ViewBuilder
    private func menuItem(_ title: String, icon: String? = nil, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .frame(width: 16)
                        .font(.system(size: 12))
                } else {
                    Spacer().frame(width: 16)
                }
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(MenuItemHoverStyle())
    }

    private func stateIcon(_ state: SessionState) -> some View {
        Group {
            switch state {
            case .idle:
                Circle().fill(.gray)
            case .working:
                SpinnerView(color: .green)
            case .awaitingApproval:
                PulseView(color: .yellow)
            case .ready:
                PulseView(color: .red)
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 13, height: 13)
    }

    private func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .idle: "Idle"
        case .working: "Working"
        case .awaitingApproval: "Awaiting Approval"
        case .ready: "Ready"
        case .complete: "Complete"
        }
    }

    private func stateColor(_ state: SessionState) -> Color {
        switch state {
        case .idle: .gray
        case .working: .green
        case .awaitingApproval: .yellow
        case .ready: .red
        case .complete: .green
        }
    }

    // MARK: - Report Issue

    private func reportIssue() {
        let crashLog = findLatestCrashLog()

        if let crashLog {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(crashLog, forType: .string)
        }

        // Open GitHub issues with a pre-filled template
        var body = """
        **Describe the issue:**\n\n\n
        **Steps to reproduce:**\n1. \n\n
        **macOS version:** \(ProcessInfo.processInfo.operatingSystemVersionString)\n
        """
        if crashLog != nil {
            body += "\n**Crash log:** (pasted to clipboard — please paste below)\n```\n\n```"
        }

        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://github.com/hezi/AgentGlance/issues/new?body=\(encoded)"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func findLatestCrashLog() -> String? {
        let diagnosticsDir = NSString("~/Library/Logs/DiagnosticReports").expandingTildeInPath
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(atPath: diagnosticsDir) else { return nil }

        // Find the most recent AgentGlance crash report (.ips or .crash)
        var latestPath: String?
        var latestDate: Date = .distantPast

        for file in files where file.hasPrefix("AgentGlance") && (file.hasSuffix(".ips") || file.hasSuffix(".crash")) {
            let path = (diagnosticsDir as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date,
               modified > latestDate {
                latestDate = modified
                latestPath = path
            }
        }

        guard let path = latestPath,
              let data = fm.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Truncate if very long (keep first 5000 chars)
        if content.count > 5000 {
            return String(content.prefix(5000)) + "\n\n... (truncated, full log at \(path))"
        }
        return content
    }
}

// MARK: - Menu item hover highlight

private struct MenuItemHoverStyle: View {
    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isHovered ? Color.accentColor.opacity(0.8) : .clear)
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func menuItemStyle() -> some View {
        self
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Menu Bar") {
    let state = AppState()
    state.sendTestEvent("PreToolUse", toolName: "Bash")
    return MenuBarView(appState: state)
}

#Preview("With Approval") {
    let state = AppState()
    state.sendTestEvent("PreToolUse", toolName: "Edit")
    DispatchQueue.main.async {
        state.sendTestNotification(type: "permission_prompt")
    }
    return MenuBarView(appState: state)
}

#Preview("Empty") {
    MenuBarView(appState: AppState())
}
#endif
