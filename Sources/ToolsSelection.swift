// SELF-TEST: (selection tools + text tool)
// 1. Rectangular selection (S): drag a box, then drag *inside* it — the pixels
//    lift off and follow the mouse (floating preview); release to drop them,
//    Undo to put them back, Escape to cancel mid-drag. Shift-drag adds to the
//    selection, Control/Option-drag subtracts. A click without a drag clears it.
// 2. Free-form selection (lasso): drag a closed loop; the marching ants follow
//    the mask (the canvas view draws the bounds box). Shift adds, Control/Option
//    subtracts. Arrow keys move the selected pixels (Shift = 10 px); Delete
//    clears them.
// 3. Magic wand: click a flat colour region — the contiguous tolerance-aware
//    region becomes the selection and the status bar reports its size. Shift
//    adds the region, Option (or Control) subtracts it. Panning uses Space-drag
//    or the middle mouse button, so Option is free for subtract.
// 4. Text (T): click on the canvas — an inline editor appears at the click point
//    with the inspector's font family, size, bold and italic. Type; press
//    Cmd+Return to commit, click outside to commit, Escape to cancel. Committed
//    text uses the primary colour, is clipped by an active selection and is a
//    single "Text" undo step with the correct baseline. Switching tools commits
//    the pending text. Locked layers refuse the text tool without crashing.
// 5. Every selection gesture on an empty selection or a locked layer is a
//    no-op, and tiny/zero-size drags never crash.
//
// Selection tools (rect, lasso, magic wand) and the Text tool with its inline
// NSTextView composer.
import AppKit
import CoreGraphics
import CoreText

// MARK: - Modifier helper

/// Shift = add to selection, Option or Control = subtract. Panning lives on
/// Space-drag and the middle mouse button, so Option stays available; Control is
/// accepted too for trackpads/left-handed users.
private func currentSelectionModifiers() -> (add: Bool, subtract: Bool) {
    let flags = NSEvent.modifierFlags
    return (flags.contains(.shift), flags.contains(.option) || flags.contains(.control))
}

// MARK: - Shared marquee drawing

private func strokeMarchingAnts(_ rect: CGRect, in ctx: CGContext, zoom: CGFloat) {
    let scale = max(0.001, zoom)
    let dash: [CGFloat] = [4 / scale, 4 / scale]
    ctx.saveGState()
    ctx.setLineWidth(1 / scale)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineDash(phase: 0, lengths: dash)
    ctx.stroke(rect)
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setLineDash(phase: 4 / scale, lengths: dash)
    ctx.stroke(rect)
    ctx.restoreGState()
}

private func selectionStatus(_ sel: SelectionModel?) -> String {
    guard let sel, !sel.isEmpty else { return "Selection cleared" }
    let w = Int(sel.bounds.width.rounded()), h = Int(sel.bounds.height.rounded())
    return "\(w) × \(h) px selected"
}

// MARK: - Keyboard shortcuts shared by the selection tools

/// Returns true when the key was consumed. Arrow keys nudge the selected pixels
/// (1 px, or 10 px with Shift); Delete clears them; Cmd+C/X/V fall back to the
/// selection operations when the Edit menu is not wired yet.
private func handleSelectionKey(_ event: NSEvent, context: ToolContext) -> Bool {
    guard let doc = context.document, let selection = doc.selection, !selection.isEmpty else {
        return false
    }
    let step = event.modifierFlags.contains(.shift) ? 10 : 1
    let command = event.modifierFlags.contains(.command)
    switch event.keyCode {
    case 123: // left arrow
        if doc.nudgeSelection(dx: -step, dy: 0) {
            context.statusMessage?("Selection moved \(step) px left")
            context.requestRedraw?(nil)
            return true
        }
    case 124: // right arrow
        if doc.nudgeSelection(dx: step, dy: 0) {
            context.statusMessage?("Selection moved \(step) px right")
            context.requestRedraw?(nil)
            return true
        }
    case 125: // down arrow
        if doc.nudgeSelection(dx: 0, dy: step) {
            context.statusMessage?("Selection moved \(step) px down")
            context.requestRedraw?(nil)
            return true
        }
    case 126: // up arrow
        if doc.nudgeSelection(dx: 0, dy: -step) {
            context.statusMessage?("Selection moved \(step) px up")
            context.requestRedraw?(nil)
            return true
        }
    case 51, 117: // delete / forward delete
        if doc.deleteSelection() {
            context.statusMessage?("Selection deleted")
            context.requestRedraw?(nil)
            return true
        }
    case 8: // C
        if command, doc.copySelection() {
            context.statusMessage?("Selection copied")
            return true
        }
    case 7: // X
        if command, doc.cutSelection() {
            context.statusMessage?("Selection cut")
            context.requestRedraw?(nil)
            return true
        }
    case 9: // V
        if command, doc.pasteSelection() {
            context.statusMessage?("Pasted")
            context.requestRedraw?(nil)
            return true
        }
    default:
        break
    }
    return false
}

