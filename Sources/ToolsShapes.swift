// SELF-TEST: (shapes & curve)
// 1. Line/Shape tools: drag to draw. The live preview (followed by the shape on
//    release) must match exactly — antialiased edges, current color, opacity,
//    outline/fill switches and line style/width from the ribbon all apply.
// 2. Shift while dragging constrains rectangles/ellipses to a square/circle.
//    Line drawing ignores Shift (free angle).
// 3. With an active rectangular or free-form selection, shapes are clipped to
//    the selection mask; nothing leaks outside the marching ants.
// 4. A click without a drag paints nothing and leaves no stray undo entry.
//    Draw, then Undo/Redo: only the shape's bounding box is restored/repainted.
// 5. Curve (C): drag to draw the initial line, release, then move the mouse and
//    click to bend the curve; releasing applies it as one "Curve" undo step.
//    Escape during either phase discards the pending curve.
// 6. Small shapes, zero-size drags and locked layers never crash (locked layers
//    report "Layer is locked").
//
// Shape tools: line, rectangle, rounded rectangle, ellipse, triangle, polygon,
// diamond, arrow, star and the two-click curve tool. All shapes share shape
// geometry and style handling; drawing is antialiased and clipped to the active
// selection mask.
import AppKit
import CoreGraphics

// MARK: - Shape geometry

/// Builds the path for each shape kind inside a rect (image coordinates).
enum ShapeGeometry {
    static func path(for kind: ToolKind, in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        let r = rect.standardized
        switch kind {
        case .line:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        case .rectangle:
            p.addRect(r)
        case .roundedRectangle:
            let radius = min(r.width, r.height) * 0.18
            p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        case .ellipse:
            p.addEllipse(in: r)
        case .triangle:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .polygon:
            addPolygon(p, in: r, sides: 6)
        case .diamond:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        case .arrow:
            addArrow(p, in: r)
        case .star:
            addStar(p, in: r, points: 5)
        default:
            p.addRect(r)
        }
        return p
    }

