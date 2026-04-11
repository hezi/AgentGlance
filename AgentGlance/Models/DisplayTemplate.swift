import Foundation

// MARK: - Display Token

enum DisplayToken: String, CaseIterable, Identifiable {
    case cwd
    case name
    case state
    case tool
    case detail
    case time
    case tools_count

    var id: String { rawValue }
    var label: String { "{\(rawValue)}" }

    var displayLabel: String {
        switch self {
        case .cwd: "Path"
        case .name: "Name"
        case .state: "State"
        case .tool: "Tool"
        case .detail: "Detail"
        case .time: "Time"
        case .tools_count: "Tool Count"
        }
    }

    /// Find all valid tokens in a string
    static func tokens(in string: String) -> [(token: DisplayToken, range: Range<String.Index>)] {
        var results: [(DisplayToken, Range<String.Index>)] = []
        for token in allCases {
            var searchStart = string.startIndex
            while let range = string.range(of: token.label, range: searchStart..<string.endIndex) {
                results.append((token, range))
                searchStart = range.upperBound
            }
        }
        return results.sorted(by: { $0.1.lowerBound < $1.1.lowerBound })
    }
}

// MARK: - Display Template (simple string-based)

struct DisplayTemplate: Codable, Equatable {
    var format: String

    /// Resolve the template by replacing token placeholders with actual values.
    func resolve(
        cwdPath: String,
        sessionName: String?,
        stateText: String,
        currentTool: String?,
        detailText: String,
        elapsedTime: String,
        toolCount: Int
    ) -> String {
        var result = format
        result = result.replacingOccurrences(of: DisplayToken.cwd.label, with: cwdPath)
        result = result.replacingOccurrences(of: DisplayToken.name.label, with: sessionName ?? "")
        result = result.replacingOccurrences(of: DisplayToken.state.label, with: stateText)
        result = result.replacingOccurrences(of: DisplayToken.tool.label, with: currentTool ?? "")
        result = result.replacingOccurrences(of: DisplayToken.detail.label, with: detailText)
        result = result.replacingOccurrences(of: DisplayToken.time.label, with: elapsedTime)
        result = result.replacingOccurrences(of: DisplayToken.tools_count.label, with: "\(toolCount)")
        // Clean up artifacts from empty tokens (e.g. " ()" when name is nil)
        result = result.replacingOccurrences(of: " ()", with: "")
        result = result.replacingOccurrences(of: "()", with: "")
        result = result.replacingOccurrences(of: "  ", with: " ")
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Defaults

    static let defaultHeader = DisplayTemplate(format: "{cwd} ({name}): {state}")
    static let defaultMultiSessionHeader = DisplayTemplate(format: "{cwd} ({name}): {state}")
    static let defaultRowTitle = DisplayTemplate(format: "{cwd} ({name})")

    // MARK: - Persistence

    static func load(forKey key: String, default defaultTemplate: DisplayTemplate) -> DisplayTemplate {
        guard let saved = UserDefaults.standard.string(forKey: key) else {
            return defaultTemplate
        }
        return DisplayTemplate(format: saved)
    }

    func save(forKey key: String) {
        UserDefaults.standard.set(format, forKey: key)
    }
}
