import SwiftUI

// MARK: - Shared icon components

struct IconSpinnerView: View {
    var color: Color = .green
    var lineWidth: CGFloat = 3
    var rotation: Double = Double.random(in: 0...360)

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(rotation))
    }
}

struct IconPulseView: View {
    var color: Color
    var pulseScale: CGFloat = CGFloat.random(in: 1.2...1.6)

    var body: some View {
        Circle()
            .fill(color)
            .overlay(
                Circle()
                    .fill(color.opacity(0.3))
                    .scaleEffect(pulseScale)
            )
            .clipShape(Circle())
    }
}

struct IconBarView: View {
    var color: Color = .white
    var opacity: Double = 0.25
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(color.opacity(opacity))
            .frame(width: width, height: height)
    }
}

// MARK: - Minimal Icon

struct MinimalAppIcon: View {
    let size: CGFloat

    private var dotSize: CGFloat { size * 0.11 }
    private var barHeight: CGFloat { size * 0.06 }
    private var rowSpacing: CGFloat { size * 0.07 }
    private var pillCorner: CGFloat { size * 0.12 }
    private var pillPadH: CGFloat { size * 0.08 }
    private var pillPadV: CGFloat { size * 0.07 }
    private var iconCorner: CGFloat { size * 0.185 }

    var body: some View {
        VStack(spacing: rowSpacing) {
            row(dot: { IconSpinnerView(color: .green, lineWidth: size * 0.015) },
                barWidth: size * 0.52)

            row(dot: { IconPulseView(color: .yellow) },
                barWidth: size * 0.62)

            row(dot: { IconPulseView(color: .red, pulseScale: 1.0) },
                barWidth: size * 0.42)
        }
        .padding(.horizontal, pillPadH)
        .padding(.vertical, pillPadV)
        .frame(width: size * 0.88)
        .background(
            RoundedRectangle(cornerRadius: pillCorner, style: .continuous)
                .fill(Color(white: 0.08))
        )
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: iconCorner, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.13), Color(white: 0.06)],
                    startPoint: .top, endPoint: .bottom
                ))
        )
        .clipShape(RoundedRectangle(cornerRadius: iconCorner, style: .continuous))
    }

    private func row<D: View>(dot: () -> D, barWidth: CGFloat) -> some View {
        HStack(spacing: size * 0.04) {
            dot()
                .frame(width: dotSize, height: dotSize)
                .frame(width: dotSize)
            IconBarView(width: barWidth, height: barHeight)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Suggestive Icon

struct SuggestiveAppIcon: View {
    let size: CGFloat

    private var dotSize: CGFloat { size * 0.11 }
    private var barHeight: CGFloat { size * 0.06 }
    private var smallBarHeight: CGFloat { size * 0.045 }
    private var rowSpacing: CGFloat { size * 0.025 }
    private var pillCorner: CGFloat { size * 0.12 }
    private var pillPadH: CGFloat { size * 0.06 }
    private var pillPadV: CGFloat { size * 0.05 }
    private var iconCorner: CGFloat { size * 0.185 }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            sessionRow(
                dot: { IconSpinnerView(color: .green, lineWidth: size * 0.015) },
                nameWidth: size * 0.42,
                detailWidth: size * 0.22
            )

            sessionRow(
                dot: { IconPulseView(color: .yellow) },
                nameWidth: size * 0.48,
                detailWidth: size * 0.25
            )

            HStack(spacing: size * 0.03) {
                Color.clear
                    .frame(width: dotSize, height: smallBarHeight)
                IconBarView(opacity: 0.12, width: size * 0.55, height: smallBarHeight)
                Spacer(minLength: 0)
            }

            sessionRow(
                dot: { IconPulseView(color: .red, pulseScale: 1.0) },
                nameWidth: size * 0.35,
                detailWidth: size * 0.22
            )
        }
        .padding(.horizontal, pillPadH)
        .padding(.vertical, pillPadV)
        .frame(width: size * 0.88)
        .background(
            RoundedRectangle(cornerRadius: pillCorner, style: .continuous)
                .fill(Color(white: 0.08))
        )
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: iconCorner, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.33), Color(white: 0.16)],
                    startPoint: .top, endPoint: .bottom
                ))
        )
        .clipShape(RoundedRectangle(cornerRadius: iconCorner, style: .continuous))
    }

    private func sessionRow<D: View>(dot: () -> D, nameWidth: CGFloat, detailWidth: CGFloat) -> some View {
        HStack(spacing: size * 0.03) {
            dot()
                .frame(width: dotSize, height: dotSize)
                .frame(width: dotSize)

            VStack(alignment: .leading, spacing: size * 0.015) {
                IconBarView(opacity: 0.35, width: nameWidth, height: barHeight)
                IconBarView(opacity: 0.15, width: detailWidth, height: smallBarHeight)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Previews

#Preview("Minimal — 512px") {
    MinimalAppIcon(size: 512)
        .padding(40)
        .background(.gray.opacity(0.2))
}

#Preview("Minimal — 128px") {
    MinimalAppIcon(size: 128)
        .padding(40)
        .background(.gray.opacity(0.2))
}

#Preview("Minimal — 32px") {
    MinimalAppIcon(size: 32)
        .padding(40)
        .background(.gray.opacity(0.2))
}

#Preview("Suggestive — 512px") {
    SuggestiveAppIcon(size: 512)
        .padding(40)
        .background(.gray.opacity(0.2))
}

#Preview("Suggestive — 128px") {
    SuggestiveAppIcon(size: 128)
        .padding(40)
        .background(.gray.opacity(0.2))
}

#Preview("Suggestive — 32px") {
    SuggestiveAppIcon(size: 32)
        .padding(40)
        .background(.gray.opacity(0.2))
}

#Preview("Side by Side") {
    HStack(spacing: 40) {
        VStack {
            MinimalAppIcon(size: 256)
            Text("Minimal").font(.caption)
        }
        VStack {
            SuggestiveAppIcon(size: 256)
            Text("Suggestive").font(.caption)
        }
    }
    .padding(40)
    .background(.gray.opacity(0.2))
}