// MARK: - Rectangular selection

final class RectSelectTool: Tool {
    var kind: ToolKind { .selectRect }
    var cursorName: NSCursorName {
        if moving { return .closedHand }
        return hoveringInside ? .openHand : .crosshair
    }

    private var anchor: CGPoint?
    private var current: CGPoint?
    private var additive = false
    private var subtractive = false

    // Floating move state.
    private var moving = false
    private var moveStart: CGPoint?
    private var moveOffset: CGPoint = .zero
    private var floating: Raster?
    private var movePending: Document.PendingUndo?
    private var moveLayer: Layer?
    private var originalSelection: SelectionModel?
    private var hoveringInside = false

    // MARK: Events

    func mouseDown(at p: CGPoint, context: ToolContext) {
        guard let doc = context.document, let layer = doc.activeLayer else { return }
        let modifiers = currentSelectionModifiers()
        if !modifiers.add && !modifiers.subtract,
           let sel = doc.selection, !sel.isEmpty, sel.contains(p) {
            beginMove(at: p, doc: doc, layer: layer, context: context)
            return
        }
        resetMoveState()
        additive = modifiers.add
        subtractive = modifiers.subtract
        anchor = p
        current = p
        hoveringInside = false
        context.requestRedraw?(nil)
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {
        if moving {
            guard let start = moveStart else { return }
            moveOffset = CGPoint(x: p.x - start.x, y: p.y - start.y)
            context.requestRedraw?(nil)
            return
        }
        guard anchor != nil else { return }
        current = p
        context.requestRedraw?(nil)
    }

    func mouseUp(at p: CGPoint, context: ToolContext) {
        if moving {
            finishMove(context: context)
            return
        }
        guard let a = anchor, let doc = context.document else {
            anchor = nil; current = nil
            return
        }
        current = p
        var rect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y),
                          width: abs(p.x - a.x), height: abs(p.y - a.y)).integral
        anchor = nil
        current = nil
        if rect.width < 1 || rect.height < 1 {
            // Zero-size drag clears the selection (classic Paint behaviour).
            doc.deselect()
            hoveringInside = false
            context.statusMessage?("Selection cleared")
            context.requestRedraw?(nil)
            return
        }
        rect = clipToCanvas(rect, canvasSize: doc.canvasSize)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            context.requestRedraw?(nil)
            return
        }
        let newSelection = SelectionModel(rect: rect)
        let existing = doc.selection
        var result: SelectionModel? = newSelection
        if let existing, !existing.isEmpty {
            if additive {
                result = SelectionMaskBuilder.union(existing, newSelection,
                                                    canvasWidth: doc.width, canvasHeight: doc.height)
            } else if subtractive {
                result = SelectionMaskBuilder.subtracting(newSelection, from: existing,
                                                          canvasWidth: doc.width, canvasHeight: doc.height)
            }
        }
        doc.setSelection(result)
        hoveringInside = false
        context.statusMessage?(selectionStatus(result))
        context.requestRedraw?(nil)
    }

    func mouseMoved(to p: CGPoint, context: ToolContext) {
        // Update the cursor shape without repainting the whole canvas: the
        // canvas view refreshes the cursor right after forwarding this event.
        if let sel = context.document?.selection, !sel.isEmpty {
            hoveringInside = sel.contains(p)
        } else {
            hoveringInside = false
        }
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        handleSelectionKey(event, context: context)
    }

    func drawOverlay(in ctx: ToolContext, viewContext: CGContext, canvasView: CanvasView) {
        let zoom = canvasView.zoomScale
        if moving, let floating, let original = originalSelection {
            let dx = moveOffset.x.rounded(), dy = moveOffset.y.rounded()
            let rect = original.bounds.offsetBy(dx: dx, dy: dy)
            if let image = floating.makeImage() {
                CGImageDrawing.drawUpright(image, in: CGRect(x: rect.minX, y: rect.minY,
                                                            width: rect.width, height: rect.height),
                                           into: viewContext)
            }
            // Ghost of where the pixels came from.
            viewContext.saveGState()
            viewContext.setLineWidth(1 / max(0.001, zoom))
            viewContext.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            viewContext.setLineDash(phase: 0, lengths: [2 / max(0.001, zoom), 4 / max(0.001, zoom)])
            viewContext.stroke(original.bounds)
            viewContext.restoreGState()
            strokeMarchingAnts(rect, in: viewContext, zoom: zoom)
            return
        }
        guard let a = anchor, let c = current else { return }
        let rect = CGRect(x: min(a.x, c.x), y: min(a.y, c.y),
                          width: abs(c.x - a.x), height: abs(c.y - a.y))
        strokeMarchingAnts(rect, in: viewContext, zoom: zoom)
    }

    func cancel(in ctx: ToolContext) {
        if moving {
            if let doc = ctx.document, let pending = movePending {
                for snapshot in pending.snapshots {
                    doc.restoreLayerRegion(snapshot.before, layerID: snapshot.layerID, region: snapshot.region)
                }
                doc.invalidateComposite()
                doc.markChanged()
            }
            resetMoveState()
            ctx.requestRedraw?(nil)
            return
        }
        anchor = nil
        current = nil
        ctx.requestRedraw?(nil)
    }

    // MARK: Floating move

    private func beginMove(at p: CGPoint, doc: Document, layer: Layer, context: ToolContext) {
        guard let selection = doc.selection, !selection.isEmpty else { return }
        guard !layer.isLocked else {
            context.statusMessage?("Layer is locked")
            return
        }
        let canvas = CGRect(origin: .zero, size: doc.canvasSize)
        let pending = doc.beginUndo(named: "Move Selection", rects: [canvas])
        let content = SelectionOps.extract(from: layer.raster, selection: selection)
        SelectionOps.clear(selection, in: layer.raster)
        doc.markChanged()
        movePending = pending
        moveLayer = layer
        originalSelection = selection
        floating = content
        moveStart = p
        moveOffset = .zero
        moving = true
        context.statusMessage?("Drag to move selection, release to drop")
        context.requestRedraw?(nil)
    }

    private func finishMove(context: ToolContext) {
        guard let doc = context.document, let layer = moveLayer,
              let content = floating, let original = originalSelection else {
            resetMoveState()
            return
        }
        let dx = Int(moveOffset.x.rounded()), dy = Int(moveOffset.y.rounded())
        if dx == 0 && dy == 0 {
            // A click inside the selection without a drag: put the pixels back
            // and record no undo step (the selection stays where it was).
            if let doc = context.document, let pending = movePending {
                for snapshot in pending.snapshots {
                    doc.restoreLayerRegion(snapshot.before, layerID: snapshot.layerID, region: snapshot.region)
                }
                doc.invalidateComposite()
                doc.markChanged()
            }
            resetMoveState()
            context.requestRedraw?(nil)
            return
        }
        let destination = original.bounds.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy))
        SelectionOps.composite(content, into: layer.raster, at: destination.origin)
        doc.markChanged()
        let newSelection = SelectionMaskBuilder.shifted(original, dx: dx, dy: dy,
                                                        canvasWidth: doc.width, canvasHeight: doc.height)
        doc.setSelection(newSelection)
        if let pending = movePending {
            doc.commitUndo(pending,
                           selectionBefore: original.bounds,
                           selectionAfter: newSelection?.bounds)
        }
        doc.notifyChange(original.bounds.union(destination))
        context.statusMessage?("Selection moved \(dx), \(dy) px")
        resetMoveState()
        context.requestRedraw?(nil)
    }

    private func resetMoveState() {
        moving = false
        moveStart = nil
        moveOffset = .zero
        floating = nil
        movePending = nil
        moveLayer = nil
        originalSelection = nil
    }
}

