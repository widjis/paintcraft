// SELF-TEST: (freehand tools)
// 1. Pencil (P): drag slowly and quickly across the canvas; the line must stay
//    continuous (no gaps on fast drags) and the ends round. Zoom to 800% to see
//    the antialiased edges.
// 2. Brush (B): draw overlapping scribbles. The stroke must not get darker where
//    it crosses itself or where consecutive dabs overlap (union coverage, not
//    additive alpha). Change brush softness in Settings to see the falloff.
// 3. Eraser (E): erase over existing paint. Hard edge, no soft fringe. With
//    "erase to transparent" on (default) the checkerboard shows through; with it
//    off the eraser paints the secondary color.
// 4. Airbrush (A): click and hold still — paint density builds up over time. The
//    density stops when the mouse is released or Escape is pressed, and no timer
//    keeps running afterwards (switch tools and hold still to confirm).
// 5. Fill (F): click a region, then undo/redo. Fill is clipped by rectangular
//    and free-form selections. Tolerance in Settings widens the color match.
// 6. Eyedropper (I): click a painted pixel; the primary swatch follows the
//    displayed color (including semi-transparent layers).
// 7. Locked layer: drawing, filling and the airbrush must not crash; a status
//    message reads "Layer is locked".
//
// Freehand painting tools: pencil, brush, eraser, airbrush, fill, eyedropper and
// magnifier. Strokes are accumulated in a transparent scratch buffer, then
// composited once per update over a restored copy of the pre-stroke pixels. That
// keeps dabs from building alpha where they overlap and makes the live preview
// pixel-identical to the final committed stroke.
import AppKit
import CoreGraphics

// MARK: - Shared drawing helpers

/// Rasterizes an antialiased brush dab at a point. Shared by pencil, brush,
/// eraser and airbrush.
enum BrushRenderer {
    /// Draws one soft/hard round dab. Colors are given unpremultiplied; Core
    /// Graphics premultiplies them for the premultiplied-alpha bitmap context.
    static func makeGradientBrushDab(into ctx: CGContext, at p: CGPoint, radius: CGFloat,
                                     color: PixelColor, softness: Double) {
        let r = max(0.5, radius)
        guard color.a > 0 else { return }
        let alpha = CGFloat(color.a) / 255.0
        let base = CGColor(srgbRed: CGFloat(color.r) / 255.0,
                           green: CGFloat(color.g) / 255.0,
                           blue: CGFloat(color.b) / 255.0,
                           alpha: alpha)
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        let soft = min(1.0, max(0.0, softness))
        if soft <= 0.02 {
            ctx.setFillColor(base)
            ctx.fillEllipse(in: rect)
            return
        }
        // Radial gradient: solid core, then a smooth falloff to transparent.
        let solid = max(0.02, (1.0 - soft) * 0.9)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let clear = base.copy(alpha: 0) ?? base
        guard let gradient = CGGradient(colorsSpace: colorSpace,
                                        colors: [base, clear] as CFArray,
                                        locations: [solid, 1.0]) else {
            ctx.setFillColor(base)
            ctx.fillEllipse(in: rect)
            return
        }
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.drawRadialGradient(gradient,
                               startCenter: p, startRadius: 0,
                               endCenter: p, endRadius: r,
                               options: [.drawsBeforeStartLocation])
        ctx.restoreGState()
    }

    /// Draws a line of dabs between two points. Kept for the demo/document
    /// generator and for any code that paints straight onto a raster context.
    /// `spacing` is a fraction of the dab diameter.
    static func strokeLine(into ctx: CGContext, from a: CGPoint, to b: CGPoint,
                           radius: CGFloat, spacing: CGFloat,
                           color: PixelColor, softness: Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let distance = sqrt(dx * dx + dy * dy)
        let step = max(0.5, max(radius, 0.5) * 2 * max(0.01, spacing))
        let count = max(1, Int((distance / step).rounded(.up)))
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            let p = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
            makeGradientBrushDab(into: ctx, at: p, radius: radius, color: color, softness: softness)
        }
    }
}

