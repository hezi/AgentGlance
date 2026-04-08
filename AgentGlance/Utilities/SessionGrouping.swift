import Foundation

struct SessionGroup: Identifiable {
    let id: String
    let title: String
    var sessions: [Session]

    var latestActivity: Date {
        sessions.map(\.lastActivity).max() ?? .distantPast
    }
}

enum SessionGrouper {
    static func group(
        sessions: [Session],
        by mode: SessionGroupMode,
        sortedBy sortMode: GroupSortMode
    ) -> [SessionGroup] {
        guard mode != .none else {
            return [SessionGroup(id: "__all__", title: "", sessions: sessions)]
        }

        let grouped: [String: [Session]]
        let titleMap: [String: String]

        switch mode {
        case .none:
            return [SessionGroup(id: "__all__", title: "", sessions: sessions)]

        case .project:
            grouped = Dictionary(grouping: sessions) { $0.cwd }
            titleMap = Dictionary(uniqueKeysWithValues: grouped.keys.map { key in
                let title = grouped[key]?.first?.projectName ?? key
                return (key, title)
            })

        case .status:
            grouped = Dictionary(grouping: sessions) { $0.state.rawValue }
            titleMap = Dictionary(uniqueKeysWithValues: grouped.keys.map { key in
                (key, stateLabel(for: key))
            })
        }

        var groups = grouped.map { key, sessions in
            SessionGroup(id: key, title: titleMap[key] ?? key, sessions: sessions)
        }

        switch sortMode {
        case .alphabetical:
            groups.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .lastUpdated:
            groups.sort { $0.latestActivity > $1.latestActivity }
        }

        return groups
    }

    private static func stateLabel(for rawValue: String) -> String {
        switch rawValue {
        case "idle": "Idle"
        case "working": "Working"
        case "awaitingApproval": "Awaiting Approval"
        case "ready": "Ready"
        case "complete": "Complete"
        default: rawValue
        }
    }
}
