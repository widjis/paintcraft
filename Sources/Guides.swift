import AppKit
import CoreGraphics

// MARK: - Smart guides (enhancement over classic Paint)
//
// SELF-TEST (manual, no UI automation available):
//  1. Open the app, add a second layer with a painted shape, activate the
//     rectangle or selection tool and drag near the shape's edge: a blue smart
//     guide appears and the dragged rect snaps to the shape's edge.
//  2. Drag near the canvas centre: the centre guide appears and the shape snaps
//     to the exact middle pixel.
//  3. Toggle `guidesOverlay.isVisible = false` (or the View ribbon toggle once
//     wired) and confirm no guides are drawn, while snapping still uses none.
//  4. With zoom at 800% a 6-point snap tolerance still feels like ~6 screen
//     points (threshold is converted to image space by the current zoom).
//
// The engine is deliberately independent of CanvasView internals: `draw` only
// reads `zoomScale` and `canvasOrigin` (and the supplied view-space imageRect),
// so CanvasView can own one instance and call it from `draw(_:)`.

/// Orientation of a smart guide. `.vertical` guides are lines of constant x,
/// `.horizontal` guides are lines of constant y (image space, top-left origin).
enum GuideOrientation: String, Equatable {
    case vertical
    case horizontal
}

/// Where a guide came from. Used for styling and for status messages.
enum GuideKind: String, Equatable {
    case canvasEdge
    case canvasCenter
    case otherBounds

    var isCanvasGuide: Bool { self != .otherBounds }
}

/// One alignment guide in image space (top-left origin, same space as Raster).
struct GuideLine: Equatable {
    var orientation: GuideOrientation
    /// x for vertical guides, y for horizontal guides.
    var position: CGFloat
    /// Spans are in image space; currently the whole canvas, kept for callers
    /// that want to draw a partial guide later.
    var start: CGFloat
    var end: CGFloat
    var kind: GuideKind

    /// Distance from a candidate coordinate to this guide.
    func distance(to value: CGFloat) -> CGFloat { abs(value - position) }
}

/// Computes and draws smart alignment guides, and snaps points to them.
///
/// Usage from CanvasView (all main-thread):
/// ```
/// // on drag begin:
/// guidesOverlay.sync(to: self)
/// guidesOverlay.beginInteraction(in: document)
/// // inside mouseDragged, after computing the drag rect in image space:
/// let lines = guidesOverlay.computeGuides(for: dragRect, document: document)
/// let (snapped, used) = guidesOverlay.snap(anchorPoint)
/// // inside draw(_:), after the composite:
/// guidesOverlay.draw(in: ctx, canvasView: self, imageRect: canvasRect)
/// // on drag end:
/// guidesOverlay.endInteraction()
/// ```
final class GuidesOverlay {
    /// Master visibility toggle (wire the View ribbon toggle to this).
    var isVisible: Bool = true

    /// When true, canvas edges and the canvas centre are always returned as
    /// guides (useful at low zoom). When false they are only shown when the
    /// dragged rect is within the proximity threshold, like other guides.
    var alwaysShowCanvasGuides: Bool = false

    /// Snap tolerance in *view points* (converted to image space by zoomScale).
    var snapThresholdPoints: CGFloat = 6

    /// How close (in view points) another layer's bounds must be to become a
    /// guide.
    var otherBoundsProximityPoints: CGFloat = 8

    /// Current canvas zoom, set by `sync(to:)` or directly by the Lead wiring.
    var zoomScale: CGFloat = 1

    /// Guides produced by the last `computeGuides` call. `draw` renders these.
    private(set) var activeGuides: [GuideLine] = []

    // Interaction cache: other-layer bounds are expensive to scan, so scan once
    // per drag rather than once per mouseDragged event.
    private var cachedOtherBounds: [CGRect] = []
    private var cachedCanvasSize: CGSize = .zero
    private var isInteracting = false
    private var otherBoundsValid = false

    // MARK: - Configuration helpers

    /// Copies the canvas zoom so snapping tolerances stay screen-sized.
    /// Reads only `CanvasView.zoomScale` (documented allowed dependency).
    func sync(to canvasView: CanvasView) {
        zoomScale = max(0.01, canvasView.zoomScale)
    }

    /// Effective snap tolerance in image pixels.
    private var snapTolerance: CGFloat {
        snapThresholdPoints / max(zoomScale, 0.01)
    }

    /// Effective proximity threshold for other-layer bounds in image pixels.
    private var proximityTolerance: CGFloat {
        otherBoundsProximityPoints / max(zoomScale, 0.01)
    }

    // MARK: - Drag lifecycle (call once per gesture; optional but faster)