// MARK: - Free-form (lasso) selection

final class FreeformSelectTool: Tool {
    var kind: ToolKind { .selectFreeform }
    var cursorName: NSCursorName { .crosshair }

    private var points: [CGPoint] = []
    private var dragging = false
    private var additive = false
    private var subtractive = false

    func mouseDown(at p: CGPoint, context: ToolContext) {
        let modifiers = currentSelectionModifiers()
        additive = modifiers.add
        subtractive = modifiers.subtract
        points = [p]
        dragging = true
        context.requestRedraw?(nil)
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {
        guard dragging else { return }
        if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 1.0 { return }
        points.append(p)
        context.requestRedraw?(nil)
    }

    func mouseUp(at p: CGPoint, context: ToolContext) {
        guard dragging, let doc = context.document else { return }
        dragging = false
        points.append(p)
        defer { points = [] }
        guard points.count >= 3 else {
            doc.deselect()
            context.statusMessage?("Selection cleared")
            context.requestRedraw?(nil)
            return
        }
        let path = SelectionModel.path(from: points)
        let newSelection = SelectionModel(path: path, canvasSize: doc.canvasSize)
        var result: SelectionModel? = newSelection
        if let existing = doc.selection, !existing.isEmpty {
            if additive {
                result = SelectionMaskBuilder.union(existing, newSelection,
                                                    canvasWidth: doc.width, canvasHeight: doc.height)
            } else if subtractive {
                result = SelectionMaskBuilder.subtracting(newSelection, from: existing,
                                                          canvasWidth: doc.width, canvasHeight: doc.height)
            }
        }
        doc.setSelection(result)
        context.statusMessage?(result == nil ? "Selection cleared" : "Free-form selection")
        context.requestRedraw?(nil)
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        handleSelectionKey(event, context: context)
    }

    func drawOverlay(in ctx: ToolContext, viewContext: CGContext, canvasView: CanvasView) {
        guard points.count > 1 else { return }
        let zoom = max(0.001, canvasView.zoomScale)
        viewContext.saveGState()
        viewContext.setLineWidth(1.5 / zoom)
        viewContext.setStrokeColor(NSColor.controlAccentColor.cgColor)
        viewContext.setLineDash(phase: 0, lengths: [5 / zoom, 4 / zoom])
        viewContext.beginPath()
        viewContext.move(to: points[0])
        for p in points.dropFirst() { viewContext.addLine(to: p) }
        viewContext.strokePath()
        // Close the loop visually so the user sees the pending selection area.
        viewContext.setLineDash(phase: 0, lengths: [2 / zoom, 3 / zoom])
        viewContext.move(to: points[points.count - 1])
        viewContext.addLine(to: points[0])
        viewContext.strokePath()
        viewContext.restoreGState()
    }

    func cancel(in ctx: ToolContext) {
        points = []
        dragging = false
        ctx.requestRedraw?(nil)
    }
}

// MARK: - Magic wand (tolerance-based contiguous selection)

final class MagicWandTool: Tool {
    var kind: ToolKind { .magicWand }
    var cursorName: NSCursorName { .crosshair }

