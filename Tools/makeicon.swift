import AppKit
import Foundation

// makeicon.swift — draws the PaintCraft application icon with AppKit and
// produces build/AppIcon.icns.
//
// Usage:
//   swiftc -framework AppKit Tools/makeicon.swift -o build/makeicon
//   ./build/makeicon            # writes build/AppIcon.iconset + build/AppIcon.icns
//
// The artwork is original: a rounded blue tile, a white canvas with paint
// strokes, a painter's palette and a brush. No Microsoft assets, logos or
// trademarks are used or referenced.

// MARK: - Helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

// MARK: - Artwork

/// Draws the icon in a 1024x1024 logical space (origin bottom-left).
func drawIcon() {
    let full = NSRect(x: 0, y: 0, width: 1024, height: 1024)

    // 1. Rounded app tile with a vertical blue gradient.
    let tileRect = NSRect(x: 40, y: 40, width: 944, height: 944)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 210, yRadius: 210)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [rgb(0x63B3FF), rgb(0x1D4EA8)])?.draw(in: tile, angle: -75)
    // Soft highlight in the upper-left corner.
    NSGradient(starting: NSColor(white: 1, alpha: 0.28),
               ending: NSColor(white: 1, alpha: 0))?.draw(
        fromCenter: NSPoint(x: 300, y: 760), radius: 0,
        toCenter: NSPoint(x: 300, y: 760), radius: 640,
        options: [])
    // Subtle diagonal sheen.
    let sheen = NSBezierPath()
    sheen.move(to: NSPoint(x: 40, y: 560))
    sheen.line(to: NSPoint(x: 640, y: 984))
    sheen.line(to: NSPoint(x: 880, y: 984))
    sheen.line(to: NSPoint(x: 40, y: 300))
    sheen.close()
    NSColor(white: 1, alpha: 0.055).setFill()
    sheen.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Inner rim to make the tile feel crafted.
    NSColor(white: 1, alpha: 0.16).setStroke()
    let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 6, dy: 6), xRadius: 204, yRadius: 204)
    rim.lineWidth = 5
    rim.stroke()

    // 2. White canvas, slightly raised with a drop shadow.
    let canvasRect = NSRect(x: 214, y: 250, width: 596, height: 596)
    let canvas = NSBezierPath(roundedRect: canvasRect, xRadius: 26, yRadius: 26)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    NSColor(white: 0.995, alpha: 1).setFill()
    canvas.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 3. Paint strokes on the canvas (clipped so they stay inside).
    NSGraphicsContext.saveGraphicsState()
    canvas.addClip()

    // Coral swoosh.
    let coral = NSBezierPath()
    coral.move(to: NSPoint(x: 262, y: 520))
    coral.curve(to: NSPoint(x: 772, y: 700),
                controlPoint1: NSPoint(x: 420, y: 470),
                controlPoint2: NSPoint(x: 600, y: 790))
    coral.lineWidth = 74
    coral.lineCapStyle = .round
    rgb(0xFF5C5C).setStroke()
    coral.stroke()

    // Golden wave.
    let gold = NSBezierPath()
    gold.move(to: NSPoint(x: 262, y: 392))
    gold.curve(to: NSPoint(x: 742, y: 436),
               controlPoint1: NSPoint(x: 420, y: 310),
               controlPoint2: NSPoint(x: 560, y: 520))
    gold.lineWidth = 58
    gold.lineCapStyle = .round
    rgb(0xFFC93C).setStroke()
    gold.stroke()

    // Teal splash with a round dot.
    let teal = NSBezierPath()
    teal.move(to: NSPoint(x: 286, y: 296))
    teal.line(to: NSPoint(x: 612, y: 310))
    teal.lineWidth = 48
    teal.lineCapStyle = .round
    rgb(0x27C4B8).setStroke()
    teal.stroke()
    rgb(0x6C5CE7).setFill()
    NSBezierPath(ovalIn: NSRect(x: 540, y: 560, width: 96, height: 96)).fill()
    rgb(0x27C4B8).setFill()
    NSBezierPath(ovalIn: NSRect(x: 410, y: 600, width: 58, height: 58)).fill()

    NSGraphicsContext.restoreGraphicsState()

    // Canvas hairline.
    NSColor(white: 0, alpha: 0.12).setStroke()
    canvas.lineWidth = 3
    canvas.stroke()

    // 4. Painter's palette overlapping the canvas, bottom-left.
    NSGraphicsContext.saveGraphicsState()
    let paletteRect = NSRect(x: 108, y: 88, width: 372, height: 286)
    let palette = NSBezierPath(ovalIn: paletteRect)
    let thumbHole = NSBezierPath(ovalIn: NSRect(x: 168, y: 210, width: 92, height: 92))
    palette.append(thumbHole)
    palette.windingRule = .evenOdd
    let paletteShadow = NSShadow()
    paletteShadow.shadowColor = NSColor(white: 0, alpha: 0.30)
    paletteShadow.shadowBlurRadius = 26
    paletteShadow.shadowOffset = NSSize(width: 0, height: -14)
    paletteShadow.set()
    rgb(0xFBF7EF).setFill()
    palette.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0, alpha: 0.18).setStroke()
    palette.windingRule = .evenOdd
    palette.lineWidth = 4
    palette.stroke()

    // Paint wells on the palette.
    let wells: [(NSRect, UInt32)] = [
        (NSRect(x: 360, y: 270, width: 64, height: 64), 0xFF5C5C),
        (NSRect(x: 405, y: 190, width: 60, height: 60), 0xFFC93C),
        (NSRect(x: 350, y: 122, width: 56, height: 56), 0x27C4B8),
        (NSRect(x: 268, y: 108, width: 52, height: 52), 0x4C8DFF),
        (NSRect(x: 168, y: 122, width: 48, height: 48), 0xAF52DE)
    ]
    for (rect, hex) in wells {
        rgb(hex).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        let highlight = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
        highlight.lineWidth = 3
        highlight.stroke()
    }

    // 5. Brush lying diagonally across the upper-right of the canvas.
    let start = NSPoint(x: 596, y: 258)
    let end = NSPoint(x: 884, y: 762)
    let delta = NSPoint(x: end.x - start.x, y: end.y - start.y)
    let length = sqrt(delta.x * delta.x + delta.y * delta.y)
    let dir = NSPoint(x: delta.x / length, y: delta.y / length)
    let normal = NSPoint(x: -dir.y, y: dir.x)

    func point(_ base: NSPoint, _ along: CGFloat, _ across: CGFloat) -> NSPoint {
        NSPoint(x: base.x + dir.x * along + normal.x * across,
                y: base.y + dir.y * along + normal.y * across)
    }

    // Handle.
    let handleStart = point(start, 0, 0)
    let handleEnd = point(start, length * 0.66, 0)
    let handle = NSBezierPath()
    handle.move(to: handleStart)
    handle.line(to: handleEnd)
    handle.lineWidth = 56
    handle.lineCapStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let brushShadow = NSShadow()
    brushShadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    brushShadow.shadowBlurRadius = 22
    brushShadow.shadowOffset = NSSize(width: -10, height: -12)
    brushShadow.set()
    rgb(0xC98B4B).setStroke()
    handle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    // Handle highlight.
    let highlightPath = NSBezierPath()
    highlightPath.move(to: point(start, 24, 10))
    highlightPath.line(to: point(start, length * 0.60, 10))
    highlightPath.lineWidth = 14
    highlightPath.lineCapStyle = .round
    NSColor(white: 1, alpha: 0.38).setStroke()
    highlightPath.stroke()

    // Ferrule.
    let ferruleStart = point(start, length * 0.66, 0)
    let ferruleEnd = point(start, length * 0.81, 0)
    let ferrule = NSBezierPath()
    ferrule.move(to: ferruleStart)
    ferrule.line(to: ferruleEnd)
    ferrule.lineWidth = 62
    ferrule.lineCapStyle = .butt
    rgb(0xD8E0EA).setStroke()
    ferrule.stroke()
    let ferruleLine = NSBezierPath()
    ferruleLine.move(to: point(start, length * 0.70, 0))
    ferruleLine.line(to: point(start, length * 0.70, 26))
    ferruleLine.lineWidth = 5
    NSColor(white: 0.45, alpha: 0.55).setStroke()
    ferruleLine.stroke()

    // Bristles: a tapered tip loaded with coral paint.
    let brushTip = NSBezierPath()
    brushTip.move(to: point(start, length * 0.80, 30))
    brushTip.curve(to: point(start, length * 0.99, 0),
                   controlPoint1: point(start, length * 0.88, 30),
                   controlPoint2: point(start, length * 0.94, 14))
    brushTip.curve(to: point(start, length * 0.80, -30),
                   controlPoint1: point(start, length * 0.94, -14),
                   controlPoint2: point(start, length * 0.88, -30))
    brushTip.close()
    rgb(0x3B3B44).setFill()
    brushTip.fill()
    let paintTip = NSBezierPath()
    paintTip.move(to: point(start, length * 0.93, 0))
    paintTip.curve(to: point(start, length * 0.99, 0),
                   controlPoint1: point(start, length * 0.95, 12),
                   controlPoint2: point(start, length * 0.97, 8))
    paintTip.lineWidth = 16
    paintTip.lineCapStyle = .round
    rgb(0xFF5C5C).setStroke()
    paintTip.stroke()

    // 6. A couple of sparkles for a friendly finish.
    drawSparkle(center: NSPoint(x: 742, y: 894), radius: 30, color: NSColor(white: 1, alpha: 0.92))
    drawSparkle(center: NSPoint(x: 842, y: 930), radius: 16, color: NSColor(white: 1, alpha: 0.8))
    _ = full
}

