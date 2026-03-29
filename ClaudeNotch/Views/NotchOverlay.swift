import SwiftUI

struct NotchOverlay: View {
    var sessionManager: SessionManager
    var hookServer: HookServer
    var appState: AppState
    @State private var isExpanded = false
    @State private var isAutoExpanded = false // held open by auto-expand, not hover
    @State private var isPinned = false
    @AppStorage(Constants.UserDefaultsKeys.fitNotchToText) private var fitToText = false
    @AppStorage(Constants.UserDefaultsKeys.notchFontScale) private var fontScaleRaw = NotchFontScale.m.rawValue
    @AppStorage(Constants.UserDefaultsKeys.liquidGlass) private var liquidGlass = false
    @AppStorage(Constants.UserDefaultsKeys.glassFrost) private var glassFrost = 0.3
    @AppStorage(Constants.UserDefaultsKeys.showAllApprovals) private var showAllApprovals = false
    @AppStorage(Constants.UserDefaultsKeys.expandedWidth) private var expandedWidth = 340.0
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var geometry: NotchGeometry

    /// Adaptive foreground color — white in dark mode, black in light mode
    private var fg: Color { colorScheme == .dark ? .white : .black }
    /// Adaptive background color — black in dark mode, white in light mode
    private var bg: Color { colorScheme == .dark ? .black : .white }

    private var fontScale: NotchFontScale {
        NotchFontScale(rawValue: fontScaleRaw) ?? .m
    }

    private var sessions: [Session] {
        sessionManager.activeSessions
    }

    private var primarySession: Session? {
        sessions.first
    }

    /// Label for the most urgent attention-needed session when multiple are active
    private var urgentLabel: String? {
        if let s = sessions.first(where: { $0.state == .awaitingApproval }) {
            if s.currentTool == "AskUserQuestion" {
                return "\(s.projectName) has a question"
            }
            if s.currentTool == "ExitPlanMode" {
                return "\(s.projectName): review plan"
            }
            if let tool = s.currentTool {
                return "\(s.projectName): approve \(tool)?"
            }
            return "\(s.projectName) needs approval"
        }
        // Only show "finished" if no session is actively working
        if !sessions.contains(where: { $0.state == .working }),
           let s = sessions.first(where: { $0.state == .ready }) {
            return "\(s.projectName) finished"
        }
        return nil
    }