/// Deterministic pseudo-random generator used by the airbrush so repeated runs
/// produce identical spray patterns (useful for the headless self-test).
private struct StrokeRandom {
    private var state: UInt64
    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) { state = seed }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / 9_007_199_254_740_992.0
    }
}

/// Base class implementing the stroke lifecycle shared by freehand tools.
///
/// The active dabs are collected in `scratch` (a transparent canvas-sized
/// raster). Each update restores the affected pixels from `base` (the canvas as
/// it looked when the stroke began) and re-composites the accumulated scratch
/// clipped to the newly touched region. Overlapping dabs therefore combine as a
/// coverage union instead of stacking alpha, and the on-screen stroke is exactly
/// what gets committed.
class StrokeTool: Tool {
    var kind: ToolKind { .pencil }
    var cursorName: NSCursorName { .crosshair }

    // MARK: Subclass configuration

    func brushColor(_ ctx: ToolContext, alternate: Bool) -> PixelColor { ctx.settings.primaryColor }
    func brushRadius(_ ctx: ToolContext) -> CGFloat { max(0.5, ctx.settings.strokeWidth / 2) }
    func brushSoftness(_ ctx: ToolContext) -> Double { ctx.settings.brushSoftness }
    func brushSpacing(_ ctx: ToolContext) -> CGFloat { ctx.settings.brushSpacing }
    func toolName() -> String { kind.title }
    func erasesToTransparent(_ ctx: ToolContext) -> Bool { false }
    /// Airbrush builds density as dabs accumulate; everything else unions
    /// coverage so a stroke cannot darken itself.
    func accumulatesDensity(_ ctx: ToolContext) -> Bool { false }
    /// Color of a single dab (airbrush lowers alpha to spray).
    func dabColor(_ ctx: ToolContext) -> PixelColor {
        erasesToTransparent(ctx) ? PixelColor(r: 255, g: 255, b: 255, a: 255)
                                 : brushColor(ctx, alternate: false)
    }
    /// Draw a brush-size ring under the cursor.
    var showsBrushPreview: Bool { false }

    // MARK: Stroke state

    private(set) var isDrawing = false
    private var contextRef: ToolContext?
    private var layerRef: Layer?
    private var base: Raster?
    private var scratch: Raster?
    private var pendingUndo: Document.PendingUndo?
    private var rawLast: CGPoint?
    private var quadMid: CGPoint?
    private var hasDabs = false
    private var pendingFlush: CGRect = .null
    private var strokeBounds: CGRect = .null
    private var hoverPoint: CGPoint?
    private var airbrushPoint: CGPoint?
    private var timer: Timer?
    private var random = StrokeRandom()

