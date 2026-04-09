import Foundation

enum Constants {
    static let defaultPort: UInt16 = 7483
    static let socketPath = "/tmp/agentglance.sock"
    static let completeFadeDelay: TimeInterval = 8.0
    static let sessionTimeoutInterval: TimeInterval = 300 // 5 minutes no activity = stale

    enum UserDefaultsKeys {
        static let port = "hookServerPort"
        static let sleepPreventionEnabled = "sleepPreventionEnabled"
        static let soundEnabled = "soundEnabled"
        static let showTextInNotch = "showTextInNotch"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let autoExpandOnApproval = "autoExpandOnApproval"
        static let fitNotchToText = "fitNotchToText"
        static let notchFontScale = "notchFontScale"
        static let liquidGlass = "liquidGlass"
        static let glassFrost = "glassFrost"
        static let showAllApprovals = "showAllApprovals"
        static let expandedWidth = "expandedWidth"
        static let appearanceMode = "appearanceMode"
        static let screenSelectionMode = "screenSelectionMode"
        static let selectedScreenID = "selectedScreenID"
        static let pillOffsetX = "pillOffsetX"
        static let pillOffsetY = "pillOffsetY"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyKey = "hotkeyKey"
        static let keyboardNavMode = "keyboardNavMode"
        static let suppressExpansionWhenInTerminal = "suppressExpansionWhenInTerminal"
        static let sessionGroupMode = "sessionGroupMode"
        static let groupSortMode = "groupSortMode"
        static let collapsedGroups = "collapsedGroups"
    }
}

enum SessionGroupMode: String, CaseIterable, Identifiable {
    case none
    case project
    case status

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .project: "Project"
        case .status: "Status"
        }
    }
}

enum GroupSortMode: String, CaseIterable, Identifiable {
    case alphabetical
    case lastUpdated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alphabetical: "Alphabetical"
        case .lastUpdated: "Last Updated"
        }
    }
}

enum KeyboardNavMode: String, CaseIterable, Identifiable {
    case arrows = "arrows"
    case numbers = "numbers"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .arrows: "Arrow Keys"
        case .numbers: "Number Keys"
        }
    }

    var description: String {
        switch self {
        case .arrows: "↑↓ to select rows, ←→ to select actions, Return to execute"
        case .numbers: "Press row number, then action number"
        }
    }
}

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay", default: .init(.c, modifiers: [.command, .shift]))
}

/// An action exposed by a session row for keyboard navigation
struct RowAction {
    let label: String
    let icon: String?
    let execute: () -> Void
}

enum NotchFontScale: String, CaseIterable, Identifiable {
    case system  // use Dynamic Type / accessibility setting
    case xs, s, m, l, xl, xxl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .xs: "XS"
        case .s: "S"
        case .m: "M"
        case .l: "L"
        case .xl: "XL"
        case .xxl: "XXL"
        }
    }

    /// Base font size for body text in the notch
    var bodySize: CGFloat {
        switch self {
        case .system: 0 // sentinel — use .body
        case .xs: 9
        case .s: 10
        case .m: 11
        case .l: 12
        case .xl: 14
        case .xxl: 16
        }
    }

    /// Smaller font for detail/secondary text
    var detailSize: CGFloat {
        switch self {
        case .system: 0
        case .xs: 7.5
        case .s: 8.5
        case .m: 9
        case .l: 10
        case .xl: 12
        case .xxl: 14
        }
    }

    /// Monospaced font size for tool summaries, code
    var monoSize: CGFloat {
        switch self {
        case .system: 0
        case .xs: 8
        case .s: 9
        case .m: 10
        case .l: 11
        case .xl: 13
        case .xxl: 15
        }
    }

    /// Badge/tag font size
    var badgeSize: CGFloat {
        switch self {
        case .system: 0
        case .xs: 7
        case .s: 8
        case .m: 9
        case .l: 10
        case .xl: 11
        case .xxl: 13
        }
    }

    /// Height of the collapsed notch bar
    var barHeight: CGFloat {
        switch self {
        case .system, .xs, .s, .m: 36
        case .l: 38
        case .xl: 42
        case .xxl: 48
        }
    }
}
