import AppKit
import CoreGraphics

/// Builds a demonstration document through the same code paths the UI uses
/// (layers, fills, shape geometry, brush renderer, text rasterisation). Used by
/// `--make-demo` to prove the painting pipeline end-to-end and to produce a
/// realistic screenshot.
enum DemoScene {
    static func make(width: Int = 1024, height: Int = 768) -> Document {
        let doc = Document(width: width, height: height)
        let bg = doc.layers[0]
        bg.name = "Sky"

        // --- Sky gradient (sunset) on the background layer.
        let ctx = bg.raster.bitmapContext
        let colors = [
            CGColor(srgbRed: 0.11, green: 0.12, blue: 0.30, alpha: 1),   // top
            CGColor(srgbRed: 0.55, green: 0.22, blue: 0.38, alpha: 1),
            CGColor(srgbRed: 0.96, green: 0.52, blue: 0.26, alpha: 1)    // horizon
        ] as CFArray
        let skyColors = [
            CGColor(srgbRed: 0.10, green: 0.11, blue: 0.29, alpha: 1),   // night blue
            CGColor(srgbRed: 0.42, green: 0.18, blue: 0.38, alpha: 1),   // magenta
            CGColor(srgbRed: 0.98, green: 0.55, blue: 0.27, alpha: 1),   // horizon orange
            CGColor(srgbRed: 0.13, green: 0.14, blue: 0.30, alpha: 1)    // water
        ] as CFArray
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let grad = CGGradient(colorsSpace: space, colors: skyColors, locations: [0, 0.42, 0.64, 1]) {
            ctx.saveGState()
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: CGFloat(height)),
                                   options: [])
            ctx.restoreGState()
        }

        // --- Sun (filled circle) on its own layer.
        let sun = doc.addLayer(name: "Sun")
        sun.raster.fill(.clear)
        let sunCenter = CGPoint(x: CGFloat(width) * 0.68, y: CGFloat(height) * 0.42)
        sun.raster.bitmapContext.saveGState()
        sun.raster.bitmapContext.setFillColor(CGColor(srgbRed: 1.0, green: 0.86, blue: 0.45, alpha: 0.95))
        sun.raster.bitmapContext.fillEllipse(in: CGRect(x: sunCenter.x - 62, y: sunCenter.y - 62,
                                                        width: 124, height: 124))
        sun.raster.bitmapContext.restoreGState()

        // --- Mountains: filled triangles via the shape engine, on their own layer.
        let hills = doc.addLayer(name: "Mountains")
        hills.raster.fill(.clear)
        drawFilledShape(kind: .triangle,
                        rect: CGRect(x: -60, y: CGFloat(height) * 0.60, width: CGFloat(width) * 0.55, height: CGFloat(height) * 0.5),
                        fill: PixelColor(r: 21, g: 23, b: 52), into: hills.raster)
        drawFilledShape(kind: .triangle,
                        rect: CGRect(x: CGFloat(width) * 0.32, y: CGFloat(height) * 0.64, width: CGFloat(width) * 0.62, height: CGFloat(height) * 0.48),
                        fill: PixelColor(r: 28, g: 30, b: 66), into: hills.raster)

        // --- Water reflection band.
        let water = doc.addLayer(name: "Water")
        water.opacity = 0.55
        water.blendMode = .screen
        water.raster.fill(.clear)
        water.raster.bitmapContext.saveGState()
        let wgrad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [CGColor(srgbRed: 0.98, green: 0.58, blue: 0.32, alpha: 0.65),
                                        CGColor(srgbRed: 0.10, green: 0.12, blue: 0.28, alpha: 0.05)] as CFArray,
                               locations: [0, 1])!
        water.raster.bitmapContext.drawLinearGradient(wgrad,
                                                      start: CGPoint(x: 0, y: CGFloat(height) * 0.64),
                                                      end: CGPoint(x: 0, y: CGFloat(height)),
                                                      options: [])
        water.raster.bitmapContext.restoreGState()

        // --- Brush strokes and pencil marks on a "Sketch" layer.
        let sketch = doc.addLayer(name: "Sketch")
        sketch.raster.fill(.clear)
        let brushCtx = sketch.raster.bitmapContext
        brushCtx.saveGState()
        brushCtx.setAlpha(0.9)
        var prev = CGPoint(x: 120, y: CGFloat(height) * 0.86)
        for i in 1...40 {
            let t = CGFloat(i) / 40
            let next = CGPoint(x: 120 + t * 460,
                               y: CGFloat(height) * 0.86 - sin(t * .pi * 2.2) * 34 - t * 22)
            BrushRenderer.strokeLine(into: brushCtx, from: prev, to: next,
                                     radius: 5.5, spacing: 0.06,
                                     color: PixelColor(r: 255, g: 244, b: 214, a: 235),
                                     softness: 0.7)
            prev = next
        }
        brushCtx.restoreGState()

        // A star outline and a rectangle, to exercise shape geometry + styles.
        let decor = doc.addLayer(name: "Decor")
        decor.raster.fill(.clear)
        let style = ShapeStyle(outlineEnabled: true, fillEnabled: false, lineWidth: 3, lineStyle: .dash)
        ShapeDraw.draw(kind: .star, rect: CGRect(x: 810, y: 470, width: 130, height: 120),
                       style: style, color: PixelColor(r: 255, g: 240, b: 190),
                       fillColor: .clear, into: decor.raster.bitmapContext, scale: 1)
        ShapeDraw.draw(kind: .rectangle, rect: CGRect(x: 690, y: 130, width: 210, height: 120),
                       style: ShapeStyle(outlineEnabled: true, fillEnabled: true, lineWidth: 2, lineStyle: .solid),
                       color: PixelColor(r: 240, g: 250, b: 255),
                       fillColor: PixelColor(r: 40, g: 80, b: 120, a: 120),
                       into: decor.raster.bitmapContext, scale: 1)

        // --- Title text as a layer (rasterised with AppKit text).
        let text = doc.addLayer(name: "Title")
        text.raster.fill(.clear)
        NSGraphicsContext.saveGraphicsState()
        do {
            let nsctx = NSGraphicsContext(cgContext: text.raster.bitmapContext, flipped: true)
            NSGraphicsContext.current = nsctx
            let title = NSAttributedString(string: "PaintCraft", attributes: [
                .font: NSFont.systemFont(ofSize: 86, weight: .bold),
                .foregroundColor: NSColor(srgbRed: 1, green: 0.98, blue: 0.92, alpha: 1)
            ])
            title.draw(at: CGPoint(x: 96, y: 92))
            let subtitle = NSAttributedString(string: "a clean-room Paint for macOS", attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 1, green: 0.93, blue: 0.80, alpha: 0.9)
            ])
            subtitle.draw(at: CGPoint(x: 100, y: 196))
        }
        NSGraphicsContext.restoreGraphicsState()

        // Leaves the Title layer active, like a user finishing a drawing.
        doc.activeLayerIndex = doc.layers.count - 1
        doc.documentName = "PaintCraft Demo"
        doc.dirty = false
        doc.markChanged()
        return doc
    }

    private static func drawFilledShape(kind: ToolKind, rect: CGRect, fill: PixelColor, into raster: Raster) {
        let path = ShapeGeometry.path(for: kind, in: rect)
        let c = fill.premultiplied
        raster.bitmapContext.saveGState()
        raster.bitmapContext.setFillColor(CGColor(srgbRed: CGFloat(c.0) / 255,
                                                  green: CGFloat(c.1) / 255,
                                                  blue: CGFloat(c.2) / 255,
                                                  alpha: CGFloat(c.3) / 255))
        raster.bitmapContext.addPath(path)
        raster.bitmapContext.fillPath()
        raster.bitmapContext.restoreGState()
    }
}
