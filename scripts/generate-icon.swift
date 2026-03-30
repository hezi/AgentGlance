#!/usr/bin/env swift
//
// generate-icon.swift
// Renders the AgentGlance app icon from live SwiftUI views
// and exports all required sizes to the asset catalog.
//
// Usage:
//   swift scripts/generate-icon.swift              # default (minimal)
//   swift scripts/generate-icon.swift minimal      # three dots + one bar each
//   swift scripts/generate-icon.swift suggestive   # dots + two bars per row, varying widths
//
// Each run captures a unique animation frame (random spinner angle, pulse scale).

import SwiftUI
import AppKit

// MARK: - Shared components

struct IconSpinner: View {
    var color: Color = .green
    var lineWidth: CGFloat = 3
    @State private var rotation: Double = Double.random(in: 0...360)

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(rotation))
    }
}

struct IconPulse: View {
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
            .clipShape(Circle()) // prevent glow from expanding the frame
    }
}

// MARK: - Abstract bar (rounded rect representing text)

struct IconBar: View {
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

// MARK: - Icon Styles

enum IconStyle: String {
    case minimal
    case suggestive
}

// MARK: - Minimal Icon: dots + one bar per row

struct MinimalIconView: View {
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
            row(dot: { IconSpinner(color: .green, lineWidth: size * 0.015) },
                barWidth: size * 0.52)

            row(dot: { IconPulse(color: .yellow) },
                barWidth: size * 0.62)

            row(dot: { IconPulse(color: .red, pulseScale: 1.0) },
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
                .frame(width: dotSize) // fixed column width for alignment
            IconBar(width: barWidth, height: barHeight)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Suggestive Icon: dots + two bars per row, varying widths

struct SuggestiveIconView: View {
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
            // Working session
            sessionRow(
                dot: { IconSpinner(color: .green, lineWidth: size * 0.015) },
                nameWidth: size * 0.42,
                detailWidth: size * 0.22
            )

            // Approval session
            sessionRow(
                dot: { IconPulse(color: .yellow) },
                nameWidth: size * 0.48,
                detailWidth: size * 0.25
            )

            // Approval command hint (indented to align with bars)
            HStack(spacing: size * 0.03) {
                Color.clear
                    .frame(width: dotSize, height: smallBarHeight)
                IconBar(opacity: 0.12, width: size * 0.55, height: smallBarHeight)
                Spacer(minLength: 0)
            }

            // Ready session
            sessionRow(
                dot: { IconPulse(color: .red, pulseScale: 1.0) },
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
                    colors: [Color(white: 0.13), Color(white: 0.06)],
                    startPoint: .top, endPoint: .bottom
                ))
        )
        .clipShape(RoundedRectangle(cornerRadius: iconCorner, style: .continuous))
    }

    private func sessionRow<D: View>(dot: () -> D, nameWidth: CGFloat, detailWidth: CGFloat) -> some View {
        HStack(spacing: size * 0.03) {
            dot()
                .frame(width: dotSize, height: dotSize)
                .frame(width: dotSize) // fixed column width for alignment

            VStack(alignment: .leading, spacing: size * 0.015) {
                IconBar(opacity: 0.35, width: nameWidth, height: barHeight)
                IconBar(opacity: 0.15, width: detailWidth, height: smallBarHeight)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Render

@MainActor
func renderIcon<V: View>(view: V, size: CGFloat) -> NSImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0
    guard let cgImage = renderer.cgImage else {
        fatalError("Failed to render icon at size \(size)")
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to create PNG")
    }
    try! pngData.write(to: URL(fileURLWithPath: path))
    print("  \(path) (\(Int(image.size.width))x\(Int(image.size.height)))")
}

// MARK: - Main

@MainActor
func generateIcons(style: IconStyle) {
    let assetDir = "AgentGlance/Resources/Assets.xcassets/AppIcon.appiconset"

    let sizes: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]

    // Glow threshold: only add glow for icons >= 128px
    let glowThreshold = 128

    print("Generating AgentGlance icon (\(style.rawValue))...")

    var images: [[String: String]] = []

    for (points, scale) in sizes {
        let pixels = points * scale
        let filename = "icon_\(points)x\(points)@\(scale)x.png"
        let s = CGFloat(pixels)

        let image: NSImage
        switch style {
        case .minimal:
            image = renderIcon(view: MinimalIconView(size: s), size: s)
        case .suggestive:
            image = renderIcon(view: SuggestiveIconView(size: s), size: s)
        }

        savePNG(image, to: "\(assetDir)/\(filename)")

        images.append([
            "idiom": "mac",
            "size": "\(points)x\(points)",
            "scale": "\(scale)x",
            "filename": filename,
        ])
    }

    let contents: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1] as [String: Any]
    ]
    let jsonData = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try! jsonData.write(to: URL(fileURLWithPath: "\(assetDir)/Contents.json"))

    print("\nDone! Run again for a different animation frame.")
}

// Parse args
let style: IconStyle
if CommandLine.arguments.count > 1 {
    style = IconStyle(rawValue: CommandLine.arguments[1]) ?? .minimal
} else {
    style = .minimal
}

Task { @MainActor in
    generateIcons(style: style)
    exit(0)
}
RunLoop.main.run()
