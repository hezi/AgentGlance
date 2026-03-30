// generate-icon-main.swift
// Compiled together with AppIconViews.swift by the "Generate Icon" target.
// Renders the icon views to PNG files in the asset catalog.

import SwiftUI
import AppKit

@MainActor
func renderView<V: View>(_ view: V, size: CGFloat) -> NSImage {
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

@MainActor
func generateIcons() {
    let assetDir = "AgentGlance/Resources/Assets.xcassets/AppIcon.appiconset"

    let sizes: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]

    let style = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "suggestive"
    print("Generating icon (\(style))...")

    var images: [[String: String]] = []

    for (points, scale) in sizes {
        let pixels = points * scale
        let filename = "icon_\(points)x\(points)@\(scale)x.png"
        let s = CGFloat(pixels)

        let image: NSImage
        switch style {
        case "minimal":
            image = renderView(MinimalAppIcon(size: s), size: s)
        default:
            image = renderView(SuggestiveAppIcon(size: s), size: s)
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

    print("Done!")
}

@main
struct IconGenerator {
    static func main() {
        Task { @MainActor in
            generateIcons()
            exit(0)
        }
        RunLoop.main.run()
    }
}
