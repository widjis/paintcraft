// SELF-TEST: (selection operations; see also `--selftest` in SelfTest.swift)
// 1. Open PaintCraft, choose the Rectangular selection tool (S), drag a box over
//    some pixels, press Cmd+C, then Cmd+V. A copy of the selected pixels appears
//    at the selection origin and becomes the new selection; Undo removes it.
// 2. Cmd+X cuts the selection: the area becomes transparent (checkerboard) and
//    the content lands on the pasteboard; Undo restores the pixels.
// 3. Press Delete or Backspace with an active selection: the selected pixels are
//    cleared to transparent, undoable as "Delete".
// 4. With a selection active choose Shift+arrow keys: the selected pixels move
//    10 px per press (1 px without Shift) and the marquee follows; each press is
//    a separate undo step. Dragging inside a selection with the Rect tool moves
//    the pixels with a floating preview.
// 5. All operations are no-ops (and never crash) when there is no selection or
//    the active layer is locked.
//
// Selection clipboard + pixel-moving operations. The Lead wires these from the
// Edit menu:
//   SelectionOps.cutSelection(in: canvasDocument)   // or canvasDocument.cutSelection()
//   SelectionOps.copySelection(in: canvasDocument)
//   SelectionOps.pasteSelection(in: canvasDocument)
//   SelectionOps.deleteSelection(in: canvasDocument)
//   SelectionOps.moveSelection(in: canvasDocument, dx: 10, dy: 0)
//   SelectionOps.nudgeSelection(in: canvasDocument, dx: 1, dy: 0)
// Each returns `true` when the document changed so a status message can be shown.

import AppKit
import CoreGraphics
import ImageIO

// MARK: - Selection clipping helper

/// Clips `ctx` to the given selection. Rectangular selections use a fast rect
/// clip; free-form selections clip through the selection's alpha mask so paint
/// never leaks outside a lasso.
func applySelectionClip(_ selection: SelectionModel?, to ctx: CGContext) {
    guard let sel = selection, !sel.isEmpty else { return }
    if let mask = sel.mask {
        ctx.clip(to: sel.bounds, mask: mask)
    } else {
        ctx.clip(to: sel.bounds)
    }
}

/// Integrally clips a rect to a canvas rect; returns `.null` when empty.
func clipToCanvas(_ rect: CGRect, canvasSize: CGSize) -> CGRect {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return .null }
    return rect.intersection(CGRect(origin: .zero, size: canvasSize)).integral
}

// MARK: - Selection clipboard

/// Reads and writes selection pixels through the system pasteboard. PNG is
/// preferred because it round-trips alpha exactly and is readable by Preview,
/// Figma, Safari and friends (`public.png`).
enum SelectionClipboard {
    static func write(_ raster: Raster) -> Bool {
        guard let image = raster.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setData(data, forType: .png)
    }

    static func read() -> Raster? {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return Raster.from(cgImage: image)
        }
        // Fall back to AppKit for pasteboard types we did not anticipate
        // (e.g. PDF or promised images from other apps).
        guard let objects = pb.readObjects(forClasses: [NSImage.self], options: nil),
              let image = objects.first as? NSImage else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return Raster.from(cgImage: cg)
    }
}

// MARK: - Selection mask algebra

