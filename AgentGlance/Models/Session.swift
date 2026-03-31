import Foundation

enum SessionState: String, CaseIterable {
    case idle
    case working
    case awaitingApproval
    case ready       // Claude finished responding, waiting for next prompt
    case complete
}

@Observable
final class Session: Identifiable {
    let id: String
    var cwd: String
    var state: SessionState
    var lastActivity: Date
    var currentTool: String?
    var toolCount: Int = 0
    var startTime: Date

    /// Human-readable description of what the pending tool wants to do
    var pendingToolSummary: String?

    /// For ExitPlanMode: plan content and path to the file
    var pendingPlanPreview: String?   // first ~15 lines for collapsed view
    var pendingPlanFull: String?      // full markdown content for expanded view
    var pendingPlanPath: String?

    /// Optional display name from --resume flag
    var name: String?

    /// Permission mode reported by Claude Code (e.g. "default", "plan", "auto", "acceptEdits")
    var permissionMode: String?

    /// Terminal info for navigation
    var tty: String?
    var terminalBundleId: String?
    var processPID: Int?

    /// Throttle enrichment retries
    var lastEnrichmentAttempt: Date?

    var projectName: String {
        var path = cwd
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            path = "~" + path.dropFirst(home.count)
        }
        let maxLength = 30
        if path.count > maxLength {
            path = "…" + path.suffix(maxLength - 1)
        }
        if let name {
            return "\(path) (\(name))"
        }
        return path
    }

    var elapsed: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    var elapsedFormatted: String {
        let total = Int(elapsed)
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    init(id: String, cwd: String) {
        self.id = id
        self.cwd = cwd
        self.state = .idle
        self.lastActivity = Date()
        self.startTime = Date()
    }
}

// MARK: - Permission Mode Display

import SwiftUI

/// Colors match the Claude Code TUI theme (extracted from binary)
enum PermissionModeStyle {
    case plan, auto, acceptEdits, bypass, dontAsk

    init?(_ mode: String?) {
        switch mode {
        case "plan": self = .plan
        case "auto": self = .auto
        case "acceptEdits": self = .acceptEdits
        case "bypassPermissions": self = .bypass
        case "dontAsk": self = .dontAsk
        default: return nil  // "default" and unknown → no badge
        }
    }

    var label: String {
        switch self {
        case .plan: "Plan"
        case .auto: "Auto"
        case .acceptEdits: "Accept"
        case .bypass: "Bypass"
        case .dontAsk: "DontAsk"
        }
    }

    var color: Color {
        switch self {
        case .plan:        Color(red: 0/255, green: 102/255, blue: 102/255)   // teal
        case .auto:        Color(red: 150/255, green: 108/255, blue: 30/255)  // amber
        case .acceptEdits: Color(red: 135/255, green: 0/255, blue: 255/255)   // purple
        case .bypass:      Color(red: 171/255, green: 43/255, blue: 63/255)   // red
        case .dontAsk:     Color(red: 171/255, green: 43/255, blue: 63/255)   // red
        }
    }
}

/// Reusable capsule badge for permission mode — returns nil view for "default" mode
struct ModeBadge: View {
    let mode: String?

    var body: some View {
        if let style = PermissionModeStyle(mode) {
            Text(style.label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(style.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(style.color.opacity(0.15))
                )
        }
    }
}
