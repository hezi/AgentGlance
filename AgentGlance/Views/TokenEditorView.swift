import SwiftUI

/// A text field for editing display format templates.
/// On macOS 26+, tokens render as styled text inline. On older, plain text.
struct TokenEditorView: View {
    @Binding var template: DisplayTemplate
    let defaultTemplate: DisplayTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if #available(macOS 26, *) {
                    AttributedTokenEditor(template: $template)
                        .frame(height: 22)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.background)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.secondary.opacity(0.2), lineWidth: 0.5)
                        )
                } else {
                    TextField("e.g. {cwd}: {state}", text: $template.format)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                if template != defaultTemplate {
                    Button("Reset") {
                        template = defaultTemplate
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            TokenFlowLayout(spacing: 4) {
                ForEach(DisplayToken.allCases) { token in
                    Button {
                        template.format += token.label
                    } label: {
                        Text(token.displayLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(.blue.opacity(0.7))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Flow Layout

private struct TokenFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews: subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, maxWidth: bounds.width)
        for (i, pos) in result.positions.enumerated() where i < subviews.count {
            subviews[i].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }
        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

// MARK: - Attributed Token Editor (macOS 26+)

@available(macOS 26, *)
private struct AttributedTokenEditor: View {
    @Binding var template: DisplayTemplate
    @State private var attributedText: AttributedString = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var suppressSync = false

    var body: some View {
        TextEditor(text: $attributedText, selection: $selection)
            .font(.system(size: 11))
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .onAppear {
                attributedText = styledString(from: template.format)
            }
            .onChange(of: attributedText) { _, newValue in
                guard !suppressSync else { return }
                let plain = String(newValue.characters)
                if plain != template.format {
                    template.format = plain
                    suppressSync = true
                    attributedText = styledString(from: plain)
                    suppressSync = false
                }
            }
            .onChange(of: template.format) { _, newValue in
                let currentPlain = String(attributedText.characters)
                guard newValue != currentPlain else { return }
                suppressSync = true
                attributedText = styledString(from: newValue)
                suppressSync = false
            }
    }

    private func styledString(from format: String) -> AttributedString {
        let defaultAttrs = AttributeContainer()
            .font(.system(size: 11))
            .foregroundColor(.primary)
            .backgroundColor(Color.clear)

        var result = AttributedString(format, attributes: defaultAttrs)

        for token in DisplayToken.allCases {
            var searchStart = result.startIndex
            while let range = result[searchStart...].range(of: token.label) {
                result[range].setAttributes(
                    AttributeContainer()
                        .foregroundColor(Color.white)
                        .backgroundColor(Color.blue.opacity(0.7))
                        .font(.system(size: 11, weight: .semibold))
                )
                searchStart = range.upperBound
            }
        }

        return result
    }
}