func drawSparkle(center: NSPoint, radius: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    let inner = radius * 0.22
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    path.curve(to: NSPoint(x: center.x + radius, y: center.y),
               controlPoint1: NSPoint(x: center.x + inner, y: center.y + inner),
               controlPoint2: NSPoint(x: center.x + inner, y: center.y + inner))
    path.curve(to: NSPoint(x: center.x, y: center.y - radius),
               controlPoint1: NSPoint(x: center.x + inner, y: center.y - inner),
               controlPoint2: NSPoint(x: center.x + inner, y: center.y - inner))
    path.curve(to: NSPoint(x: center.x - radius, y: center.y),
               controlPoint1: NSPoint(x: center.x - inner, y: center.y - inner),
               controlPoint2: NSPoint(x: center.x - inner, y: center.y - inner))
    path.curve(to: NSPoint(x: center.x, y: center.y + radius),
               controlPoint1: NSPoint(x: center.x - inner, y: center.y + inner),
               controlPoint2: NSPoint(x: center.x - inner, y: center.y + inner))
    path.close()
    color.setFill()
    path.fill()
}

// MARK: - Rendering

func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        return nil
    }
    let scale = CGFloat(pixels) / 1024.0
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Locate the project root and write the iconset

let fileManager = FileManager.default
var root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
while root.path != "/" && !fileManager.fileExists(atPath: root.appendingPathComponent("Sources").path) {
    root.deleteLastPathComponent()
}
if root.path == "/" {
    root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
}