    static func addPolygon(_ p: CGMutablePath, in r: CGRect, sides: Int) {
        let cx = r.midX, cy = r.midY
        let rx = r.width / 2, ry = r.height / 2
        for i in 0..<max(3, sides) {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * (2 * .pi / CGFloat(max(3, sides)))
            let pt = CGPoint(x: cx + cos(angle) * rx, y: cy + sin(angle) * ry)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
    }

    static func addStar(_ p: CGMutablePath, in r: CGRect, points: Int) {
        let cx = r.midX, cy = r.midY
        let outerX = r.width / 2, outerY = r.height / 2
        let innerX = outerX * 0.382, innerY = outerY * 0.382
        let total = max(4, points * 2)
        for i in 0..<total {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * (.pi / CGFloat(points))
            let rx = i % 2 == 0 ? outerX : innerX
            let ry = i % 2 == 0 ? outerY : innerY
            let pt = CGPoint(x: cx + cos(angle) * rx, y: cy + sin(angle) * ry)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
    }

    static func addArrow(_ p: CGMutablePath, in r: CGRect) {
        // Arrow pointing right, body ~42% of the height.
        let bodyH = max(1, r.height * 0.42)
        let headW = min(r.width, max(1, r.width * 0.34))
        let top = r.midY - bodyH / 2
        let bottom = r.midY + bodyH / 2
        p.move(to: CGPoint(x: r.minX, y: top))
        p.addLine(to: CGPoint(x: r.maxX - headW, y: top))
        p.addLine(to: CGPoint(x: r.maxX - headW, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - headW, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - headW, y: bottom))
        p.addLine(to: CGPoint(x: r.minX, y: bottom))
        p.closeSubpath()
    }
}

// MARK: - Shape drawing helper

enum ShapeDraw {
    /// Draws the shape according to current style. Called both for the live
    /// preview (on the view context) and on commit (into the layer bitmap).
    /// `scale` converts style line widths (points) into context pixels.
    static func draw(kind: ToolKind, rect: CGRect, style: ShapeStyle,
                     color: PixelColor, fillColor: PixelColor,
                     into ctx: CGContext, scale: CGFloat) {
        let path = ShapeGeometry.path(for: kind, in: rect)
        let unit = max(scale, 0.0001)
        ctx.saveGState()
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        if style.fillEnabled && kind != .line && kind != .curve {
            ctx.setFillColor(cgColor(fillColor))
            ctx.addPath(path)
            ctx.fillPath()
        }
        if style.outlineEnabled {
            ctx.setStrokeColor(cgColor(color))
            ctx.setLineWidth(max(0.5, style.lineWidth / unit))
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            if let pattern = style.lineStyle.cgPattern {
                ctx.setLineDash(phase: 0, lengths: pattern.map { $0 / unit })
            } else {
                ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    static func cgColor(_ color: PixelColor) -> CGColor {
        CGColor(srgbRed: CGFloat(color.r) / 255.0,
                green: CGFloat(color.g) / 255.0,
                blue: CGFloat(color.b) / 255.0,
                alpha: CGFloat(color.a) / 255.0)
    }
}

// MARK: - Shape tool base

class ShapeTool: Tool {
    var kind: ToolKind { .rectangle }
    var cursorName: NSCursorName { .crosshair }

    private var start: CGPoint?
    private var current: CGPoint?
    private var shiftHeld = false
    private var strokeStyle = ShapeStyle()

    func mouseDown(at p: CGPoint, context: ToolContext) {
        guard let doc = context.document, let layer = doc.activeLayer, !layer.isLocked else {
            context.statusMessage?("Layer is locked")
            return
        }
        _ = layer
        start = p
        current = p
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
        strokeStyle = context.settings.shapeStyle
        // The ribbon's size slider drives shapeLineWidth; keep it in sync with
        // the style we captured for this gesture.
        if context.settings.shapeLineWidth > 0 {
            strokeStyle.lineWidth = context.settings.shapeLineWidth
        }
        context.requestRedraw?(nil)
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {
        guard start != nil else { return }
        current = p
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
        context.requestRedraw?(nil)
    }

    func mouseUp(at p: CGPoint, context: ToolContext) {
        guard let s = start, let doc = context.document, let layer = doc.activeLayer else {
            reset()
            return
        }
        current = p
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let rect = normalizedRect(from: s, to: p)
        reset()
        guard rect.width >= 1 || rect.height >= 1 else {
            context.statusMessage?("Nothing drawn")
            context.requestRedraw?(nil)
            return
        }
        guard !layer.isLocked else {
            context.statusMessage?("Layer is locked")
            context.requestRedraw?(nil)
            return
        }
        let padding = max(2, strokeStyle.lineWidth + 2)
        let undoRect = clipToCanvas(rect.insetBy(dx: -padding, dy: -padding), canvasSize: doc.canvasSize)
        guard !undoRect.isNull else { return }
        let pending = context.undoSnapshot(named: kind == .curve ? "Curve" : "Shape",
                                           rects: [undoRect])
        let ctx = layer.raster.bitmapContext
        ctx.saveGState()
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        applySelectionClip(doc.selection, to: ctx)
        ctx.setAlpha(CGFloat(min(1.0, max(0.0, context.settings.opacity))))
        if kind == .line {
            drawLine(into: ctx, from: s, to: p, style: strokeStyle,
                     color: context.settings.primaryColor, scale: 1)
        } else {
            ShapeDraw.draw(kind: kind, rect: rect, style: strokeStyle,
                           color: context.settings.primaryColor,
                           fillColor: context.settings.secondaryColor,
                           into: ctx, scale: 1)
        }
        ctx.restoreGState()
        doc.markChanged()
        context.commit(pending)
        context.statusMessage?(kind.title + " drawn")
        context.requestRedraw?(undoRect)
    }

    func drawOverlay(in ctx: ToolContext, viewContext: CGContext, canvasView: CanvasView) {
        guard let s = start, let c = current else { return }
        let rect = normalizedRect(from: s, to: c)
        let zoom = max(0.001, canvasView.zoomScale)
        viewContext.saveGState()
        viewContext.setAllowsAntialiasing(true)
        viewContext.setAlpha(CGFloat(min(1.0, max(0.0, ctx.settings.opacity))))
        var previewStyle = ctx.settings.shapeStyle
        if ctx.settings.shapeLineWidth > 0 { previewStyle.lineWidth = ctx.settings.shapeLineWidth }
        if kind == .line {
            let color = ctx.settings.primaryColor
            viewContext.setStrokeColor(ShapeDraw.cgColor(color))
            viewContext.setLineWidth(max(0.5, previewStyle.lineWidth / zoom))
            viewContext.setLineCap(.round)
            viewContext.setLineDash(phase: 0, lengths: [])
            viewContext.move(to: s)
            viewContext.addLine(to: c)
            viewContext.strokePath()
        } else {
            ShapeDraw.draw(kind: kind, rect: rect, style: previewStyle,
                           color: ctx.settings.primaryColor,
                           fillColor: ctx.settings.secondaryColor,
                           into: viewContext, scale: zoom)
            // Light bounds marquee so the user sees the shape's extent.
            viewContext.setAlpha(1)
            viewContext.setLineWidth(1 / zoom)
            viewContext.setStrokeColor(NSColor.controlAccentColor.cgColor)
            viewContext.setLineDash(phase: 0, lengths: [4 / zoom, 4 / zoom])
            viewContext.stroke(rect)
        }
        viewContext.restoreGState()
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        shiftHeld = event.modifierFlags.contains(.shift)
        return false
    }

    func cancel(in ctx: ToolContext) {
        reset()
        ctx.requestRedraw?(nil)
    }

    // MARK: Helpers

    private func reset() {
        start = nil
        current = nil
        shiftHeld = false
    }

    /// Drag rect in image coordinates, constrained to a square when Shift is
    /// held (ignored for lines, which use the raw endpoints).
    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        var rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        if kind != .line && shiftHeld && rect.width > 0 && rect.height > 0 {
            let side = max(rect.width, rect.height)
            rect.size = CGSize(width: side, height: side)
            if b.x < a.x { rect.origin.x = a.x - side }
            if b.y < a.y { rect.origin.y = a.y - side }
        }
        return rect
    }

    private func drawLine(into ctx: CGContext, from a: CGPoint, to b: CGPoint,
                          style: ShapeStyle, color: PixelColor, scale: CGFloat) {
        ctx.setStrokeColor(ShapeDraw.cgColor(color))
        ctx.setLineWidth(max(0.5, style.lineWidth / max(scale, 0.0001)))
        ctx.setLineCap(.round)
        if let pattern = style.lineStyle.cgPattern {
            ctx.setLineDash(phase: 0, lengths: pattern.map { $0 / max(scale, 0.0001) })
        } else {
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }
}

// MARK: - Concrete shapes

final class RectangleTool: ShapeTool {
    let rounded: Bool
    init(rounded: Bool = false) { self.rounded = rounded }
    override var kind: ToolKind { rounded ? .roundedRectangle : .rectangle }
}
final class EllipseTool: ShapeTool { override var kind: ToolKind { .ellipse } }
final class TriangleTool: ShapeTool { override var kind: ToolKind { .triangle } }
final class PolygonTool: ShapeTool { override var kind: ToolKind { .polygon } }
final class DiamondTool: ShapeTool { override var kind: ToolKind { .diamond } }
final class ArrowTool: ShapeTool { override var kind: ToolKind { .arrow } }
final class StarTool: ShapeTool { override var kind: ToolKind { .star } }
final class LineTool: ShapeTool { override var kind: ToolKind { .line } }

// MARK: - Curve (drag to draw, then bend with a second drag)

final class CurveTool: Tool {
    var kind: ToolKind { .curve }
    var cursorName: NSCursorName { .crosshair }

    private enum Phase { case initialLine, bend }
    private var phase: Phase = .initialLine
    private var start: CGPoint?
    private var end: CGPoint?
    private var control: CGPoint?
    private var bending = false
    private var strokeStyle = ShapeStyle()

    func mouseDown(at p: CGPoint, context: ToolContext) {
        guard let doc = context.document, let layer = doc.activeLayer, !layer.isLocked else {
            context.statusMessage?("Layer is locked")
            return
        }
        _ = layer
        strokeStyle = context.settings.shapeStyle
        if context.settings.shapeLineWidth > 0 {
            strokeStyle.lineWidth = context.settings.shapeLineWidth
        }
        switch phase {
        case .initialLine:
            start = p
            end = p
        case .bend:
            bending = true
            control = p
        }
        context.requestRedraw?(nil)
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {
        switch phase {
        case .initialLine:
            end = p
        case .bend:
            bending = true
            control = p
        }
        context.requestRedraw?(nil)
    }

    func mouseUp(at p: CGPoint, context: ToolContext) {
        switch phase {
        case .initialLine:
            guard let s = start else { return }
            end = p
            if hypot(p.x - s.x, p.y - s.y) > 1 {
                // Start with a slight bow so the first bend drag is predictable.
                let mid = CGPoint(x: (s.x + p.x) / 2, y: (s.y + p.y) / 2)
                let dx = p.x - s.x, dy = p.y - s.y
                let length = max(1, hypot(dx, dy))
                control = CGPoint(x: mid.x - dy / length * 24, y: mid.y + dx / length * 24)
                phase = .bend
                context.statusMessage?("Curve: drag to bend, release to apply")
            } else {
                start = nil
                end = nil
                context.statusMessage?("Curve: drag to draw a line")
            }
            context.requestRedraw?(nil)
        case .bend:
            guard bending, let doc = context.document, let layer = doc.activeLayer else { return }
            defer {
                bending = false
                phase = .initialLine
                start = nil; end = nil; control = nil
                context.requestRedraw?(nil)
            }
            guard !layer.isLocked else {
                context.statusMessage?("Layer is locked")
                return
            }
            applyCurve(doc: doc, layer: layer, context: context)
        }
    }

    private func applyCurve(doc: Document, layer: Layer, context: ToolContext) {
        guard let s = start, let e = end, let c = control else { return }
        let box = CGRect(x: min(s.x, min(e.x, c.x)), y: min(s.y, min(e.y, c.y)),
                         width: 0, height: 0)
            .union(CGRect(x: max(s.x, max(e.x, c.x)), y: max(s.y, max(e.y, c.y)),
                          width: 0, height: 0))
        let padding = max(3, strokeStyle.lineWidth + 2)
        let undoRect = clipToCanvas(box.insetBy(dx: -padding, dy: -padding),
                                    canvasSize: doc.canvasSize)
        guard !undoRect.isNull else { return }
        let pending = context.undoSnapshot(named: "Curve", rects: [undoRect])
        let ctx = layer.raster.bitmapContext
        ctx.saveGState()
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        applySelectionClip(doc.selection, to: ctx)
        ctx.setAlpha(CGFloat(min(1.0, max(0.0, context.settings.opacity))))
        ctx.setStrokeColor(ShapeDraw.cgColor(context.settings.primaryColor))
        ctx.setLineWidth(max(0.5, strokeStyle.lineWidth))
        ctx.setLineCap(.round)
        if let pattern = strokeStyle.lineStyle.cgPattern {
            ctx.setLineDash(phase: 0, lengths: pattern)
        } else {
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.move(to: s)
        ctx.addQuadCurve(to: e, control: c)
        ctx.strokePath()
        ctx.restoreGState()
        doc.markChanged()
        context.commit(pending)
        context.statusMessage?("Curve applied")
    }

    func drawOverlay(in ctx: ToolContext, viewContext: CGContext, canvasView: CanvasView) {
        guard let s = start, let e = end else { return }
        let zoom = max(0.001, canvasView.zoomScale)
        let color = ctx.settings.primaryColor
        viewContext.saveGState()
        viewContext.setLineWidth(max(0.5, effectiveStyle(ctx).lineWidth / zoom))
        viewContext.setStrokeColor(ShapeDraw.cgColor(color))
        viewContext.setLineCap(.round)
        if phase == .initialLine || control == nil {
            viewContext.move(to: s)
            viewContext.addLine(to: e)
            viewContext.strokePath()
        } else if let c = control {
            let box = CGRect(x: min(s.x, min(e.x, c.x)), y: min(s.y, min(e.y, c.y)),
                             width: 0, height: 0)
                .union(CGRect(x: max(s.x, max(e.x, c.x)), y: max(s.y, max(e.y, c.y)),
                              width: 0, height: 0))
            viewContext.setLineWidth(1 / zoom)
            viewContext.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
            viewContext.setLineDash(phase: 0, lengths: [3 / zoom, 4 / zoom])
            viewContext.stroke(box.insetBy(dx: -2, dy: -2))
            viewContext.setLineDash(phase: 0, lengths: [])
            viewContext.setLineWidth(max(0.5, effectiveStyle(ctx).lineWidth / zoom))
            viewContext.setStrokeColor(ShapeDraw.cgColor(color))
            viewContext.move(to: s)
            viewContext.addQuadCurve(to: e, control: c)
            viewContext.strokePath()
        }
        viewContext.restoreGState()
    }

    private func effectiveStyle(_ ctx: ToolContext) -> ShapeStyle {
        var style = ctx.settings.shapeStyle
        if ctx.settings.shapeLineWidth > 0 { style.lineWidth = ctx.settings.shapeLineWidth }
        return style
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        false
    }

    func cancel(in ctx: ToolContext) {
        phase = .initialLine
        start = nil
        end = nil
        control = nil
        bending = false
        ctx.requestRedraw?(nil)
    }
}