    deinit {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Tool lifecycle

    func mouseDown(at p: CGPoint, context: ToolContext) {
        guard !isDrawing else { return }
        guard let doc = context.document, let layer = doc.activeLayer, !layer.isLocked else {
            context.statusMessage?("Layer is locked")
            return
        }
        isDrawing = true
        contextRef = context
        layerRef = layer
        let width = max(1, doc.width), height = max(1, doc.height)
        base = layer.raster.snapshot()
        scratch = Raster(width: width, height: height)
        pendingFlush = .null
        strokeBounds = .null
        hasDabs = false
        rawLast = p
        quadMid = p
        airbrushPoint = p
        random = StrokeRandom(seed: 0x9E37_79B9_7F4A_7C15 ^ UInt64(abs(Int(p.x * 31 + p.y * 17)) + 1))
        pendingUndo = context.undoSnapshot(named: toolName(),
                                           rects: [CGRect(x: 0, y: 0, width: width, height: height)])
        addDabs(at: [p], context: context)
        flush(context: context)
        if accumulatesDensity(context) {
            startAirbrushTimer(context: context)
        }
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {
        guard isDrawing else { return }
        hoverPoint = p
        appendSmoothedSegment(to: p, final: false, context: context)
        airbrushPoint = p
        flush(context: context)
    }

    func mouseUp(at p: CGPoint, context: ToolContext) {
        guard isDrawing else { return }
        stopAirbrushTimer()
        appendSmoothedSegment(to: p, final: true, context: context)
        flush(context: context)
        finishStroke(context: context)
    }

    func mouseMoved(to p: CGPoint, context: ToolContext) {
        guard showsBrushPreview else { return }
        let radius = brushRadius(context)
        let old = hoverPoint
        hoverPoint = p
        if let old {
            context.requestRedraw?(CGRect(x: old.x - radius - 2, y: old.y - radius - 2,
                                          width: radius * 2 + 4, height: radius * 2 + 4))
        }
        context.requestRedraw?(CGRect(x: p.x - radius - 2, y: p.y - radius - 2,
                                      width: radius * 2 + 4, height: radius * 2 + 4))
    }

    func drawOverlay(in ctx: ToolContext, viewContext: CGContext, canvasView: CanvasView) {
        guard showsBrushPreview, let p = hoverPoint else { return }
        let radius = max(1, brushRadius(ctx))
        let zoom = max(0.001, canvasView.zoomScale)
        let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        viewContext.saveGState()
        viewContext.setLineWidth(1.0 / zoom)
        viewContext.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        viewContext.strokeEllipse(in: rect)
        viewContext.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        viewContext.strokeEllipse(in: rect.insetBy(dx: 1.0 / zoom, dy: 1.0 / zoom))
        viewContext.restoreGState()
    }

    func activate(in ctx: ToolContext) {
        hoverPoint = nil
    }

    func deactivate(in ctx: ToolContext) {
        if isDrawing { cancel(in: ctx) }
        stopAirbrushTimer()
        hoverPoint = nil
    }

    func cancel(in ctx: ToolContext) {
        stopAirbrushTimer()
        if let layer = layerRef, let base {
            // Restore the pre-stroke pixels exactly; no undo item is recorded.
            memcpy(layer.raster.data, base.data, min(layer.raster.stride * layer.raster.height,
                                                    base.stride * base.height))
            ctx.document?.invalidateComposite()
            ctx.document?.markChanged()
        }
        resetStrokeState()
        ctx.requestRedraw?(nil)
    }

    // MARK: Dabs & smoothing

    private func resetStrokeState() {
        isDrawing = false
        contextRef = nil
        layerRef = nil
        base = nil
        scratch = nil
        pendingUndo = nil
        rawLast = nil
        quadMid = nil
        hasDabs = false
        pendingFlush = .null
        strokeBounds = .null
        airbrushPoint = nil
    }

    /// Mid-points between raw input samples are used as spline anchors, so the
    /// rendered stroke is a C1-continuous chain of quadratic curves ("incremental
    /// smoothing"). Only the newly generated dabs are rasterized per event.
    private func appendSmoothedSegment(to p: CGPoint, final: Bool, context: ToolContext) {
        guard let last = rawLast, let mid = quadMid else { return }
        let radius = brushRadius(context)
        let spacing = max(0.01, brushSpacing(context))
        let step = max(0.5, radius * 2 * spacing)
        var dabs: [CGPoint]
        if final {
            dabs = StrokeTool.sampleQuadratic(from: mid, control: last, to: p, step: step)
            rawLast = p
        } else {
            let end = CGPoint(x: (last.x + p.x) / 2, y: (last.y + p.y) / 2)
            dabs = StrokeTool.sampleQuadratic(from: mid, control: last, to: end, step: step)
            quadMid = end
            rawLast = p
        }
        if dabs.count > 1 { dabs.removeFirst() } // start already covered by last event
        addDabs(at: dabs, context: context)
    }

    private static func sampleQuadratic(from a: CGPoint, control c: CGPoint,
                                        to b: CGPoint, step: CGFloat) -> [CGPoint] {
        let approx = hypot(a.x - c.x, a.y - c.y) + hypot(c.x - b.x, c.y - b.y)
        let count = max(1, Int((approx / max(step, 0.4)).rounded(.up)))
        var points: [CGPoint] = []
        points.reserveCapacity(count + 1)
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            let mt = 1 - t
            points.append(CGPoint(x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
                                  y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y))
        }
        return points
    }

    private func addDabs(at points: [CGPoint], context: ToolContext) {
        guard let scratch else { return }
        let radius = brushRadius(context)
        let color = dabColor(context)
        let softness = brushSoftness(context)
        let erasing = erasesToTransparent(context)
        guard erasing || color.a > 0 else { return }
        let blending: CGBlendMode = accumulatesDensity(context) ? .normal : .lighten
        let ctx = scratch.bitmapContext
        ctx.saveGState()
        ctx.setBlendMode(blending)
        for p in points {
            BrushRenderer.makeGradientBrushDab(into: ctx, at: p, radius: radius,
                                               color: color, softness: softness)
            let dabRect = CGRect(x: p.x - radius - 1, y: p.y - radius - 1,
                                 width: radius * 2 + 2, height: radius * 2 + 2)
            pendingFlush = pendingFlush.isNull ? dabRect : pendingFlush.union(dabRect)
        }
        ctx.restoreGState()
        hasDabs = hasDabs || !points.isEmpty
    }

    /// Composites the accumulated scratch stroke onto the layer, clipped to the
    /// region touched since the previous update, and restores that region from
    /// the pre-stroke snapshot first (so repeated updates never double-paint).
    private func flush(context: ToolContext) {
        guard let layer = layerRef, let base, let scratch, !pendingFlush.isNull else { return }
        let canvas = CGRect(origin: .zero, size: context.canvasSize)
        let region = pendingFlush.integral.intersection(canvas)
        pendingFlush = .null
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return }
        strokeBounds = strokeBounds.isNull ? region : strokeBounds.union(region)

        // 1. Restore the pre-stroke pixels in the affected region.
        restoreRegion(of: layer.raster, from: base, region: region)

        // 2. Composite the scratch stroke over it.
        guard let scratchImage = scratch.makeImage() else { return }
        let ctx = layer.raster.bitmapContext
        ctx.saveGState()
        ctx.clip(to: region)
        applySelectionClip(context.document?.selection, to: ctx)
        ctx.setAlpha(CGFloat(min(1.0, max(0.0, context.settings.opacity))))
        if erasesToTransparent(context) {
            ctx.setBlendMode(.destinationOut)
            CGImageDrawing.drawUpright(scratchImage, in: scratch.bounds, into: ctx)
        } else if hasDabs {
            ctx.setBlendMode(.normal)
            CGImageDrawing.drawUpright(scratchImage, in: scratch.bounds, into: ctx)
        }
        ctx.restoreGState()

        context.document?.invalidateComposite()
        context.document?.markChanged()
        context.requestRedraw?(region)
    }