let buildDir = root.appendingPathComponent("build", isDirectory: true)
let iconset = buildDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fileManager.createDirectory(at: buildDir, withIntermediateDirectories: true)
try? fileManager.removeItem(at: iconset)
do {
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("cannot create iconset: \(error)\n".utf8))
    exit(1)
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

var written = 0
for (name, pixels) in entries {
    guard let data = renderPNG(pixels: pixels) else {
        FileHandle.standardError.write(Data("render failed for \(name)\n".utf8))
        exit(1)
    }
    let url = iconset.appendingPathComponent(name)
    do {
        try data.write(to: url)
        written += 1
    } catch {
        FileHandle.standardError.write(Data("write failed for \(name): \(error)\n".utf8))
        exit(1)
    }
}
print("rendered \(written) iconset images into \(iconset.path)")

// Convert to .icns with the system iconutil.
let icns = buildDir.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
do {
    try process.run()
    process.waitUntilExit()
} catch {
    FileHandle.standardError.write(Data("could not run iconutil: \(error)\n".utf8))
    exit(1)
}
if process.terminationStatus != 0 {
    FileHandle.standardError.write(Data("iconutil failed with status \(process.terminationStatus)\n".utf8))
    exit(1)
}
var icnsSize = 0
if let attributes = try? fileManager.attributesOfItem(atPath: icns.path),
   let bytes = attributes[.size] as? Int {
    icnsSize = bytes
}
print("wrote \(icns.path) (\(icnsSize) bytes)")