    func mouseDown(at p: CGPoint, context: ToolContext) {
        guard let doc = context.document else { return }
        let canvasRect = CGRect(x: 0, y: 0, width: doc.width, height: doc.height)
        guard canvasRect.contains(p) else {
            context.statusMessage?("Magic wand: click inside the canvas")
            return
        }
        guard let composite = doc.compositeImage(),
              let region = MagicWand.region(in: composite, at: p,
                                            tolerance: context.settings.fillTolerance) else {
            context.statusMessage?("Magic wand: nothing to select")
            return
        }
        let modifiers = currentSelectionModifiers()
        let newSelection = region.selection(canvasWidth: doc.width, canvasHeight: doc.height)
        guard let newSelection else {
            context.statusMessage?("Magic wand: nothing to select")
            return
        }
        var result: SelectionModel? = newSelection
        if let existing = doc.selection, !existing.isEmpty {
            if modifiers.add {
                result = SelectionMaskBuilder.union(existing, newSelection,
                                                    canvasWidth: doc.width, canvasHeight: doc.height)
            } else if modifiers.subtract {
                result = SelectionMaskBuilder.subtracting(newSelection, from: existing,
                                                          canvasWidth: doc.width, canvasHeight: doc.height)
            }
        }
        doc.setSelection(result)
        let selectedPixels = result.map { SelectionMaskBuilder.pixelCount(of: $0) } ?? 0
        if let result, !result.isEmpty {
            let w = Int(result.bounds.width.rounded()), h = Int(result.bounds.height.rounded())
            context.statusMessage?("Magic wand: \(w) × \(h) px region, \(selectedPixels) px selected")
        } else {
            context.statusMessage?("Magic wand: selection cleared")
        }
        context.requestRedraw?(nil)
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {}
    func mouseUp(at p: CGPoint, context: ToolContext) {}

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        handleSelectionKey(event, context: context)
    }
}

/// A contiguous tolerance-aware region of the composite, stored as a
/// canvas-sized 0/255 mask (used for Shift/Option combination).
struct WandRegion {
    var bytes: [UInt8]
    var bounds: CGRect
    var pixelCount: Int

