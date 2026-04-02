import SwiftUI

/// A single line in a computed diff
private struct DiffLine: Identifiable {
    enum Kind { case context, removed, added }
    let id: Int
    let kind: Kind
    let text: String
}

/// Renders a proper line-level diff for Edit tool approvals.
/// Uses LCS (longest common subsequence) to show only actually changed lines
/// as red/green, with unchanged lines as neutral context.
struct EditDiffView: View {
    let filePath: String
    let oldString: String
    let newString: String
    let fontScale: NotchFontScale
    let fg: Color

    @State private var isExpanded = false
    private let maxCollapsedLines = 10

    private var diffLines: [DiffLine] {
        Self.computeDiff(
            old: oldString.components(separatedBy: "\n"),
            new: newString.components(separatedBy: "\n")
        )
    }

    var body: some View {
        let lines = diffLines
        let visible = isExpanded ? lines : Array(lines.prefix(maxCollapsedLines))
        let hiddenCount = lines.count - visible.count

        VStack(alignment: .leading, spacing: 4) {
            // File path header
            Text(shortenPath(filePath))
                .font(.system(size: fontScale.monoSize, design: .monospaced))
                .foregroundStyle(fg.opacity(0.5))
                .lineLimit(1)

            // Diff lines
            VStack(alignment: .leading, spacing: 1) {
                ForEach(visible) { line in
                    diffLineView(line)
                }
            }

            // Collapse / expand
            if !isExpanded && hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true }
                } label: {
                    Text("... +\(hiddenCount) more lines")
                        .font(.system(size: fontScale.badgeSize))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            } else if isExpanded && lines.count > maxCollapsedLines {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded = false }
                } label: {
                    Text("Show less")
                        .font(.system(size: fontScale.badgeSize))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fg.opacity(0.04))
        )
    }

    @ViewBuilder
    private func diffLineView(_ line: DiffLine) -> some View {
        let (prefix, color): (String, Color?) = switch line.kind {
        case .removed: ("−", .red)
        case .added:   ("+", .green)
        case .context:  (" ", nil)
        }

        HStack(spacing: 4) {
            Text(prefix)
                .font(.system(size: fontScale.monoSize, weight: .bold, design: .monospaced))
                .foregroundStyle((color ?? fg).opacity(0.7))
                .frame(width: 12, alignment: .center)
            Text(line.text)
                .font(.system(size: fontScale.monoSize, design: .monospaced))
                .foregroundStyle(fg.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((color ?? .clear).opacity(color != nil ? 0.08 : 0))
    }

    // MARK: - LCS Diff

    /// Computes a minimal line diff using longest common subsequence.
    fileprivate static func computeDiff(old: [String], new: [String]) -> [DiffLine] {
        let m = old.count, n = new.count

        // Build LCS length table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...max(m, 1) {
            guard i <= m else { break }
            for j in 1...max(n, 1) {
                guard j <= n else { break }
                if old[i - 1] == new[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to produce diff
        var result: [DiffLine] = []
        var i = m, j = n, id = 0

        func appendLine(_ kind: DiffLine.Kind, _ text: String) {
            result.append(DiffLine(id: id, kind: kind, text: text))
            id += 1
        }

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && old[i - 1] == new[j - 1] {
                appendLine(.context, old[i - 1])
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                appendLine(.added, new[j - 1])
                j -= 1
            } else {
                appendLine(.removed, old[i - 1])
                i -= 1
            }
        }

        return result.reversed()
    }

    private func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }
}
