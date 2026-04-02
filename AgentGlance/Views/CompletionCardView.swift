import SwiftUI

/// Shows the agent's last assistant message as a styled card when a session finishes.
/// Auto-collapses after a timeout or on user dismiss.
struct CompletionCardView: View {
    let message: String
    let fontScale: NotchFontScale
    let fg: Color
    let onDismiss: () -> Void

    @State private var isExpanded = false
    @State private var isTruncated = false

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

            // Measure full height vs clamped height to detect truncation
            Text(message)
                .font(.system(size: fontScale.detailSize))
                .foregroundStyle(fg.opacity(0.6))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(isExpanded ? nil : 5)
                .background(
                    // Hidden full-height copy to detect if lineLimit clips
                    Text(message)
                        .font(.system(size: fontScale.detailSize))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(nil)
                        .hidden()
                        .overlay(
                            GeometryReader { full in
                                Text(message)
                                    .font(.system(size: fontScale.detailSize))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(5)
                                    .hidden()
                                    .overlay(
                                        GeometryReader { clamped in
                                            Color.clear
                                                .onAppear {
                                                    isTruncated = full.size.height > clamped.size.height + 2
                                                }
                                        }
                                    )
                            }
                        )
                )

            if isTruncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded ? "Show less" : "Show more")
                        .font(.system(size: fontScale.badgeSize))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fg.opacity(0.04))
        )
        .task {
            // Auto-collapse after 15 seconds
            try? await Task.sleep(for: .seconds(15))
            onDismiss()
        }
    }
}