    func selection(canvasWidth: Int, canvasHeight: Int) -> SelectionModel? {
        SelectionMaskBuilder.selection(fromCanvasMask: bytes,
                                       canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }
}

enum MagicWand {
    /// Flood-fills the composite from `point` with `tolerance` and returns the
    /// covered region. Uses 4-connectivity and a scanline algorithm so selecting
    /// a full canvas region stays fast.
    static func region(in image: CGImage, at point: CGPoint, tolerance: Int) -> WandRegion? {
        let raster = Raster.from(cgImage: image)
        let width = raster.width, height = raster.height
        let startX = Int(point.x), startY = Int(point.y)
        guard startX >= 0, startY >= 0, startX < width, startY < height else { return nil }
        let target = raster.getPixel(startX, startY)
        var mask = [UInt8](repeating: 0, count: width * height)
        var visited = [Bool](repeating: false, count: width * height)
        var count = 0
        var minX = startX, maxX = startX, minY = startY, maxY = startY

        func matches(_ x: Int, _ y: Int) -> Bool {
            FloodFill.matches(raster.getPixel(x, y), target, tolerance: tolerance)
        }

        var stack: [(Int, Int)] = [(startX, startY)]
        while let seed = stack.popLast() {
            let y = seed.1
            guard !visited[y * width + seed.0], matches(seed.0, y) else { continue }
            var left = seed.0
            while left - 1 >= 0, !visited[y * width + left - 1], matches(left - 1, y) { left -= 1 }
            var right = seed.0
            while right + 1 < width, !visited[y * width + right + 1], matches(right + 1, y) { right += 1 }
            for x in left...right {
                visited[y * width + x] = true
                mask[y * width + x] = 255
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
            for neighborY in [y - 1, y + 1] {
                guard neighborY >= 0, neighborY < height else { continue }
                var inRun = false
                for x in left...right {
                    let ok = !visited[neighborY * width + x] && matches(x, neighborY)
                    if ok && !inRun { stack.append((x, neighborY)); inRun = true }
                    if !ok { inRun = false }
                }
            }
        }
        guard count > 0 else { return nil }
        let bounds = CGRect(x: minX, y: minY,
                            width: maxX - minX + 1, height: maxY - minY + 1)
        return WandRegion(bytes: mask, bounds: bounds, pixelCount: count)
    }
}

// MARK: - Text tool

/// Font resolution and Core Text rasterization shared by the inline editor and
/// the final commit, so what the user sees is what gets painted.
enum TextFonts {
    static func resolvedFont(settings: ToolSettings, scale: CGFloat = 1) -> NSFont {
        let size = max(1, settings.fontSize * scale)
        let base = NSFont(name: settings.fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if settings.bold { traits.insert(.bold) }
        if settings.italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        let system = NSFont.systemFont(ofSize: size)
        let systemDescriptor = system.fontDescriptor.withSymbolicTraits(traits)
        if let font = NSFont(descriptor: systemDescriptor, size: size) {
            return font
        }
        return base
    }
}

enum TextRasterizer {
    static func ctFont(_ font: NSFont) -> CTFont {
        CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
    }

