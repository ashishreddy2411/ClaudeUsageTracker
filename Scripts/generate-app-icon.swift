#!/usr/bin/env swift
// Generates the macOS app icon PNGs for AppIcon.appiconset.
//
// Why this exists
// ---------------
// The asset catalog declared ten icon slots but shipped no artwork, so the bundle had
// no icon. macOS draws notification icons from the app bundle's icon, which is why
// alerts appeared with a blank/placeholder image.
//
// Why the art is generated rather than sourced
// --------------------------------------------
// The icon must carry no third-party copyright or trademark. Apple licenses SF Symbols
// for in-app UI but explicitly NOT for app icons or logos, and this project must not
// evoke Anthropic's marks. Everything below is drawn from primitives -- rounded rect,
// arcs, gradient -- so the artwork is original to this repository.
//
// Usage: swift Scripts/generate-app-icon.swift [repo-root]

import AppKit
import Foundation

let arguments = CommandLine.arguments
let repoRoot = URL(
    fileURLWithPath: arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
)
let iconSetURL = repoRoot
    .appendingPathComponent("ClaudeUsageBar/Resources/Assets.xcassets/AppIcon.appiconset")

/// macOS icon grid: art occupies the rounded rect, with a margin around it.
/// The 22.37% corner radius matches the system "squircle" proportion closely enough
/// at every raster size we emit.
let cornerRadiusRatio: CGFloat = 0.2237
let marginRatio: CGFloat = 0.0977

/// Fraction of the ring drawn filled. Purely decorative: an icon must look identical
/// on every launch, so it never reflects live usage.
let ringFillFraction: CGFloat = 0.72

func makeIcon(pixelSize: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("could not allocate bitmap for \(pixelSize)px icon")
    }

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create drawing context for \(pixelSize)px icon")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext

    let margin = (size * marginRatio).rounded()
    let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = plate.width * cornerRadiusRatio
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
    }
    let accent = color(0.98, 0.62, 0.29, 1.0)

    // Plate: a deep slate gradient so the ring reads on both light and dark desktops.
    let platePath = CGPath(
        roundedRect: plate,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
    cg.saveGState()
    cg.addPath(platePath)
    cg.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.16, 0.18, 0.23, 1.0), color(0.09, 0.10, 0.13, 1.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    cg.restoreGState()

    // Hairline rim keeps the plate edge crisp against a dark wallpaper.
    cg.addPath(platePath)
    cg.setStrokeColor(color(1, 1, 1, 0.10))
    cg.setLineWidth(max(size * 0.004, 0.5))
    cg.strokePath()

    // Ring: same motif as the menu bar status item, so the two read as one product.
    let center = CGPoint(x: plate.midX, y: plate.midY)
    let ringRadius = plate.width * 0.28
    let ringWidth = plate.width * 0.115
    cg.setLineWidth(ringWidth)
    cg.setLineCap(.round)

    cg.setStrokeColor(color(1, 1, 1, 0.16))
    cg.addArc(
        center: center,
        radius: ringRadius,
        startAngle: 0,
        endAngle: .pi * 2,
        clockwise: false
    )
    cg.strokePath()

    let start = CGFloat.pi / 2
    cg.setStrokeColor(accent)
    cg.addArc(
        center: center,
        radius: ringRadius,
        startAngle: start,
        endAngle: start - (.pi * 2 * ringFillFraction),
        clockwise: true
    )
    cg.strokePath()

    // Center dot anchors the composition at small sizes where the ring alone
    // can read as an empty circle.
    cg.setFillColor(accent)
    let dot = plate.width * 0.055
    cg.fillEllipse(
        in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

struct Slot {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
    var sizeString: String { "\(points)x\(points)" }
    var scaleString: String { "\(scale)x" }
}

let slots: [Slot] = [16, 32, 128, 256, 512].flatMap { points in
    [Slot(points: points, scale: 1), Slot(points: points, scale: 2)]
}

try FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

for slot in slots {
    let rep = makeIcon(pixelSize: slot.pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed for \(slot.filename)")
    }
    try data.write(to: iconSetURL.appendingPathComponent(slot.filename))
    print("wrote \(slot.filename) (\(slot.pixels)px)")
}

// Rewrite Contents.json so every declared slot points at the file just written.
// A slot without a filename is why the bundle previously had no icon.
let entries = slots.map { slot in
    """
        {
          "filename" : "\(slot.filename)",
          "idiom" : "mac",
          "scale" : "\(slot.scaleString)",
          "size" : "\(slot.sizeString)"
        }
    """
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: iconSetURL.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("updated Contents.json with \(slots.count) filenames")