    private var displayState: SessionState {
        if sessions.contains(where: { $0.state == .awaitingApproval }) { return .awaitingApproval }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        if sessions.contains(where: { $0.state == .ready }) { return .ready }
        if sessions.contains(where: { $0.state == .complete }) { return .complete }
        return .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            notchContent
                .padding(.top, 4)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                geometry.pillRect = geo.frame(in: .global)
                            }
                            .onChange(of: geo.size) { _, _ in
                                geometry.pillRect = geo.frame(in: .global)
                            }
                    }
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notchContent: some View {
        VStack(spacing: 0) {
            collapsedBar

            if isExpanded && !sessions.isEmpty {
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: isExpanded ? expandedWidth : (fitToText ? nil : notchWidth))
        .fixedSize(horizontal: fitToText && !isExpanded, vertical: false)
        .modifier(NotchBackgroundModifier(
            cornerRadius: isExpanded ? 20 : 18,
            glowColor: stateGlow,
            glowRadius: isExpanded ? 16 : 8,
            useGlass: liquidGlass,
            fillColor: bg,
            frost: glassFrost
        ))
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !geometry.isDragging, !sessions.isEmpty else {
                if sessions.isEmpty {
                    isExpanded = false
                    isAutoExpanded = false
                    isPinned = false
                }
                return
            }
            if hovering {
                isExpanded = true
                isAutoExpanded = false // user took over, no longer auto
            } else if !isAutoExpanded && !isPinned {
                isExpanded = false
            }
        }
        .animation(.smooth(duration: 0.35), value: isExpanded)
        .animation(.smooth(duration: 0.3), value: displayState)
        .animation(.smooth(duration: 0.3), value: sessions.count)
        .onChange(of: appState.shouldAutoExpand) { _, shouldExpand in
            if shouldExpand && !sessions.isEmpty {
                isExpanded = true
                isAutoExpanded = true
                appState.shouldAutoExpand = false
            }
        }
        // Auto-expand stays open until the mouse leaves the pill area.
        // The onHover handler above handles collapsing when hovering = false.
    }

    // MARK: - Collapsed bar

    private var collapsedBar: some View {
        ZStack {
            // Center: status label
            HStack(spacing: 8) {
                if let session = primarySession {
                    stateIndicator(for: session.state)
                        .frame(width: 10, height: 10)

                    Group {
                        if sessions.count > 1, let urgent = urgentLabel {
                            Text(urgent)
                        } else if sessions.count > 1 {
                            Text("\(session.projectName): \(stateText(for: session).lowercased())")
                        } else {
                            Text(stateText(for: session))
                        }
                    }
                    .font(scaledFont(size: fontScale.bodySize, weight: .medium))
                    .foregroundStyle(fg.opacity(0.8))
                    .lineLimit(1)
                } else {
                    Image(systemName: "terminal")
                        .font(scaledFont(size: fontScale.detailSize))
                        .foregroundStyle(fg.opacity(0.35))
                    Text("Claude Notch")
                        .font(scaledFont(size: fontScale.bodySize, weight: .medium))
                        .foregroundStyle(fg.opacity(0.35))
                }
            }

            // Left/right buttons (only when expanded)
            if isExpanded {
                HStack {
                    Button {
                        isPinned.toggle()
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(scaledFont(size: fontScale.detailSize))
                            .foregroundStyle(isPinned ? .accentColor : fg.opacity(0.35))
                            .rotationEffect(.degrees(isPinned ? 0 : 45))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        appState.showSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(scaledFont(size: fontScale.detailSize))
                            .foregroundStyle(fg.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: fontScale.barHeight)
    }

    // MARK: - Expanded detail

    private var expandedDetail: some View {
        VStack(spacing: 4) {
            ForEach(sessions, id: \.id) { session in
                if session.state == .awaitingApproval && session.currentTool == "AskUserQuestion" {
                    questionRow(session)
                } else if session.state == .awaitingApproval && session.currentTool == "ExitPlanMode" {
                    planReviewRow(session)
                } else if session.state == .awaitingApproval {
                    if showAllApprovals {
                        // Show all queued approvals for this session
                        let queue = hookServer.pendingDecisions[session.id] ?? []
                        ForEach(Array(queue.enumerated()), id: \.offset) { index, pending in
                            approvalRowForPending(session: session, pending: pending, index: index)
                        }
                        if queue.isEmpty {
                            approvalRow(session)
                        }
                    } else {
                        approvalRow(session)
                    }
                } else {
                    sessionRow(session)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func sessionRow(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Main row content (tappable → terminal)
                Button {
                    TerminalActivator.activate(session: session)
                } label: {
                    HStack(spacing: 8) {
                        stateIndicator(for: session.state)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.projectName)
                                .font(scaledFont(size: fontScale.bodySize, weight: .medium))
                                .foregroundStyle(fg)
                                .lineLimit(1)

                            Text(stateDetail(for: session))
                                .font(scaledFont(size: fontScale.detailSize))
                                .foregroundStyle(fg.opacity(0.45))
                                .lineLimit(1)
                        }

                        Spacer()

                        ModeBadge(mode: session.permissionMode)

                        Text(session.elapsedFormatted)
                            .font(scaledFont(size: fontScale.monoSize, design: .monospaced))
                            .foregroundStyle(fg.opacity(0.35))
                    }
                }
                .buttonStyle(.plain)

                // Action buttons
                HStack(spacing: 4) {
                    Button { TerminalActivator.activate(session: session) } label: {
                        Image(systemName: "apple.terminal")
                            .font(scaledFont(size: fontScale.detailSize))
                            .foregroundStyle(fg.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help("Open in terminal")

                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) } label: {
                        Image(systemName: "folder")
                            .font(scaledFont(size: fontScale.detailSize))
                            .foregroundStyle(fg.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help("Open folder in Finder")
                }
            }

            // Clickable tool summary (URLs, search queries) below the main row
            if let summary = session.pendingToolSummary, session.currentTool == "WebFetch",
               let url = URL(string: summary) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(scaledFont(size: fontScale.badgeSize))
                        Text(summary)
                            .font(scaledFont(size: fontScale.monoSize, design: .monospaced))
                            .lineLimit(1)
                            .underline()
                    }
                    .foregroundColor(.blue)
                }
            } else if let summary = session.pendingToolSummary, session.currentTool == "WebSearch" {
                Link(destination: URL(string: "https://www.google.com/search?q=\(summary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? summary)")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(scaledFont(size: fontScale.badgeSize))
                        Text(summary)
                            .font(scaledFont(size: fontScale.monoSize))
                            .lineLimit(1)
                            .underline()
                    }
                    .foregroundColor(.blue)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fg.opacity(0.06))
        )
    }

    // MARK: - Shared: Tool summary display (used by both approval row modes)

    @ViewBuilder
    private func toolSummaryBlock(summary: String?, toolName: String?) -> some View {
        if let summary {
            if toolName == "WebFetch", let url = URL(string: summary) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(scaledFont(size: fontScale.badgeSize))
                        Text(summary)
                            .font(scaledFont(size: fontScale.monoSize, design: .monospaced))
                            .lineLimit(2)
                            .underline()
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.blue.opacity(0.06))
                    )
                }
            } else if toolName == "WebSearch",
                      let encoded = summary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(scaledFont(size: fontScale.badgeSize))
                        Text(summary)
                            .font(scaledFont(size: fontScale.monoSize))
                            .lineLimit(2)
                            .underline()
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.blue.opacity(0.06))
                    )
                }
            } else {
                Text(summary)
                    .font(scaledFont(size: fontScale.monoSize, design: .monospaced))
                    .foregroundStyle(fg.opacity(0.7))
                    .lineLimit(3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(fg.opacity(0.04))
                    )
            }
        }
    }

    // MARK: - Shared: Approval action buttons

    @ViewBuilder
    private func approvalButtons(
        session: Session,
        allowAction: @escaping () -> Void,
        denyAction: @escaping () -> Void,
        showAlways: Bool = true,
        queueCount: Int = 0
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                allowAction()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(scaledFont(size: fontScale.badgeSize, weight: .bold))
                    Text("Allow")
                        .font(scaledFont(size: fontScale.monoSize, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.green.opacity(0.7)))
            }
            .buttonStyle(.plain)

            if showAlways {
                Button {
                    hookServer.allowAlwaysPermission(sessionId: session.id)
                } label: {
                    Text("Always")
                        .font(scaledFont(size: fontScale.monoSize, weight: .medium))
                        .foregroundStyle(.green.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

            Button {
                denyAction()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(scaledFont(size: fontScale.badgeSize, weight: .bold))
                    Text("Deny")
                        .font(scaledFont(size: fontScale.monoSize, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.red.opacity(0.5)))
            }
            .buttonStyle(.plain)

            Spacer()

            if queueCount > 1 {
                Text("+\(queueCount - 1)")
                    .font(scaledFont(size: fontScale.badgeSize, weight: .semibold))
                    .foregroundStyle(.yellow.opacity(0.7))
            }

            Button {
                hookServer.dismissPermission(sessionId: session.id)
            } label: {
                Text("Skip")
                    .font(scaledFont(size: fontScale.badgeSize, weight: .medium))
                    .foregroundStyle(fg.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Approval Row for specific queued item (show-all mode)

    private func approvalRowForPending(session: Session, pending: PendingDecision, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if index == 0 {
                    PulseView(color: .yellow)
                        .frame(width: 8, height: 8)
                } else {
                    Circle().fill(.yellow.opacity(0.4))
                        .frame(width: 8, height: 8)
                }

                if index == 0 {
                    Button { TerminalActivator.activate(session: session) } label: {
                        Text(session.projectName)
                            .font(scaledFont(size: fontScale.bodySize, weight: .semibold))
                            .foregroundStyle(fg)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text(pending.toolName)
                    .font(scaledFont(size: fontScale.badgeSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.yellow.opacity(0.15)))
            }

            toolSummaryBlock(summary: pending.toolSummary, toolName: pending.toolName)

            approvalButtons(
                session: session,
                allowAction: { hookServer.allowSpecificPermission(id: pending.id, sessionId: session.id) },
                denyAction: { hookServer.denySpecificPermission(id: pending.id, sessionId: session.id) },
                showAlways: index == 0
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.yellow.opacity(index == 0 ? 0.06 : 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.yellow.opacity(0.1), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Approval Row (single / queue-front mode)

    private func approvalRow(_ session: Session) -> some View {
        let hasPending = hookServer.nextPending(for: session.id) != nil
        let pending = hookServer.nextPending(for: session.id)
        let queueCount = hookServer.pendingCount(for: session.id)
        let toolName = pending?.toolName ?? session.currentTool
        let summary = pending?.toolSummary ?? session.pendingToolSummary

        return VStack(alignment: .leading, spacing: 6) {
            // Header
            Button { TerminalActivator.activate(session: session) } label: {
                HStack(spacing: 6) {
                    PulseView(color: .yellow)
                        .frame(width: 8, height: 8)

                    Text(session.projectName)
                        .font(scaledFont(size: fontScale.bodySize, weight: .semibold))
                        .foregroundStyle(fg)

                    Image(systemName: "apple.terminal")
                        .font(scaledFont(size: fontScale.badgeSize))
                        .foregroundStyle(fg.opacity(0.25))

                    Spacer()

                    if let toolName {
                        Text(toolName)
                            .font(scaledFont(size: fontScale.badgeSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(.yellow.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.yellow.opacity(0.15)))
                    }
                }
            }
            .buttonStyle(.plain)

            toolSummaryBlock(summary: summary, toolName: toolName)

            if hasPending {
                approvalButtons(
                    session: session,
                    allowAction: { hookServer.allowPermission(sessionId: session.id) },
                    denyAction: { hookServer.denyPermission(sessionId: session.id) },
                    queueCount: queueCount
                )
            } else {
                Text("Waiting for approval in terminal")
                    .font(scaledFont(size: fontScale.badgeSize, weight: .medium))
                    .foregroundStyle(.yellow.opacity(0.6))
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

    // MARK: - Question Row (AskUserQuestion)

    private func questionRow(_ session: Session) -> some View {
        QuestionRowView(
            session: session,
            hookServer: hookServer,
            fontScale: fontScale,
            fg: fg
        )
    }

    // MARK: - Plan Review Row

    private func planReviewRow(_ session: Session) -> some View {
        let hasPending = hookServer.nextPending(for: session.id) != nil

        return VStack(alignment: .leading, spacing: 6) {
            // Header
            Button { TerminalActivator.activate(session: session) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(scaledFont(size: fontScale.detailSize))
                        .foregroundStyle(.blue)

                    Text(session.projectName)
                        .font(scaledFont(size: fontScale.bodySize, weight: .semibold))
                        .foregroundStyle(fg)

                    Image(systemName: "apple.terminal")
                        .font(scaledFont(size: fontScale.badgeSize))
                        .foregroundStyle(fg.opacity(0.25))

                    Spacer()

                    Text("Plan Review")
                        .font(scaledFont(size: fontScale.badgeSize, weight: .medium))
                        .foregroundStyle(.blue.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(.blue.opacity(0.15))
                        )
                }
            }
            .buttonStyle(.plain)

            // Plan preview
            if let preview = session.pendingPlanPreview {
                Text(preview)
                    .font(scaledFont(size: fontScale.detailSize))
                    .foregroundStyle(fg.opacity(0.7))
                    .lineLimit(5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(fg.opacity(0.04))
                    )
            }

            // Actions
            if hasPending {
                HStack(spacing: 8) {
                    Button {
                        hookServer.allowPermission(sessionId: session.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(scaledFont(size: fontScale.badgeSize, weight: .bold))
                            Text("Approve")
                                .font(scaledFont(size: fontScale.monoSize, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.green.opacity(0.7)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        hookServer.denyPermission(sessionId: session.id, message: "Plan rejected from Claude Notch")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(scaledFont(size: fontScale.badgeSize, weight: .bold))
                            Text("Reject")
                                .font(scaledFont(size: fontScale.monoSize, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.red.opacity(0.5)))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Open plan file
                    if session.pendingPlanPath != nil {
                        Button {
                            if let path = session.pendingPlanPath {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(scaledFont(size: fontScale.detailSize))
                                Text("Open")
                                    .font(scaledFont(size: fontScale.badgeSize, weight: .medium))
                            }
                            .foregroundStyle(.blue.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.blue.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.blue.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Tool Summary (with clickable URLs)

    @ViewBuilder
    private func toolSummaryView(_ summary: String, toolName: String? = nil) -> some View {
        if toolName == "WebFetch" {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(scaledFont(size: fontScale.badgeSize))
                    .foregroundStyle(.blue.opacity(0.6))
                Text(summary)
                    .font(scaledFont(size: fontScale.monoSize, design: .monospaced))
                    .foregroundStyle(.blue.opacity(0.9))
                    .lineLimit(2)
                    .underline()
            }
            .onTapGesture {
                if let url = URL(string: summary) {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if toolName == "WebSearch" {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(scaledFont(size: fontScale.badgeSize))
                    .foregroundStyle(.blue.opacity(0.6))
                Text(summary)
                    .font(scaledFont(size: fontScale.monoSize))
                    .foregroundStyle(.blue.opacity(0.9))
                    .lineLimit(2)
                    .underline()
            }
            .onTapGesture {
                if let encoded = summary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            Text(summary)
                .font(scaledFont(size: fontScale.monoSize, design: .monospaced))
                .foregroundStyle(fg.opacity(0.7))
                .lineLimit(3)
        }
    }

    // MARK: - State Visuals

    @ViewBuilder
    private func stateIndicator(for state: SessionState) -> some View {
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
                .font(scaledFont(size: fontScale.monoSize))
                .foregroundStyle(.green)
        }
    }

    private func stateText(for session: Session) -> String {
        switch session.state {
        case .idle: "Idle"
        case .working:
            if let tool = session.currentTool {
                "Running \(tool)..."
            } else {
                "Working..."
            }
        case .awaitingApproval:
            if let tool = session.currentTool {
                "Approve \(tool)?"
            } else {
                "Needs approval"
            }
        case .ready: "Finished"
        case .complete: "Complete"
        }
    }

    private func stateDetail(for session: Session) -> String {
        switch session.state {
        case .idle: "Waiting"
        case .working:
            if let tool = session.currentTool {
                "\(tool) — \(session.toolCount) tools"
            } else {
                "\(session.toolCount) tool calls"
            }
        case .awaitingApproval:
            session.pendingToolSummary ?? "Waiting for approval"
        case .ready: "Ready for next prompt"
        case .complete: "\(session.toolCount) tool calls completed"
        }
    }

    // MARK: - Layout

    private var notchWidth: CGFloat {
        guard let session = primarySession else { return 160 }
        if session.state == .awaitingApproval { return 220 }
        return 200
    }

    /// Returns a font respecting the user's scale preference.
    /// When scale is `.system`, uses SwiftUI's dynamic body/caption styles.
    private func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if fontScale == .system {
            // Map to semantic styles based on the size role
            switch weight {
            case .semibold, .bold: return .subheadline.weight(weight)
            case .medium: return .caption.weight(weight)
            default: return .caption2
            }
        }
        return .system(size: size, weight: weight, design: design)
    }

    private var stateGlow: Color {
        switch displayState {
        case .idle: .clear
        case .working: .green
        case .awaitingApproval: .yellow
        case .ready: .red
        case .complete: .green
        }
    }
}

// MARK: - Notch Background (opaque black or Liquid Glass)

private struct NotchBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    let glowColor: Color
    let glowRadius: CGFloat
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
                            .shadow(color: glowColor.opacity(0.3), radius: glowRadius)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .shadow(color: glowColor.opacity(0.3), radius: glowRadius)
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
                        .shadow(color: glowColor.opacity(0.4), radius: glowRadius)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

// MARK: - Question Row (interactive AskUserQuestion)

struct QuestionRowView: View {
    let session: Session
    let hookServer: HookServer
    let fontScale: NotchFontScale
    let fg: Color

    @State private var selections: [String: Set<String>] = [:]

    private var pending: PendingDecision? {
        hookServer.nextPending(for: session.id)
    }

    private var questions: [ParsedQuestion] {
        pending?.questions ?? []
    }

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
        VStack(alignment: .leading, spacing: 6) {
            // Header
            Button { TerminalActivator.activate(session: session) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(font(size: fontScale.monoSize))
                        .foregroundStyle(.blue)

                    Text(session.projectName)
                        .font(font(size: fontScale.bodySize, weight: .semibold))
                        .foregroundStyle(fg)

                    Image(systemName: "apple.terminal")
                        .font(font(size: fontScale.badgeSize))
                        .foregroundStyle(fg.opacity(0.25))

                    Spacer()

                    Text("Question")
                        .font(font(size: fontScale.badgeSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(.blue.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.blue.opacity(0.15)))
                }
            }
            .buttonStyle(.plain)

            // Questions with selectable options
            if !questions.isEmpty {
                ForEach(questions) { q in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(q.questionText)
                            .font(font(size: fontScale.monoSize, weight: .medium))
                            .foregroundStyle(fg.opacity(0.85))

                        // Option chips
                        FlowLayout(spacing: 4) {
                            ForEach(q.options, id: \.self) { option in
                                let isSelected = selections[q.questionText, default: []].contains(option)
                                Button {
                                    toggleSelection(question: q, option: option)
                                } label: {
                                    Text(option)
                                        .font(font(size: fontScale.detailSize, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? .white : fg.opacity(0.7))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(isSelected ? .blue.opacity(0.7) : fg.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(isSelected ? .blue : fg.opacity(0.1), lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(fg.opacity(0.03))
                    )
                }
            } else if let summary = pending?.toolSummary ?? session.pendingToolSummary {
                // Fallback: show raw question text
                Text(summary)
                    .font(font(size: fontScale.monoSize))
                    .foregroundStyle(fg.opacity(0.85))
                    .lineLimit(4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(fg.opacity(0.04))
                    )
            }

            // Action buttons
            HStack(spacing: 6) {
                if !questions.isEmpty && hasAnySelection {
                    Button {
                        submitAnswers()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(font(size: fontScale.badgeSize, weight: .bold))
                            Text("Submit")
                                .font(font(size: fontScale.monoSize, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.blue.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    TerminalActivator.activate(session: session)
                    hookServer.dismissPermission(sessionId: session.id)
                } label: {
                    Text("Answer in Terminal")
                        .font(font(size: fontScale.badgeSize, weight: .medium))
                        .foregroundStyle(fg.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.blue.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.blue.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    private var hasAnySelection: Bool {
        selections.values.contains { !$0.isEmpty }
    }

    private func toggleSelection(question: ParsedQuestion, option: String) {
        var current = selections[question.questionText, default: []]
        if question.multiSelect {
            if current.contains(option) { current.remove(option) }
            else { current.insert(option) }
        } else {
            current = [option]
        }
        selections[question.questionText] = current
    }

    private func submitAnswers() {
        var answers: [String: String] = [:]
        for q in questions {
            let selected = selections[q.questionText, default: []]
            if !selected.isEmpty {
                // For multi-select, join with comma; for single, just the value
                answers[q.questionText] = selected.sorted().joined(separator: ",")
            }
        }
        hookServer.answerQuestion(sessionId: session.id, answers: answers)
    }
}

/// Simple flow layout for option chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - Spinner (orange rotating arc)

struct SpinnerView: View {
    var color: Color = .green
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, lineWidth: 1.5)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Pulse (breathing dot)

struct PulseView: View {
    var color: Color = .orange
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(color)
            .overlay(
                Circle()
                    .fill(color.opacity(0.3))
                    .scaleEffect(scale)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    scale = 1.8
                }
            }
    }
}

// MARK: - Previews

#if DEBUG
/// Creates a SessionManager populated with mock sessions for previews.
/// Avoids needing to instantiate AppState (which creates windows/servers).
@MainActor
private func previewSessionManager(_ events: [(id: String, cwd: String, event: String, tool: String?, input: JSONValue?)]) -> SessionManager {
    let sm = SessionManager()
    for e in events {
        sm.handleEvent(HookPayload(
            session_id: e.id,
            cwd: e.cwd,
            hook_event_name: e.event,
            tool_name: e.tool,
            tool_input: e.input
        ))
    }
    return sm
}

#Preview("Idle") {
    let sm = SessionManager()
    let hs = HookServer()
    return NotchOverlay(sessionManager: sm, hookServer: hs, appState: AppState())
        .environmentObject(NotchGeometry())
        .frame(width: 500, height: 400)
        .background(.gray.opacity(0.2))
}

#Preview("Working") {
    let sm = previewSessionManager([
        (id: "s1", cwd: "/Users/demo/Projects/MyApp", event: "PreToolUse", tool: "Bash",
         input: .object(["command": .string("npm run build && npm test")])),
    ])
    return NotchOverlay(sessionManager: sm, hookServer: HookServer(), appState: AppState())
        .environmentObject(NotchGeometry())
        .frame(width: 500, height: 400)
        .background(.gray.opacity(0.2))
}

#Preview("Awaiting Approval") {
    let sm = previewSessionManager([
        (id: "s1", cwd: "/Users/demo/Projects/MyApp", event: "PreToolUse", tool: "Bash",
         input: .object(["command": .string("rm -rf node_modules && npm install")])),
        (id: "s1", cwd: "/Users/demo/Projects/MyApp", event: "PermissionRequest", tool: "Bash",
         input: .object(["command": .string("rm -rf node_modules && npm install")])),
    ])
    let hs = HookServer()
    hs.addMockPending(sessionId: "s1", toolName: "Bash",
                         toolInput: .object(["command": .string("rm -rf node_modules && npm install")]),
                         toolSummary: "rm -rf node_modules && npm install")
    return NotchOverlay(sessionManager: sm, hookServer: hs, appState: AppState())
        .environmentObject(NotchGeometry())
        .frame(width: 500, height: 400)
        .background(.gray.opacity(0.2))
}

#Preview("Multiple Sessions") {
    let sm = previewSessionManager([
        // Working session
        (id: "s1", cwd: "/Users/demo/Projects/MyApp", event: "PreToolUse", tool: "Edit",
         input: .object(["file_path": .string("/Users/demo/Projects/MyApp/src/App.swift")])),
        // Awaiting approval
        (id: "s2", cwd: "/Users/demo/Projects/Backend", event: "PreToolUse", tool: "Bash",
         input: .object(["command": .string("docker compose up -d")])),
        (id: "s2", cwd: "/Users/demo/Projects/Backend", event: "PermissionRequest", tool: "Bash",
         input: .object(["command": .string("docker compose up -d")])),
        // Ready
        (id: "s3", cwd: "/Users/demo/Projects/Docs", event: "PreToolUse", tool: "Write",
         input: .object(["file_path": .string("/Users/demo/Projects/Docs/README.md")])),
        (id: "s3", cwd: "/Users/demo/Projects/Docs", event: "Stop", tool: nil, input: nil),
    ])
    let hs = HookServer()
    hs.addMockPending(sessionId: "s2", toolName: "Bash",
                         toolInput: .object(["command": .string("docker compose up -d")]),
                         toolSummary: "docker compose up -d")
    return NotchOverlay(sessionManager: sm, hookServer: hs, appState: AppState())
        .environmentObject(NotchGeometry())
        .frame(width: 500, height: 400)
        .background(.gray.opacity(0.2))
}

#Preview("SpinnerView") {
    HStack(spacing: 20) {
        SpinnerView(color: .green)
            .frame(width: 20, height: 20)
        SpinnerView(color: .blue)
            .frame(width: 30, height: 30)
        SpinnerView(color: .orange)
            .frame(width: 40, height: 40)
    }
    .padding()
}

#Preview("PulseView") {
    HStack(spacing: 20) {
        PulseView(color: .yellow)
            .frame(width: 12, height: 12)
        PulseView(color: .red)
            .frame(width: 12, height: 12)
        PulseView(color: .orange)
            .frame(width: 12, height: 12)
    }
    .padding()
}
#endif