    private func restoreRegion(of raster: Raster, from snapshot: Raster, region: CGRect) {
        let x0 = max(0, Int(region.minX))
        let y0 = max(0, Int(region.minY))
        let x1 = min(raster.width, Int(region.maxX))
        let y1 = min(raster.height, Int(region.maxY))
        guard x0 < x1, y0 < y1 else { return }
        let bytes = (x1 - x0) * PixelFormat.bytesPerPixel
        for y in y0..<y1 {
            let offset = y * raster.stride + x0 * PixelFormat.bytesPerPixel
            memcpy(raster.data + offset, snapshot.data + offset, bytes)
        }
    }

    private func finishStroke(context: ToolContext) {
        let hadContent = !strokeBounds.isNull && hasDabs
        if hadContent, let pending = pendingUndo {
            context.commit(pending)
        }
        let bounds = strokeBounds
        resetStrokeState()
        context.requestRedraw?(bounds.isNull ? nil : bounds)
    }

    // MARK: Airbrush timer

    private func startAirbrushTimer(context: ToolContext) {
        stopAirbrushTimer()
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self, let ctx = self.contextRef, self.isDrawing else { return }
            self.airbrushTick(context: ctx)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAirbrushTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func airbrushTick(context: ToolContext) {
        guard isDrawing, contextRef != nil,
              let doc = context.document,
              let layer = layerRef, doc.layers.contains(where: { $0 === layer }),
              !layer.isLocked, let p = airbrushPoint else {
            stopAirbrushTimer()
            return
        }
        let radius = brushRadius(context)
        let density = min(1.0, max(0.02, context.settings.airbrushDensity))
        let dabRadius = max(1, radius * 0.28)
        let spread = max(0, radius - dabRadius)
        let spray = dabColor(context)
        let alpha = UInt8(clamping: Int((20.0 + 120.0 * density).rounded()))
        let color = PixelColor(r: spray.r, g: spray.g, b: spray.b,
                               a: UInt8(clamping: Int(Double(spray.a) * Double(alpha) / 255.0)))
        let count = max(1, Int((6.0 + 26.0 * density).rounded()))
        guard let scratch else { return }
        let ctx = scratch.bitmapContext
        ctx.saveGState()
        ctx.setBlendMode(.normal)
        for _ in 0..<count {
            let angle = random.next() * 2 * Double.pi
            let distance = sqrt(random.next()) * Double(spread)
            let q = CGPoint(x: p.x + CGFloat(cos(angle) * distance),
                            y: p.y + CGFloat(sin(angle) * distance))
            BrushRenderer.makeGradientBrushDab(into: ctx, at: q, radius: dabRadius,
                                               color: color, softness: 0.95)
        }
        ctx.restoreGState()
        let dabRect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        pendingFlush = pendingFlush.isNull ? dabRect : pendingFlush.union(dabRect)
        hasDabs = true
        flush(context: context)
    }
}

// MARK: - Pencil

final class PencilTool: StrokeTool {
    override var kind: ToolKind { .pencil }
    override var cursorName: NSCursorName { .crosshair }
    override func brushRadius(_ ctx: ToolContext) -> CGFloat { max(0.5, ctx.settings.strokeWidth / 2) }
    override func brushSoftness(_ ctx: ToolContext) -> Double { 0 }
    override func brushSpacing(_ ctx: ToolContext) -> CGFloat {
        min(0.2, max(0.02, ctx.settings.brushSpacing))
    }
    override func toolName() -> String { "Pencil" }
}

// MARK: - Brush

final class BrushTool: StrokeTool {
    override var kind: ToolKind { .brush }
    override var cursorName: NSCursorName { .brush }
    override func brushRadius(_ ctx: ToolContext) -> CGFloat { max(1, ctx.settings.strokeWidth / 2) }
    override func brushSoftness(_ ctx: ToolContext) -> Double { ctx.settings.brushSoftness }
    override func brushSpacing(_ ctx: ToolContext) -> CGFloat {
        min(0.5, max(0.02, ctx.settings.brushSpacing))
    }
    override func toolName() -> String { "Brush" }
    override var showsBrushPreview: Bool { true }
}

// MARK: - Eraser

final class EraserTool: StrokeTool {
    override var kind: ToolKind { .eraser }
    override var cursorName: NSCursorName { .eraser }
    override func brushRadius(_ ctx: ToolContext) -> CGFloat { max(1, ctx.settings.strokeWidth / 2) }
    override func brushSoftness(_ ctx: ToolContext) -> Double { 0 }
    override func brushSpacing(_ ctx: ToolContext) -> CGFloat {
        min(0.5, max(0.02, ctx.settings.brushSpacing))
    }
    override func toolName() -> String { "Eraser" }
    override func erasesToTransparent(_ ctx: ToolContext) -> Bool { ctx.settings.eraserRestore }
    override func brushColor(_ ctx: ToolContext, alternate: Bool) -> PixelColor {
        ctx.settings.eraserRestore ? .clear : ctx.settings.secondaryColor
    }
    override var showsBrushPreview: Bool { true }
}

// MARK: - Airbrush

final class AirbrushTool: StrokeTool {
    override var kind: ToolKind { .airbrush }
    override var cursorName: NSCursorName { .airbrush }
    override func brushRadius(_ ctx: ToolContext) -> CGFloat { max(2, ctx.settings.airbrushSize / 2) }
    override func brushSoftness(_ ctx: ToolContext) -> Double { 1.0 }
    override func brushSpacing(_ ctx: ToolContext) -> CGFloat { 0.04 }
    override func toolName() -> String { "Airbrush" }
    override func accumulatesDensity(_ ctx: ToolContext) -> Bool { true }
    override func dabColor(_ ctx: ToolContext) -> PixelColor {
        let density = min(1.0, max(0.02, ctx.settings.airbrushDensity))
        let alpha = UInt8(clamping: Int((24.0 + 120.0 * density).rounded()))
        let c = ctx.settings.primaryColor
        return PixelColor(r: c.r, g: c.g, b: c.b,
                          a: UInt8(clamping: Int(Double(c.a) * Double(alpha) / 255.0)))
    }
    override var showsBrushPreview: Bool { true }
}

// MARK: - Fill (scanline flood fill, Paint-compatible)

final class FillTool: Tool {
    var kind: ToolKind { .fill }
    var cursorName: NSCursorName { .crosshair }