    static func lineHeight(font: NSFont) -> CGFloat {
        let ct = ctFont(font)
        return ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
    }

    static func measure(text: String, font: NSFont) -> CGSize {
        let lines = text.components(separatedBy: "\n")
        let height = max(1, CGFloat(lines.count)) * lineHeight(font: font)
        var width: CGFloat = 1
        for line in lines where !line.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont(font)
            ]
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            width = max(width, lineWidth)
        }
        return CGSize(width: ceil(width) + 6, height: ceil(height) + 4)
    }

    /// Rasterizes multi-line text with its first line's top at `topLeft` (image
    /// coordinates, y down). The baseline is derived from the font ascent, so a
    /// click always produces text at the clicked location.
    static func draw(text: String, font: NSFont, color: NSColor, topLeft: CGPoint, into ctx: CGContext) {
        let ct = ctFont(font)
        let ascent = CTFontGetAscent(ct)
        let height = lineHeight(font: font)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ct,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ]
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let baselineY = topLeft.y + ascent + CGFloat(index) * height
            ctx.saveGState()
            ctx.translateBy(x: topLeft.x, y: baselineY)
            // The bitmap context is already flipped for top-left image space;
            // flip again locally so glyphs stand upright with the baseline here.
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }
}

final class TextTool: Tool {
    var kind: ToolKind { .text }
    var cursorName: NSCursorName { .text }

    private var composer: TextComposer?

    func activate(in ctx: ToolContext) {}

    func mouseDown(at p: CGPoint, context: ToolContext) {
        if composer != nil {
            // A click while editing commits the current text (the click-away
            // that made the canvas first responder also commits; this is the
            // deterministic fallback and also covers click-to-commit when the
            // canvas was not first responder).
            commit(context)
            return
        }
        guard let doc = context.document, let layer = doc.activeLayer, !layer.isLocked else {
            context.statusMessage?("Layer is locked")
            return
        }
        guard let canvas = context.canvasView else { return }
        _ = layer
        let editor = TextComposer(canvas: canvas, originInImage: p, settings: context.settings)
        editor.onCommit = { [weak self] text, origin in
            self?.rasterize(text: text, origin: origin, context: context)
        }
        editor.onFinish = { [weak self] reason in
            guard let self else { return }
            self.composer = nil
            _ = reason
            context.requestRedraw?(nil)
        }
        canvas.addSubview(editor)
        if let window = canvas.window {
            window.makeFirstResponder(editor)
        } else {
            _ = editor.becomeFirstResponder()
        }
        composer = editor
        context.statusMessage?("Type text · Cmd+Return commits · Esc cancels")
    }

    func mouseDragged(to p: CGPoint, context: ToolContext) {}
    func mouseUp(at p: CGPoint, context: ToolContext) {}

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard composer != nil else { return false }
        if event.keyCode == 53 { // Escape cancels without painting.
            cancel(in: context)
            return true
        }
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.contains(.command) { // Cmd+Return commits.
            commit(context)
            return true
        }
        return false
    }

    func commit(_ context: ToolContext) {
        composer?.commitFromKeyboard()
    }

    func deactivate(in ctx: ToolContext) {
        if composer != nil { commit(ctx) }
    }

    func cancel(in ctx: ToolContext) {
        composer?.cancelEditing()
    }

    // MARK: Rasterization

    private func rasterize(text: String, origin: CGPoint, context: ToolContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let doc = context.document,
              let layer = doc.activeLayer, !layer.isLocked else { return }
        let font = TextFonts.resolvedFont(settings: context.settings)
        let size = TextRasterizer.measure(text: text, font: font)
        let rect = clipToCanvas(CGRect(origin: origin, size: size), canvasSize: doc.canvasSize)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return }
        let undoRect = clipToCanvas(rect.insetBy(dx: -4, dy: -4), canvasSize: doc.canvasSize)
        let pending = context.undoSnapshot(named: "Text", rects: [undoRect])
        let ctx = layer.raster.bitmapContext
        ctx.saveGState()
        applySelectionClip(doc.selection, to: ctx)
        ctx.setAlpha(CGFloat(min(1.0, max(0.0, context.settings.opacity))))
        TextRasterizer.draw(text: text, font: font,
                            color: context.settings.primaryColor.nsColor,
                            topLeft: origin, into: ctx)
        ctx.restoreGState()
        doc.markChanged()
        context.commit(pending)
        context.requestRedraw?(undoRect.isNull ? rect : undoRect)
        context.statusMessage?("Text added")
    }
}

