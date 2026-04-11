import SwiftUI

/// Standalone header bar showing session status — extracted from NotchOverlay
/// so it can be reused in different window contexts.
struct NotchHeaderBar: View {
    var sessions: [Session]
    var fontScale: NotchFontScale = .m
    @Environment(\.colorScheme) private var colorScheme

    private var fg: Color { colorScheme == .dark ? .white : .black }

    private var primarySession: Session? {
        sessions.first(where: { $0.state == .awaitingApproval })
            ?? sessions.first(where: { $0.state == .working })
            ?? sessions.first
    }

    private var urgentLabel: String? {
        let approvals = sessions.filter { $0.state == .awaitingApproval }
        if approvals.count > 1 { return "\(approvals.count) approvals" }
        let working = sessions.filter { $0.state == .working }
        if !approvals.isEmpty && !working.isEmpty {
            return "\(approvals.count) approval, \(working.count) working"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if let session = primarySession {
                stateIndicator(for: session)
                    .frame(width: 10, height: 10)

                Text(resolveHeader(for: session))
                .font(scaledFont(size: fontScale.bodySize, weight: .medium))
                .foregroundStyle(fg.opacity(0.8))
                .lineLimit(1)
            } else {
                Image(systemName: "terminal")
                    .font(scaledFont(size: fontScale.detailSize))
                    .foregroundStyle(fg.opacity(0.5))
                Text("AgentGlance")
                    .font(scaledFont(size: fontScale.bodySize, weight: .medium))
                    .foregroundStyle(fg.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: fontScale.barHeight)
    }

    @ViewBuilder
    private func stateIndicator(for session: Session) -> some View {
        switch session.state {
        case .idle:
            Circle().fill(.gray)
        case .working:
            switch session.workingDetail {
            case .thinking:
                SpinnerView(color: .cyan)
            case .compacting:
                SpinnerView(color: .orange)
            default:
                SpinnerView(color: .green)
            }
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
            switch session.workingDetail {
            case .thinking: "Thinking..."
            case .compacting: "Compacting..."
            case .runningTool:
                if let tool = session.currentTool {
                    "Running \(tool)..."
                } else {
                    "Working..."
                }
            case nil:
                if let tool = session.currentTool {
                    "Running \(tool)..."
                } else {
                    "Working..."
                }
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

    private func resolveHeader(for session: Session) -> String {
        let template: DisplayTemplate = sessions.count > 1
            ? DisplayTemplate.load(forKey: Constants.UserDefaultsKeys.headerTemplate, default: .defaultMultiSessionHeader)
            : DisplayTemplate.load(forKey: Constants.UserDefaultsKeys.headerTemplate, default: .defaultHeader)
        return template.resolve(
            cwdPath: session.projectPath,
            sessionName: session.name,
            stateText: stateText(for: session),
            currentTool: session.currentTool,
            detailText: "",
            elapsedTime: session.elapsedFormatted,
            toolCount: session.toolCount
        )
    }

    private func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if fontScale == .system {
            switch weight {
            case .semibold, .bold: return .subheadline.weight(weight)
            case .medium: return .caption.weight(weight)
            default: return .caption2
            }
        }
        return .system(size: size, weight: weight, design: design)
    }
}
