#!/usr/bin/env swift
//
// Draws the app icon and writes build/AppIcon.iconset.
// Run via scripts/build-app.sh, or on its own: swift scripts/make-icon.swift
//
import AppKit
import Foundation

// The same scale the app uses for bars and the menu bar dot.
let levelColors: [NSColor] = [
    NSColor(srgbRed: 0.30, green: 0.78, blue: 0.47, alpha: 1),  // green
    NSColor(srgbRed: 0.95, green: 0.80, blue: 0.25, alpha: 1),  // yellow
    NSColor(srgbRed: 0.96, green: 0.58, blue: 0.20, alpha: 1),  // orange
    NSColor(srgbRed: 0.93, green: 0.33, blue: 0.31, alpha: 1),  // red
]

/// Colour at `t` (0...1) along the green -> red ramp.
func rampColor(_ t: CGFloat) -> NSColor {
    let clamped = min(max(t, 0), 1)
    let scaled = clamped * CGFloat(levelColors.count - 1)
    let i = min(Int(scaled), levelColors.count - 2)
    let local = scaled - CGFloat(i)
    return levelColors[i].blended(withFraction: local, of: levelColors[i + 1]) ?? levelColors[i]
}

func drawIcon(size: CGFloat, context ctx: CGContext) {
    let s = size / 1024.0  // design on a 1024 grid, then scale
    ctx.saveGState()

    // Rounded-rect plate, inset like Apple's template.
    let inset: CGFloat = 100 * s
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.addPath(platePath)
    ctx.clip()

    // Dark glass, matching the panel.
    let bg = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(srgbRed: 0.24, green: 0.15, blue: 0.42, alpha: 1).cgColor,
            NSColor(srgbRed: 0.11, green: 0.09, blue: 0.20, alpha: 1).cgColor,
            NSColor(srgbRed: 0.35, green: 0.14, blue: 0.16, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        bg,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    ctx.restoreGState()

    // Gauge geometry: a 270-degree arc with the gap at the bottom.
    let center = CGPoint(x: size / 2, y: size / 2)
    let radius = 268 * s
    let lineWidth = 104 * s
    let startAngle = CGFloat.pi * 1.25      // 225 degrees
    let sweep = CGFloat.pi * 1.5            // 270 degrees
    let fill: CGFloat = 0.68                // how full the gauge reads

    // Track.
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.30).cgColor)
    ctx.addArc(center: center, radius: radius,
               startAngle: startAngle, endAngle: startAngle - sweep, clockwise: true)
    ctx.strokePath()

    // Filled part, stepped along the green -> red ramp so the scale is visible.
    let steps = 96
    let filledSteps = Int(CGFloat(steps) * fill)
    for i in 0..<filledSteps {
        let t0 = CGFloat(i) / CGFloat(steps)
        let t1 = CGFloat(i + 1) / CGFloat(steps)
        ctx.setLineCap(i == 0 || i == filledSteps - 1 ? .round : .butt)
        ctx.setStrokeColor(rampColor(t0 / max(fill, 0.0001) * fill).cgColor)
        ctx.addArc(center: center, radius: radius,
                   startAngle: startAngle - sweep * t0,
                   endAngle: startAngle - sweep * (t1 + 0.004),
                   clockwise: true)
        ctx.strokePath()
    }

    // Tip marker at the end of the fill.
    let tipAngle = startAngle - sweep * fill
    let tip = CGPoint(x: center.x + cos(tipAngle) * radius, y: center.y + sin(tipAngle) * radius)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: tip.x - 26 * s, y: tip.y - 26 * s, width: 52 * s, height: 52 * s))

    // Inner dot fills the middle at large sizes. Below 64px it just muddies
    // the ring, so it is left out there.
    if size >= 64 {
        ctx.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 52 * s, y: center.y - 52 * s, width: 104 * s, height: 104 * s))
    }
}

func writePNG(size: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw NSError(domain: "icon", code: 1) }

    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    drawIcon(size: CGFloat(size), context: gc.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try data.write(to: url)
}

// MARK: - main

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Each size is drawn directly rather than downscaled, so small sizes stay crisp.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    try writePNG(size: v.px, to: iconset.appendingPathComponent("\(v.name).png"))
}
print("wrote \(variants.count) images to \(iconset.path)")