    func mouseDown(at p: CGPoint, context: ToolContext) {
        guard let doc = context.document, let layer = doc.activeLayer else { return }
        guard !layer.isLocked else {
            context.statusMessage?("Layer is locked")
            return
        }
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < layer.raster.width, y < layer.raster.height else { return }
        let selection = doc.selection
        if let sel = selection, !sel.isEmpty,
           !sel.contains(CGPoint(x: p.x, y: p.y)) {
            context.statusMessage?("Click inside the selection to fill")
            return
        }
        let target = layer.raster.getPixel(x, y)
        let fill = context.settings.primaryColor
        let tolerance = context.settings.fillTolerance
        if target == fill && tolerance == 0 { return }

        let region = context.editableRegion()
        let pending = context.undoSnapshot(named: "Fill", rects: [region])
        if context.settings.fillContiguous {
            FloodFill.fill(from: p, in: layer.raster, target: target, replacement: fill,
                           tolerance: tolerance, clip: region, selection: selection)
        } else {
            FloodFill.replaceGlobal(in: layer.raster, target: target, replacement: fill,
                                    tolerance: tolerance, clip: region, selection: selection)
        }
        doc.markChanged()
        context.commit(pending)
        context.requestRedraw?(region)
        context.statusMessage?(context.settings.fillContiguous ? "Filled area" : "Replaced color")
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {}
    func mouseUp(at p: CGPoint, context: ToolContext) {}
}

/// Fast scanline flood fill + global color replacement with tolerance and an
/// optional selection restriction (free-form selections fill only the covered
/// pixels and act as barriers to the flood).
enum FloodFill {
    static func matches(_ a: PixelColor, _ b: PixelColor, tolerance: Int) -> Bool {
        if tolerance <= 0 { return a == b }
        let t = tolerance
        return abs(Int(a.r) - Int(b.r)) <= t &&
               abs(Int(a.g) - Int(b.g)) <= t &&
               abs(Int(a.b) - Int(b.b)) <= t &&
               abs(Int(a.a) - Int(b.a)) <= t
    }

