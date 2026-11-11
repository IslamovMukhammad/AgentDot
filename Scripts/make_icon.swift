#!/usr/bin/env swift
// Draws the AgentDot app icon in code and writes Resources/AppIcon.iconset.
// Usage: swift Scripts/make_icon.swift   (from the package folder)
//
// The design: a dark slate tile with a usage gauge (an arc filled to about three quarters)
// around a glowing status dot, the two things the menu-bar icon shows.

import AppKit

func drawIcon(_ px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = px / 1024   // design in 1024 units

    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: (1024 - y - h) * s, width: w * s, height: h * s)
    }
    func shadowed(_ color: NSColor, blur: CGFloat, y: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur * s
        shadow.shadowOffset = NSSize(width: 0, height: -y * s)
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Tile (macOS icon grid: 824 pt body centred in 1024, radius ~185)
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    shadowed(NSColor.black.withAlphaComponent(0.35), blur: 24, y: 10) { NSColor.black.setFill(); tile.fill() }
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [NSColor(red: 0.17, green: 0.19, blue: 0.24, alpha: 1),
                        NSColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)])!
        .draw(in: tile.bounds, angle: -70)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(ovalIn: r(40, 40, 620, 620)), relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()

    let center = NSPoint(x: 512 * s, y: 512 * s)
    let radius = 270 * s
    let width = 64 * s
    // Gauge track: a 270° arc open at the bottom.
    let start: CGFloat = 225, end: CGFloat = -45
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    track.lineWidth = width
    track.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.12).setStroke()
    track.stroke()

    // Filled part: ~72 %, warm orange to coral.
    let fillEnd = start - 270 * 0.72
    let fill = NSBezierPath()
    fill.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: fillEnd, clockwise: true)
    fill.lineWidth = width
    fill.lineCapStyle = .round
    shadowed(NSColor(red: 1, green: 0.55, blue: 0.25, alpha: 0.55), blur: 30, y: 0) {
        NSColor(red: 0.98, green: 0.58, blue: 0.30, alpha: 1).setStroke()
        fill.stroke()
    }

    // Status dot in the middle: yellow "working", with a soft glow.
    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 110 * s, y: center.y - 110 * s, width: 220 * s, height: 220 * s))
    shadowed(NSColor(red: 1, green: 0.82, blue: 0.2, alpha: 0.8), blur: 60, y: 0) {
        NSColor(red: 1, green: 0.80, blue: 0.22, alpha: 1).setFill()
        dot.fill()
    }
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)])!
        .draw(in: dot, relativeCenterPosition: NSPoint(x: -0.35, y: 0.45))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let folder = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(px).representation(using: .png, properties: [:])!
        try! data.write(to: folder.appendingPathComponent(name))
    }
}
print("Wrote \(folder.path)")
