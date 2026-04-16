import SwiftUI

/// Shows the agent's last assistant message as a styled card when a session finishes.
/// Dismissed by the user or when the next prompt starts.
struct CompletionCardView: View {
    let message: String
    let fontScale: NotchFontScale
    let fg: Color
    let onDismiss: () -> Void

    @State private var isExpanded = false

    private var lines: [String] {
        message.components(separatedBy: .newlines)
    }

    private var isLong: Bool {
        lines.count > 8
    }

    private var displayLines: [String] {
        isExpanded ? lines : Array(lines.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "text.bubble")
                    .font(.system(size: fontScale.badgeSize))
                    .foregroundStyle(fg.opacity(0.4))
                Text("Agent Response")
                    .font(.system(size: fontScale.badgeSize, weight: .medium))
                    .foregroundStyle(fg.opacity(0.4))
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: fontScale.badgeSize))
                        .foregroundStyle(fg.opacity(0.3))
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                ScrollView {
                    markdownContent
                }
                .frame(maxHeight: 500)
            } else {
                markdownContent
            }

            if isLong {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.system(size: fontScale.badgeSize, weight: .medium))
                    }
                    .foregroundStyle(.blue.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fg.opacity(0.04))
        )
    }

    private var markdownContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                renderLine(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("### ") {
            Text(trimmed.dropFirst(4))
                .font(scaledFont(size: fontScale.bodySize, weight: .semibold))
                .foregroundStyle(fg.opacity(0.9))
                .padding(.top, 2)
        } else if trimmed.hasPrefix("## ") {
            Text(trimmed.dropFirst(3))
                .font(scaledFont(size: fontScale.bodySize, weight: .bold))
                .foregroundStyle(fg.opacity(0.9))
                .padding(.top, 3)
        } else if trimmed.hasPrefix("# ") {
            Text(trimmed.dropFirst(2))
                .font(scaledFont(size: fontScale.bodySize + 2, weight: .bold))
                .foregroundStyle(fg)
                .padding(.top, 2)
        } else if trimmed.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 4) {
                Text("•")
                    .font(scaledFont(size: fontScale.detailSize))
                    .foregroundStyle(fg.opacity(0.5))
                Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                    .font(scaledFont(size: fontScale.detailSize))
                    .foregroundStyle(fg.opacity(0.75))
            }
        } else if trimmed.hasPrefix("```") {
            EmptyView()
        } else if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else {
            Text(LocalizedStringKey(trimmed))
                .font(scaledFont(size: fontScale.detailSize))
                .foregroundStyle(fg.opacity(0.75))
        }
    }

    private func scaledFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if fontScale == .system { return .caption2 }
        return .system(size: size, weight: weight)
    }
}