    static func fill(from start: CGPoint, in raster: Raster, target: PixelColor,
                     replacement: PixelColor, tolerance: Int, clip: CGRect,
                     selection: SelectionModel? = nil) {
        let width = raster.width, height = raster.height
        let bounds = clip.integral.intersection(raster.bounds)
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        let minX = Int(bounds.minX), minY = Int(bounds.minY)
        let maxX = Int(bounds.maxX), maxY = Int(bounds.maxY)
        var visited = [Bool](repeating: false, count: width * height)
        let premultiplied = replacement.premultiplied
        let mask = (selection?.isEmpty == false) ? selection : nil

        func allowed(_ x: Int, _ y: Int) -> Bool {
            guard x >= minX, x < maxX, y >= minY, y < maxY else { return false }
            if let mask {
                return mask.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
            }
            return true
        }
        func matchesTarget(_ x: Int, _ y: Int) -> Bool {
            allowed(x, y) && matches(raster.getPixel(x, y), target, tolerance: tolerance)
        }

        let startX = Int(start.x), startY = Int(start.y)
        guard startX >= 0, startY >= 0, startX < width, startY < height,
              matchesTarget(startX, startY) else { return }

        var stack: [(Int, Int)] = [(startX, startY)]
        while let seed = stack.popLast() {
            let y = seed.1
            guard !visited[y * width + seed.0], matchesTarget(seed.0, y) else { continue }
            // Expand the run around the seed.
            var left = seed.0
            while left - 1 >= minX, !visited[y * width + left - 1], matchesTarget(left - 1, y) {
                left -= 1
            }
            var right = seed.0
            while right + 1 < maxX, !visited[y * width + right + 1], matchesTarget(right + 1, y) {
                right += 1
            }
            for x in left...right {
                visited[y * width + x] = true
                raster.setPixelPremultiplied(x, y, premultiplied)
            }
            // Push the runs of matching pixels directly above and below.
            for neighborY in [y - 1, y + 1] {
                guard neighborY >= minY, neighborY < maxY else { continue }
                var inRun = false
                for x in left...right {
                    let ok = !visited[neighborY * width + x] && matchesTarget(x, neighborY)
                    if ok && !inRun { stack.append((x, neighborY)); inRun = true }
                    if !ok { inRun = false }
                }
            }
        }
    }