/// Floating editor placed over the canvas at the click point. Uses the system
/// text system so selection, IME and undo behave natively; the font size is
/// scaled by the canvas zoom so the editor matches the rasterized result.
final class TextComposer: NSTextView, NSTextViewDelegate {
    enum EndReason { case committed, cancelled, focusLoss }

    var onCommit: ((String, CGPoint) -> Void)?
    var onFinish: ((EndReason) -> Void)?

    private let originInImage: CGPoint
    private var ended = false

    init(canvas: CanvasView, originInImage: CGPoint, settings: ToolSettings) {
        self.originInImage = originInImage
        let zoom = max(0.05, canvas.zoomScale)
        let viewPoint = CGPoint(x: canvas.canvasOrigin.x + originInImage.x * zoom,
                                y: canvas.canvasOrigin.y + originInImage.y * zoom)
        let editorFont = TextFonts.resolvedFont(settings: settings, scale: zoom)
        let lineHeight = max(12, TextRasterizer.lineHeight(font: editorFont))
        let available = max(120, canvas.bounds.width - viewPoint.x - 12)
        let width = min(available, max(180, canvas.bounds.width * 0.55))
        let frame = CGRect(x: viewPoint.x, y: viewPoint.y,
                           width: width, height: max(lineHeight * 3, 48))
        // Build the text system explicitly: `init(frame:textContainer:nil)` does
        // not create a text storage on macOS 13+, which would make typing a
        // silent no-op.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: width,
                                                     height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        self.delegate = self
        self.font = editorFont
        self.textColor = settings.primaryColor.nsColor
        self.backgroundColor = .clear
        self.drawsBackground = false
        self.isRichText = false
        self.importsGraphics = false
        self.insertionPointColor = NSColor.controlAccentColor
        self.isVerticallyResizable = true
        self.isHorizontallyResizable = true
        self.textContainerInset = .zero
        self.textContainer?.lineFragmentPadding = 0
        self.string = ""
        self.typingAttributes = [
            .font: editorFont,
            .foregroundColor: settings.primaryColor.nsColor
        ]
        self.wantsLayer = true
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        self.layer?.cornerRadius = 2
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("TextComposer is programmatic") }

    // MARK: Commit / cancel

    func commitFromKeyboard() {
        finish(reason: .committed)
    }

    func cancelEditing() {
        finish(reason: .cancelled)
    }

    private func finish(reason: EndReason) {
        guard !ended else { return }
        ended = true
        let text = string
        removeFromSuperview()
        onFinish?(reason)
        if reason != .cancelled {
            onCommit?(text, originInImage)
        }
        onFinish = nil
        onCommit = nil
    }

    // MARK: NSTextView hooks

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.contains(.command) { // Cmd+Return
            finish(reason: .committed)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        finish(reason: .cancelled)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned && !ended {
            // Focus loss commits (click-away). Deferred so we never tear the
            // responder chain apart from inside its own callback.
            DispatchQueue.main.async { [weak self] in
                self?.finish(reason: .focusLoss)
            }
        }
        return resigned
    }

    func textDidEndEditing(_ notification: Notification) {
        if !ended {
            DispatchQueue.main.async { [weak self] in
                self?.finish(reason: .focusLoss)
            }
        }
    }
}

// MARK: - SelectionModel masked init

extension SelectionModel {
    /// Builds a masked selection directly from a canvas-sized alpha mask.
    convenience init(maskBytes: [UInt8], canvasWidth: Int, canvasHeight: Int, bounds: CGRect) {
        self.init(rect: bounds)
        self.installMask(bytes: maskBytes, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }
}