/// Converts selections to canvas-sized 0/255 masks and back. Used for the magic
/// wand's Shift (union) and Option/Control (subtract) modes and for moving a
/// masked selection. Everything is expressed in top-left image coordinates.
enum SelectionMaskBuilder {
    static func canvasMask(for selection: SelectionModel, canvasWidth: Int, canvasHeight: Int) -> [UInt8] {
        let count = max(0, canvasWidth * canvasHeight)
        var bytes = [UInt8](repeating: 0, count: count)
        guard count > 0, !selection.isEmpty else { return bytes }
        let b = selection.bounds.integral
        let x0 = max(0, Int(b.minX)), y0 = max(0, Int(b.minY))
        let x1 = min(canvasWidth, Int(b.maxX)), y1 = min(canvasHeight, Int(b.maxY))
        guard x0 < x1, y0 < y1 else { return bytes }
        if selection.mask != nil {
            for y in y0..<y1 {
                let row = y * canvasWidth
                for x in x0..<x1 {
                    if selection.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                        bytes[row + x] = 255
                    }
                }
            }
        } else {
            for y in y0..<y1 {
                let row = y * canvasWidth
                for x in x0..<x1 { bytes[row + x] = 255 }
            }
        }
        return bytes
    }

    /// Tight bounds of non-zero mask bytes, or nil when the mask is empty.
    static func tightBounds(of bytes: [UInt8], canvasWidth: Int, canvasHeight: Int) -> CGRect? {
        guard canvasWidth > 0, canvasHeight > 0, bytes.count >= canvasWidth * canvasHeight else { return nil }
        var minX = canvasWidth, minY = canvasHeight, maxX = -1, maxY = -1
        for y in 0..<canvasHeight {
            let row = y * canvasWidth
            for x in 0..<canvasWidth where bytes[row + x] > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Builds a (possibly masked) selection from a canvas-sized mask.
    static func selection(fromCanvasMask bytes: [UInt8], canvasWidth: Int, canvasHeight: Int) -> SelectionModel? {
        guard let bounds = tightBounds(of: bytes, canvasWidth: canvasWidth, canvasHeight: canvasHeight) else {
            return nil
        }
        return SelectionModel(maskBytes: bytes, canvasWidth: canvasWidth, canvasHeight: canvasHeight, bounds: bounds)
    }

    static func union(_ a: SelectionModel, _ b: SelectionModel,
                      canvasWidth: Int, canvasHeight: Int) -> SelectionModel? {
        let ab = canvasMask(for: a, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let bb = canvasMask(for: b, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        var out = ab
        for i in 0..<out.count where bb[i] > 0 { out[i] = 255 }
        return Self.selection(fromCanvasMask: out, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    static func subtracting(_ b: SelectionModel, from a: SelectionModel,
                            canvasWidth: Int, canvasHeight: Int) -> SelectionModel? {
        var out = canvasMask(for: a, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let bb = canvasMask(for: b, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        for i in 0..<out.count where bb[i] > 0 { out[i] = 0 }
        return Self.selection(fromCanvasMask: out, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    static func shifted(_ selection: SelectionModel, dx: Int, dy: Int,
                        canvasWidth: Int, canvasHeight: Int) -> SelectionModel? {
        guard !selection.isEmpty, canvasWidth > 0, canvasHeight > 0 else { return nil }
        if dx == 0 && dy == 0 { return selection }
        let src = canvasMask(for: selection, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        var out = [UInt8](repeating: 0, count: canvasWidth * canvasHeight)
        for y in 0..<canvasHeight {
            let sy = y - dy
            guard sy >= 0, sy < canvasHeight else { continue }
            let srcRow = sy * canvasWidth
            let dstRow = y * canvasWidth
            for x in 0..<canvasWidth {
                let sx = x - dx
                guard sx >= 0, sx < canvasWidth else { continue }
                out[dstRow + x] = src[srcRow + sx]
            }
        }
        return Self.selection(fromCanvasMask: out, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    static func pixelCount(of selection: SelectionModel) -> Int {
        guard !selection.isEmpty else { return 0 }
        let b = selection.bounds
        if selection.mask == nil { return Int(b.width * b.height) }
        var count = 0
        let x0 = Int(b.minX), y0 = Int(b.minY)
        for y in 0..<Int(b.height) {
            for x in 0..<Int(b.width) {
                if selection.contains(CGPoint(x: CGFloat(x0 + x) + 0.5, y: CGFloat(y0 + y) + 0.5)) {
                    count += 1
                }
            }
        }
        return count
    }
}

// MARK: - Selection operations

/// Pixel-level operations on a Document's active layer. Every method is
/// defensive: locked layers and empty selections return `false` instead of
/// mutating anything, and the caller owns user-facing status messages.
enum SelectionOps {
    // MARK: Copy / cut / delete

    @discardableResult
    static func copySelection(in doc: Document) -> Bool {
        guard let selection = doc.selection, !selection.isEmpty,
              let layer = doc.activeLayer else { return false }
        let content = extract(from: layer.raster, selection: selection)
        return SelectionClipboard.write(content)
    }

    @discardableResult
    static func cutSelection(in doc: Document) -> Bool {
        guard let selection = doc.selection, !selection.isEmpty,
              let layer = doc.activeLayer, !layer.isLocked else { return false }
        guard copySelection(in: doc) else { return false }
        return deleteSelection(in: doc, named: "Cut", selection: selection)
    }

    @discardableResult
    static func deleteSelection(in doc: Document) -> Bool {
        guard let selection = doc.selection, !selection.isEmpty,
              let layer = doc.activeLayer, !layer.isLocked else { return false }
        return deleteSelection(in: doc, named: "Delete", selection: selection)
    }

    private static func deleteSelection(in doc: Document, named name: String,
                                        selection: SelectionModel) -> Bool {
        guard let layer = doc.activeLayer, !layer.isLocked else { return false }
        _ = layer
        let pending = doc.beginUndo(named: name, rects: [selection.bounds])
        clear(selection, in: layer.raster)
        doc.markChanged()
        doc.commitUndo(pending, selectionBefore: selection.bounds, selectionAfter: selection.bounds)
        doc.notifyChange(selection.bounds)
        return true
    }

    // MARK: Paste

    @discardableResult
    static func pasteSelection(in doc: Document) -> Bool {
        guard let content = SelectionClipboard.read() else { return false }
        let canvasSize = doc.canvasSize
        let oldSelection = doc.selection

        // Paint pastes at the selection origin; with no selection the image is
        // centred on the canvas.
        var origin: CGPoint
        if let sel = oldSelection, !sel.isEmpty {
            origin = CGPoint(x: sel.bounds.minX, y: sel.bounds.minY)
        } else {
            origin = CGPoint(x: max(0, (canvasSize.width - CGFloat(content.width)) / 2).rounded(),
                             y: max(0, (canvasSize.height - CGFloat(content.height)) / 2).rounded())
        }
        let drawRect = clipToCanvas(CGRect(x: origin.x, y: origin.y,
                                          width: CGFloat(content.width), height: CGFloat(content.height)),
                                    canvasSize: canvasSize)
        guard !drawRect.isNull, drawRect.width >= 1, drawRect.height >= 1 else {
            // Entire image is off-canvas: clamp it back to the canvas corner so
            // pasting a huge clipboard still does something predictable.
            origin = .zero
            let fallback = clipToCanvas(CGRect(x: 0, y: 0,
                                               width: CGFloat(content.width),
                                               height: CGFloat(content.height)),
                                        canvasSize: canvasSize)
            guard !fallback.isNull else { return false }
            return paste(content, at: origin, rect: fallback, into: doc, oldSelection: oldSelection)
        }
        return paste(content, at: origin, rect: drawRect, into: doc, oldSelection: oldSelection)
    }

    private static func paste(_ content: Raster, at origin: CGPoint, rect: CGRect,
                              into doc: Document, oldSelection: SelectionModel?) -> Bool {
        guard let layer = doc.activeLayer else { return false }
        let target: Layer
        if layer.isLocked {
            // Locked layer: contribute the paste on a new layer above it rather
            // than silently dropping the paste.
            target = doc.addLayer(name: "Pasted Image")
        } else {
            target = layer
        }
        let pending = doc.beginUndo(named: "Paste", rects: [rect])
        composite(content, into: target.raster, at: origin)
        doc.markChanged()

        let newSelection = SelectionModel(rect: rect)
        doc.setSelection(newSelection)
        doc.commitUndo(pending,
                       selectionBefore: (oldSelection?.isEmpty == false) ? oldSelection?.bounds : nil,
                       selectionAfter: rect)
        doc.notifyChange(rect)
        return true
    }

    // MARK: Move / nudge

    @discardableResult
    static func moveSelection(in doc: Document, dx: Int, dy: Int) -> Bool {
        guard let selection = doc.selection, !selection.isEmpty,
              let layer = doc.activeLayer, !layer.isLocked else { return false }
        guard dx != 0 || dy != 0 else { return false }
        let canvasWidth = doc.width, canvasHeight = doc.height
        let target = SelectionMaskBuilder.shifted(selection, dx: dx, dy: dy,
                                                  canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let content = extract(from: layer.raster, selection: selection)
        let sourceBounds = selection.bounds
        let destination = sourceBounds.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy))

        let pending = doc.beginUndo(named: "Move Selection", rects: [sourceBounds, destination])
        clear(selection, in: layer.raster)
        composite(content, into: layer.raster, at: destination.origin)
        doc.markChanged()
        doc.setSelection(target)
        doc.commitUndo(pending,
                       selectionBefore: sourceBounds,
                       selectionAfter: target?.bounds)
        doc.notifyChange(sourceBounds.union(destination))
        return true
    }

    @discardableResult
    static func nudgeSelection(in doc: Document, dx: Int, dy: Int) -> Bool {
        moveSelection(in: doc, dx: dx, dy: dy)
    }

    // MARK: Pixel helpers (also used by the selection tools)

    /// Copies the pixels of `selection` out of `raster` into a new raster whose
    /// origin is the selection's bounds origin. Masked selections keep only the
    /// covered pixels; everything outside the mask stays transparent.
    static func extract(from raster: Raster, selection: SelectionModel) -> Raster {
        let b = selection.bounds.integral
        let width = max(1, Int(b.width)), height = max(1, Int(b.height))
        let out = Raster(width: width, height: height)
        let x0 = Int(b.minX), y0 = Int(b.minY)
        let srcX0 = max(0, x0), srcY0 = max(0, y0)
        let srcX1 = min(raster.width, x0 + width), srcY1 = min(raster.height, y0 + height)
        guard srcX0 < srcX1, srcY0 < srcY1 else { return out }
        if selection.mask == nil {
            for y in srcY0..<srcY1 {
                let src = raster.index(srcX0, y)
                let dst = out.index(srcX0 - x0, y - y0)
                memcpy(out.data + dst, raster.data + src,
                       (srcX1 - srcX0) * PixelFormat.bytesPerPixel)
            }
        } else {
            for y in srcY0..<srcY1 {
                for x in srcX0..<srcX1 {
                    guard selection.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) else { continue }
                    let si = raster.index(x, y)
                    let di = out.index(x - x0, y - y0)
                    out.data[di] = raster.data[si]
                    out.data[di + 1] = raster.data[si + 1]
                    out.data[di + 2] = raster.data[si + 2]
                    out.data[di + 3] = raster.data[si + 3]
                }
            }
        }
        return out
    }

    /// Clears the pixels covered by `selection` to transparent.
    static func clear(_ selection: SelectionModel, in raster: Raster) {
        guard !selection.isEmpty else { return }
        let b = selection.bounds
        if selection.mask == nil {
            raster.clear(rect: b)
            return
        }
        let x0 = max(0, Int(b.minX)), y0 = max(0, Int(b.minY))
        let x1 = min(raster.width, Int(b.maxX)), y1 = min(raster.height, Int(b.maxY))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard selection.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) else { continue }
                let i = raster.index(x, y)
                raster.data[i] = 0; raster.data[i + 1] = 0
                raster.data[i + 2] = 0; raster.data[i + 3] = 0
            }
        }
    }

    /// Draws `content` into `raster` with its top-left corner at `origin`,
    /// overwriting (normal alpha compositing) whatever is underneath.
    static func composite(_ content: Raster, into raster: Raster, at origin: CGPoint) {
        guard let image = content.makeImage() else { return }
        raster.bitmapContext.saveGState()
        raster.bitmapContext.interpolationQuality = .none
        CGImageDrawing.drawUpright(image,
                                   in: CGRect(x: origin.x, y: origin.y,
                                              width: CGFloat(content.width), height: CGFloat(content.height)),
                                   into: raster.bitmapContext)
        raster.bitmapContext.restoreGState()
    }

    /// Convenience for tools that already captured a floating raster.
    static func drawFloating(_ content: Raster, into raster: Raster, at origin: CGPoint) {
        composite(content, into: raster, at: origin)
    }
}

// MARK: - Document convenience wrappers

/// Non-@objc Swift methods the workspace/menu code can call directly. They are
/// internal (single-module app) but stable; see the SELF-TEST notes above.
extension Document {
    @discardableResult func cutSelection() -> Bool { SelectionOps.cutSelection(in: self) }
    @discardableResult func copySelection() -> Bool { SelectionOps.copySelection(in: self) }
    @discardableResult func pasteSelection() -> Bool { SelectionOps.pasteSelection(in: self) }
    @discardableResult func deleteSelection() -> Bool { SelectionOps.deleteSelection(in: self) }
    @discardableResult func moveSelection(dx: Int, dy: Int) -> Bool {
        SelectionOps.moveSelection(in: self, dx: dx, dy: dy)
    }
    @discardableResult func nudgeSelection(dx: Int, dy: Int) -> Bool {
        SelectionOps.nudgeSelection(in: self, dx: dx, dy: dy)
    }
}