    /// Caches canvas size and the content bounds of every other visible layer.
    func beginInteraction(in document: Document) {
        cachedCanvasSize = document.canvasSize
        let activeID = document.activeLayer?.id
        cachedOtherBounds = GuidesOverlay.contentBounds(of: document.layers,
                                                        excluding: activeID)
        otherBoundsValid = true
        isInteracting = true
    }

    /// Clears cached bounds and any stale guides after the gesture ends.
    func endInteraction() {
        isInteracting = false
        otherBoundsValid = false
        cachedOtherBounds = []
        activeGuides = []
    }

    /// Invalidates the cached other-layer bounds (call after painting/layer edits
    /// if a gesture is stretched across multiple edits).
    func invalidateOtherBounds() {
        otherBoundsValid = false
        cachedOtherBounds = []
    }

    /// Clears the active guide set (e.g. when a tool is deactivated).
    func clear() {
        activeGuides = []
    }

    // MARK: - Guide computation

    /// Convenience: computes guides for `rect`, using the cached other-layer
    /// bounds from `beginInteraction(in:)`. Falls back to scanning the document
    /// once when no interaction cache exists.
    func computeGuides(for rect: CGRect, document: Document) -> [GuideLine] {
        if !isInteracting || !otherBoundsValid {
            beginInteraction(in: document)
        }
        return computeGuides(for: rect, canvasSize: document.canvasSize,
                             others: cachedOtherBounds)
    }

    /// Computes canvas-edge/centre guides and nearby other-bounds guides.
    ///
    /// - Parameters:
    ///   - rect: dragged rect in image space (top-left origin).
    ///   - canvasSize: document size in pixels.
    ///   - others: content bounds of other layers/objects, in image space.
    /// - Returns: deduplicated guides, vertical ones first, and stores them as
    ///   `activeGuides` for drawing.
    func computeGuides(for rect: CGRect, canvasSize: CGSize, others: [CGRect]) -> [GuideLine] {
        let w = max(canvasSize.width, 1)
        let h = max(canvasSize.height, 1)
        let tol = proximityTolerance
        var verticals: [CGFloat] = []
        var horizontals: [CGFloat] = []
        var verticalKinds: [CGFloat: GuideKind] = [:]
        var horizontalKinds: [CGFloat: GuideKind] = [:]

        func addVertical(_ x: CGFloat, _ kind: GuideKind) {
            guard x >= -0.001, x <= w + 0.001 else { return }
            if !verticals.contains(where: { abs($0 - x) < 0.01 }) { verticals.append(x) }
            // Canvas guides win over layer guides at the same position.
            verticalKinds[x] = kind.isCanvasGuide ? kind : (verticalKinds[x] ?? kind)
        }
        func addHorizontal(_ y: CGFloat, _ kind: GuideKind) {
            guard y >= -0.001, y <= h + 0.001 else { return }
            if !horizontals.contains(where: { abs($0 - y) < 0.01 }) { horizontals.append(y) }
            horizontalKinds[y] = kind.isCanvasGuide ? kind : (horizontalKinds[y] ?? kind)
        }

        let canvasX: [(CGFloat, GuideKind)] = [(0, .canvasEdge), (w / 2, .canvasCenter), (w, .canvasEdge)]
        let canvasY: [(CGFloat, GuideKind)] = [(0, .canvasEdge), (h / 2, .canvasCenter), (h, .canvasEdge)]
        let rectX = [rect.minX, rect.midX, rect.maxX]
        let rectY = [rect.minY, rect.midY, rect.maxY]

        if alwaysShowCanvasGuides {
            for (x, kind) in canvasX { addVertical(x, kind) }
            for (y, kind) in canvasY { addHorizontal(y, kind) }
        }

        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tol }

        // Canvas edges + centre: emitted when the dragged rect aligns nearby.
        for rx in rectX {
            for (cx, kind) in canvasX where near(rx, cx) {
                addVertical(cx, kind)
            }
        }
        for ry in rectY {
            for (cy, kind) in canvasY where near(ry, cy) {
                addHorizontal(cy, kind)
            }
        }

        // Nearby other bounds: compare every rect edge/centre to every other
        // edge/centre and guide at the other object's coordinate.
        for other in others where !other.isEmpty {
            let ox = [other.minX, other.midX, other.maxX]
            let oy = [other.minY, other.midY, other.maxY]
            for rx in rectX {
                for cx in ox where near(rx, cx) {
                    addVertical(cx, .otherBounds)
                }
            }
            for ry in rectY {
                for cy in oy where near(ry, cy) {
                    addHorizontal(cy, .otherBounds)
                }
            }
        }