    static func replaceGlobal(in raster: Raster, target: PixelColor, replacement: PixelColor,
                              tolerance: Int, clip: CGRect,
                              selection: SelectionModel? = nil) {
        let bounds = clip.integral.intersection(raster.bounds)
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        let premultiplied = replacement.premultiplied
        let mask = (selection?.isEmpty == false) ? selection : nil
        let minX = Int(bounds.minX), minY = Int(bounds.minY)
        let maxX = Int(bounds.maxX), maxY = Int(bounds.maxY)
        for y in minY..<maxY {
            for x in minX..<maxX {
                if let mask, !mask.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    continue
                }
                if matches(raster.getPixel(x, y), target, tolerance: tolerance) {
                    raster.setPixelPremultiplied(x, y, premultiplied)
                }
            }
        }
    }
}

// MARK: - Eyedropper

final class EyedropperTool: Tool {
    var kind: ToolKind { .eyedropper }
    var cursorName: NSCursorName { .eyedropper }

    /// Decoding the composite once per gesture keeps dragging snappy.
    private var compositeRaster: Raster?

    func mouseDown(at p: CGPoint, context: ToolContext) {
        compositeRaster = context.document?.compositeImage().map { Raster.from(cgImage: $0) }
        sample(at: p, context: context)
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {
        sample(at: p, context: context)
    }

    func mouseUp(at p: CGPoint, context: ToolContext) {
        sample(at: p, context: context)
        compositeRaster = nil
    }

    func cancel(in ctx: ToolContext) {
        compositeRaster = nil
    }

    private func sample(at p: CGPoint, context: ToolContext) {
        guard let doc = context.document else { return }
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < doc.width, y < doc.height else { return }
        // Sample the flattened composite: that is the color the user sees, even
        // for semi-transparent layers and layer blend modes.
        var color: PixelColor = .clear
        if let raster = compositeRaster {
            color = raster.getPixel(x, y)
        } else if let composite = doc.compositeImage() {
            color = Raster.from(cgImage: composite).getPixel(x, y)
        }
        if color.a == 0, let layer = doc.activeLayer {
            color = layer.raster.getPixel(x, y)
        }
        color.a = 255
        context.setPrimaryColor?(color)
        context.statusMessage?("Picked \(color.hexString)")
    }
}

// MARK: - Magnifier

final class MagnifierTool: Tool {
    var kind: ToolKind { .magnifier }
    var cursorName: NSCursorName { .magnifier }

    func mouseDown(at p: CGPoint, context: ToolContext) {
        guard let canvas = context.canvasView else { return }
        // Shift-click zooms out; plain click zooms in (Option is reserved for
        // panning by the canvas).
        if NSEvent.modifierFlags.contains(.shift) {
            canvas.zoomOut()
        } else {
            canvas.zoomIn()
        }
        context.statusMessage?("Zoom \(Int(canvas.zoomScale * 100))%")
    }
    func mouseDragged(to p: CGPoint, context: ToolContext) {}
    func mouseUp(at p: CGPoint, context: ToolContext) {}
}