        verticals.sort()
        horizontals.sort()
        var result: [GuideLine] = []
        for x in verticals {
            result.append(GuideLine(orientation: .vertical, position: x,
                                    start: 0, end: h, kind: verticalKinds[x] ?? .otherBounds))
        }
        for y in horizontals {
            result.append(GuideLine(orientation: .horizontal, position: y,
                                    start: 0, end: w, kind: horizontalKinds[y] ?? .otherBounds))
        }
        activeGuides = result
        return result
    }

    /// Convenience overload for a point (e.g. pencil anchor or cursor).
    func computeGuides(for point: CGPoint, canvasSize: CGSize, others: [CGRect]) -> [GuideLine] {
        computeGuides(for: CGRect(origin: point, size: .zero), canvasSize: canvasSize, others: others)
    }

    // MARK: - Snapping

    /// Snaps `point` (image space) to the nearest active guide within tolerance.
    /// Returns the snapped point and the guides responsible (empty when none).
    func snap(_ point: CGPoint) -> (CGPoint, [GuideLine]) {
        guard !activeGuides.isEmpty else { return (point, []) }
        let tol = snapTolerance
        var bestVertical: GuideLine?
        var bestVerticalDistance = CGFloat.greatestFiniteMagnitude
        var bestHorizontal: GuideLine?
        var bestHorizontalDistance = CGFloat.greatestFiniteMagnitude

        for guide in activeGuides {
            switch guide.orientation {
            case .vertical:
                let d = guide.distance(to: point.x)
                if d <= tol, d < bestVerticalDistance {
                    bestVerticalDistance = d
                    bestVertical = guide
                }
            case .horizontal:
                let d = guide.distance(to: point.y)
                if d <= tol, d < bestHorizontalDistance {
                    bestHorizontalDistance = d
                    bestHorizontal = guide
                }
            }
        }

        var snapped = point
        var used: [GuideLine] = []
        if let v = bestVertical { snapped.x = v.position; used.append(v) }
        if let h = bestHorizontal { snapped.y = h.position; used.append(h) }
        return (snapped, used)
    }

    /// Snaps a point but keeps the un-snapped coordinate when nothing is near.
    /// Identical to `snap(_:)`; kept as a named alternative for readability.
    func snapPoint(_ point: CGPoint) -> (CGPoint, [GuideLine]) { snap(point) }

    // MARK: - Drawing

    /// Draws the active guides into the canvas view context (view/point space).
    /// - Parameters:
    ///   - ctx: current AppKit graphics context.
    ///   - canvasView: only `zoomScale` and `canvasOrigin` are read.
    ///   - imageRect: canvas rect in view space (as computed by CanvasView).
    func draw(in ctx: CGContext, canvasView: CanvasView, imageRect: CGRect) {
        guard isVisible, !activeGuides.isEmpty else { return }
        let origin = canvasView.canvasOrigin
        let zoom = max(0.0001, canvasView.zoomScale)
        let accent = NSColor.controlAccentColor
        let color = (accent.blended(withFraction: 0.35, of: .systemPink) ?? accent)
            .withAlphaComponent(0.9)
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(color.cgColor)
        for guide in activeGuides {
            switch guide.orientation {
            case .vertical:
                let x = (origin.x + guide.position * zoom).rounded() + 0.5
                ctx.move(to: CGPoint(x: x, y: imageRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: imageRect.maxY))
            case .horizontal:
                let y = (origin.y + guide.position * zoom).rounded() + 0.5
                ctx.move(to: CGPoint(x: imageRect.minX, y: y))
                ctx.addLine(to: CGPoint(x: imageRect.maxX, y: y))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Content bounds helpers

    /// Bounding rect of non-transparent pixels in `layer`, in image space.
    /// Returns nil for empty/locked-hidden content. Scans raw alpha bytes, so it
    /// is O(width × height) — call once per gesture, not per mouse event.
    static func contentBounds(of layer: Layer) -> CGRect? {
        guard layer.isVisible else { return nil }
        let raster = layer.raster
        let w = raster.width
        let h = raster.height
        guard w > 0, h > 0 else { return nil }
        var minX = w
        var minY = h
        var maxX = -1
        var maxY = -1
        let data = raster.data
        let stride = raster.stride
        for y in 0..<h {
            let row = y * stride
            // Quick row reject: skip rows that are fully transparent.
            var hasAlpha = false
            var x = 0
            while x < w {
                if data[row + x * 4 + 3] != 0 { hasAlpha = true; break }
                x += 1
            }
            guard hasAlpha else { continue }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
            for x in 0..<w where data[row + x * 4 + 3] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    /// Convenience: content bounds of several layers, optionally skipping one
    /// (normally the active layer being dragged).
    static func contentBounds(of layers: [Layer], excluding layerID: UUID?) -> [CGRect] {
        layers.compactMap { layer in
            guard layer.id != layerID else { return nil }
            return contentBounds(of: layer)
        }
    }
}
