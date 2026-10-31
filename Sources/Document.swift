import AppKit
import CoreGraphics

// MARK: - Blend modes

enum BlendMode: String, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, darken, lighten, difference, plusLighter

    var id: String { rawValue }

    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .difference: return .difference
        case .plusLighter: return .plusLighter
        }
    }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        case .difference: return "Difference"
        case .plusLighter: return "Add"
        }
    }
}

// MARK: - Layer

/// One layer of the document: pixels plus compositing attributes and an
/// optional non-destructive adjustment chain (enhancement over classic Paint).
final class Layer {
    let id: UUID
    var name: String
    var isVisible: Bool
    var opacity: Double        // 0...1
    var blendMode: BlendMode
    var isLocked: Bool
    var raster: Raster
    var adjustments: [Adjustment] = []

    init(name: String, width: Int, height: Int) {
        self.id = UUID()
        self.name = name
        self.isVisible = true
        self.opacity = 1.0
        self.blendMode = .normal
        self.isLocked = false
        self.raster = Raster(width: width, height: height)
    }

    init(name: String, raster: Raster) {
        self.id = UUID()
        self.name = name
        self.isVisible = true
        self.opacity = 1.0
        self.blendMode = .normal
        self.isLocked = false
        self.raster = raster
    }

    /// Render this layer (with adjustments applied) as a CGImage at native size.
    func renderedImage() -> CGImage? {
        let base = raster.makeImage()
        if adjustments.isEmpty { return base }
        return AdjustmentPipeline.apply(adjustments, to: raster)
    }

    /// Draw into a canvas context whose coordinate space is the layer's space.
    /// Callers are responsible for setting up scale/offset.
    func draw(into ctx: CGContext) {
        guard isVisible, opacity > 0.001 else { return }
        guard let img = renderedImage() else { return }
        ctx.saveGState()
        ctx.setBlendMode(blendMode.cgBlendMode)
        ctx.setAlpha(CGFloat(opacity))
        CGImageDrawing.drawUpright(img, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height),
                                   into: ctx)
        ctx.restoreGState()
    }
}

// MARK: - Undo

struct LayerRasterChange {
    let layerID: UUID
    let before: Raster   // region contents before the edit
    let after: Raster    // region contents after the edit
    let region: CGRect   // region in image space
}

/// Undo/redo stack holding rectangular layer snapshots. Region snapshots keep
/// memory bounded even on huge documents.
final class UndoStack {
    struct Item {
        let name: String
        let layerChanges: [LayerRasterChange]
        let selectionBefore: CGRect?
        let selectionAfter: CGRect?
    }

    private(set) var undoItems: [Item] = []
    private(set) var redoItems: [Item] = []
    var limit: Int = 40

    var canUndo: Bool { !undoItems.isEmpty }
    var canRedo: Bool { !redoItems.isEmpty }

    func push(_ item: Item) {
        undoItems.append(item)
        if undoItems.count > limit { undoItems.removeFirst(undoItems.count - limit) }
        redoItems.removeAll()
    }

    func popUndo() -> Item? {
        guard let item = undoItems.popLast() else { return nil }
        redoItems.append(item)
        return item
    }

    func popRedo() -> Item? {
        guard let item = redoItems.popLast() else { return nil }
        undoItems.append(item)
        return item
    }

    func clear() {
        undoItems.removeAll()
        redoItems.removeAll()
    }

    var titles: [String] { undoItems.map { $0.name } }
}

// MARK: - Document

protocol DocumentDelegate: AnyObject {
    func documentDidChange(_ doc: Document, region: CGRect?)
    func documentLayersDidChange(_ doc: Document)
    func documentSelectionDidChange(_ doc: Document)
    func documentHistoryDidChange(_ doc: Document)
    func documentDidChangeName(_ doc: Document)
}

/// The editing document: a stack of layers, a selection, and undo history.
final class Document {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var layers: [Layer]   // mutate via document API; FileIO rebuilds on load
    var activeLayerIndex: Int
    var selection: SelectionModel?
    var dirty: Bool = false
    var fileURL: URL?
    var documentName: String = "Untitled"
    var undoStack = UndoStack()
    weak var delegate: DocumentDelegate?

    private var compositeCache: CGImage?
    private var revision: Int = 0

    var activeLayer: Layer? {
        guard layers.indices.contains(activeLayerIndex) else { return layers.last }
        return layers[activeLayerIndex]
    }

    var canvasSize: CGSize { CGSize(width: width, height: height) }

    init(width: Int, height: Int, background: PixelColor = .white) {
        self.width = max(1, width)
        self.height = max(1, height)
        let bg = Layer(name: "Background", width: self.width, height: self.height)
        bg.raster.fill(background)
        self.layers = [bg]
        self.activeLayerIndex = 0
    }

    /// Document with a single imported image as the background layer.
    init(image: CGImage) {
        self.width = image.width
        self.height = image.height
        let layer = Layer(name: "Background", raster: Raster.from(cgImage: image))
        self.layers = [layer]
        self.activeLayerIndex = 0
    }

    // MARK: Layer management

    @discardableResult
    func addLayer(name: String? = nil, above: Int? = nil) -> Layer {
        let layer = Layer(name: name ?? "Layer \(layers.count)", width: width, height: height)
        let index = min((above ?? activeLayerIndex) + 1, layers.count)
        layers.insert(layer, at: index)
        activeLayerIndex = index
        markChanged()
        delegate?.documentLayersDidChange(self)
        return layer
    }

    func removeLayer(at index: Int) {
        guard layers.count > 1, layers.indices.contains(index) else { return }
        layers.remove(at: index)
        activeLayerIndex = min(activeLayerIndex, layers.count - 1)
        markChanged()
        delegate?.documentLayersDidChange(self)
    }

    func duplicateLayer(at index: Int) {
        guard layers.indices.contains(index) else { return }
        let src = layers[index]
        let copy = Layer(name: src.name + " copy", raster: src.raster.snapshot())
        copy.opacity = src.opacity
        copy.blendMode = src.blendMode
        copy.isVisible = src.isVisible
        layers.insert(copy, at: index + 1)
        activeLayerIndex = index + 1
        markChanged()
        delegate?.documentLayersDidChange(self)
    }

    func moveLayer(from: Int, to: Int) {
        guard layers.indices.contains(from), to >= 0, to < layers.count, from != to else { return }
        let layer = layers.remove(at: from)
        layers.insert(layer, at: to)
        activeLayerIndex = to
        markChanged()
        delegate?.documentLayersDidChange(self)
    }

    func mergeLayerDown(at index: Int) {
        guard layers.indices.contains(index), index > 0 else { return }
        let top = layers[index], bottom = layers[index - 1]
        let merged = bottom.raster.snapshot()
        if let img = top.renderedImage() {
            merged.bitmapContext.saveGState()
            merged.bitmapContext.setAlpha(CGFloat(top.opacity))
            merged.bitmapContext.setBlendMode(top.blendMode.cgBlendMode)
            merged.bitmapContext.draw(img, in: merged.bounds)
            merged.bitmapContext.restoreGState()
        }
        bottom.raster.replaceContents(with: merged)
        layers.remove(at: index)
        activeLayerIndex = index - 1
        markChanged()
        delegate?.documentLayersDidChange(self)
    }

    func flatten() -> Raster {
        let out = Raster(width: width, height: height)
        for layer in layers {
            layer.draw(into: out.bitmapContext)
        }
        return out
    }

    // MARK: Canvas-level operations

    /// Paint has two distinct resize operations.
    /// - Canvas resize: keeps pixel scale, changes the canvas box; the existing
    ///   artwork is anchored (default centre) inside the new canvas.
    /// - Image resize: scales the artwork itself to the new dimensions.
    func resizeCanvas(to newWidth: Int, newHeight: Int,
                      anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let w = max(1, newWidth), h = max(1, newHeight)
        for i in layers.indices {
            let old = layers[i].raster
            let newRaster = Raster(width: w, height: h)
            let ox = (CGFloat(w) - CGFloat(old.width)) * anchor.x
            let oy = (CGFloat(h) - CGFloat(old.height)) * anchor.y
            if let img = old.makeImage() {
                CGImageDrawing.drawUpright(img, in: CGRect(x: ox, y: oy,
                                                           width: CGFloat(old.width),
                                                           height: CGFloat(old.height)),
                                           into: newRaster.bitmapContext)
            }
            layers[i].raster = newRaster
        }
        width = w; height = h
        selection = nil
        undoStack.clear()
        markChanged()
        delegate?.documentLayersDidChange(self)
        delegate?.documentSelectionDidChange(self)
    }

    /// Scales the artwork (all layers) to the new pixel dimensions.
    func resizeImage(to newWidth: Int, newHeight: Int) {
        let w = max(1, newWidth), h = max(1, newHeight)
        for i in layers.indices {
            layers[i].raster = layers[i].raster.resized(to: w, newHeight: h)
        }
        width = w; height = h
        selection = nil
        undoStack.clear()
        markChanged()
        delegate?.documentLayersDidChange(self)
        delegate?.documentSelectionDidChange(self)
    }

    func crop(to rect: CGRect) {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard r.width >= 1, r.height >= 1 else { return }
        for i in layers.indices {
            layers[i].raster = layers[i].raster.cropped(r)
        }
        width = Int(r.width); height = Int(r.height)
        selection = nil
        undoStack.clear()
        markChanged()
        delegate?.documentLayersDidChange(self)
        delegate?.documentSelectionDidChange(self)
    }

    func rotate90(clockwise: Bool) {
        for i in layers.indices {
            layers[i].raster = clockwise ? layers[i].raster.rotate90Clockwise()
                                         : layers[i].raster.rotate90CounterClockwise()
        }
        swap(&width, &height)
        selection = nil
        undoStack.clear()
        markChanged()
        delegate?.documentLayersDidChange(self)
        delegate?.documentSelectionDidChange(self)
    }

    func rotate180() {
        for i in layers.indices {
            layers[i].raster = layers[i].raster.rotate180()
        }
        undoStack.clear()
        markChanged()
        delegate?.documentLayersDidChange(self)
    }

    func flip(horizontal: Bool) {
        for i in layers.indices {
            if horizontal { layers[i].raster.flipHorizontally() } else { layers[i].raster.flipVertically() }
        }
        undoStack.clear()
        markChanged()
        delegate?.documentLayersDidChange(self)
    }

    func invertColors() {
        guard let layer = activeLayer, !layer.isLocked else { return }
        let region = CGRect(x: 0, y: 0, width: width, height: height)
        let pending = beginUndo(named: "Invert Colors", rects: [region])
        for y in 0..<height {
            for x in 0..<width {
                let i = layer.raster.index(x, y)
                layer.raster.data[i] = 255 - layer.raster.data[i]
                layer.raster.data[i + 1] = 255 - layer.raster.data[i + 1]
                layer.raster.data[i + 2] = 255 - layer.raster.data[i + 2]
            }
        }
        commitUndo(pending)
        markChanged()
        delegate?.documentDidChange(self, region: region)
    }

    // MARK: Selection

    func setSelection(_ sel: SelectionModel?) {
        selection = sel
        delegate?.documentSelectionDidChange(self)
    }

    func selectAll() {
        selection = SelectionModel(rect: CGRect(x: 0, y: 0, width: width, height: height))
        delegate?.documentSelectionDidChange(self)
    }

    func deselect() {
        guard selection != nil else { return }
        selection = nil
        delegate?.documentSelectionDidChange(self)
    }

    // MARK: Undo

    /// Snapshot regions of layers before a mutation, so the mutation can be undone.
    struct PendingUndo {
        var name: String
        var snapshots: [(layerID: UUID, before: Raster, region: CGRect)]
    }

    func beginUndo(named name: String, rects: [CGRect]) -> PendingUndo {
        guard let layer = activeLayer else { return PendingUndo(name: name, snapshots: []) }
        var snaps: [(UUID, Raster, CGRect)] = []
        for rect in rects {
            let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard clipped.width >= 1, clipped.height >= 1 else { continue }
            let before = layer.raster.cropped(clipped)
            snaps.append((layer.id, before, clipped))
        }
        return PendingUndo(name: name, snapshots: snaps)
    }

    func commitUndo(_ pending: PendingUndo, selectionBefore: CGRect? = nil, selectionAfter: CGRect? = nil) {
        guard !pending.snapshots.isEmpty else { return }
        var changes: [LayerRasterChange] = []
        for snap in pending.snapshots {
            // Capture the post-edit pixels now, so redo can restore them.
            let after: Raster
            if let layer = layers.first(where: { $0.id == snap.layerID }) {
                after = layer.raster.cropped(snap.region)
            } else {
                after = snap.before.snapshot()
            }
            changes.append(LayerRasterChange(layerID: snap.layerID, before: snap.before,
                                             after: after, region: snap.region))
        }
        undoStack.push(UndoStack.Item(name: pending.name, layerChanges: changes,
                                      selectionBefore: selectionBefore, selectionAfter: selectionAfter))
        dirty = true
        delegate?.documentHistoryDidChange(self)
    }

    func undo() {
        guard let item = undoStack.popUndo() else { return }
        for change in item.layerChanges {
            guard let layer = layers.first(where: { $0.id == change.layerID }) else { continue }
            restore(change.before, into: layer, region: change.region)
        }
        if let sel = item.selectionBefore {
            selection = SelectionModel(rect: sel)
        } else {
            selection = nil
        }
        dirty = true
        invalidateComposite()
        delegate?.documentDidChange(self, region: nil)
        delegate?.documentSelectionDidChange(self)
        delegate?.documentHistoryDidChange(self)
    }

    func redo() {
        guard let item = undoStack.popRedo() else { return }
        for change in item.layerChanges {
            guard let layer = layers.first(where: { $0.id == change.layerID }) else { continue }
            restore(change.after, into: layer, region: change.region)
        }
        if let sel = item.selectionAfter {
            selection = SelectionModel(rect: sel)
        } else {
            selection = nil
        }
        dirty = true
        invalidateComposite()
        delegate?.documentDidChange(self, region: nil)
        delegate?.documentSelectionDidChange(self)
        delegate?.documentHistoryDidChange(self)
    }

    private func restore(_ snapshot: Raster, into layer: Layer, region: CGRect) {
        layer.raster.bitmapContext.saveGState()
        layer.raster.bitmapContext.clear(region)
        if let img = snapshot.makeImage() {
            CGImageDrawing.drawUpright(img, in: CGRect(x: region.minX, y: region.minY,
                                                       width: region.width, height: region.height),
                                       into: layer.raster.bitmapContext)
        }
        layer.raster.bitmapContext.restoreGState()
    }

    /// Restores a layer region directly (used by tool cancellation).
    func restoreLayerRegion(_ snapshot: Raster, layerID: UUID, region: CGRect) {
        guard let layer = layers.first(where: { $0.id == layerID }) else { return }
        restore(snapshot, into: layer, region: region)
        markChanged()
    }

    // MARK: Change tracking

    func markChanged() {
        revision += 1
        dirty = true
        compositeCache = nil
    }

    func notifyChange(_ region: CGRect?) {
        markChanged()
        delegate?.documentDidChange(self, region: region)
    }

    func invalidateComposite() {
        compositeCache = nil
    }

    /// Composite of all visible layers at document resolution. Cached until the
    /// document changes.
    func compositeImage() -> CGImage? {
        if let cached = compositeCache { return cached }
        let out = Raster(width: width, height: height)
        for layer in layers { layer.draw(into: out.bitmapContext) }
        compositeCache = out.makeImage()
        return compositeCache
    }

    func clearAll() {
        undoStack.clear()
        layers.removeAll()
        let bg = Layer(name: "Background", width: width, height: height)
        bg.raster.fill(.white)
        layers = [bg]
        activeLayerIndex = 0
        selection = nil
        revision += 1
        compositeCache = nil
        delegate?.documentLayersDidChange(self)
        delegate?.documentDidChange(self, region: nil)
    }
}

// MARK: - Layer helpers

extension Layer {
    /// Copies compositing attributes (name/opacity/blend/visibility/adjustments)
    /// from another layer into this freshly constructed one.
    func copyingAttributes(from other: Layer) -> Layer {
        self.name = other.name
        self.isVisible = other.isVisible
        self.opacity = other.opacity
        self.blendMode = other.blendMode
        self.isLocked = other.isLocked
        self.adjustments = other.adjustments
        return self
    }
}

// MARK: - Raster from CGImage

extension Raster {
    static func from(cgImage: CGImage) -> Raster {
        let r = Raster(width: cgImage.width, height: cgImage.height)
        r.bitmapContext.saveGState()
        r.bitmapContext.interpolationQuality = .high
        CGImageDrawing.drawUpright(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height),
                                   into: r.bitmapContext)
        r.bitmapContext.restoreGState()
        return r
    }
}

// MARK: - Loading support

extension Document {
    /// Replaces the layer stack wholesale. Used only by the file loader, which
    /// constructs layers from decoded bytes; never call this from tools.
    func replaceLayersForLoad(_ newLayers: [Layer], activeIndex: Int) {
        guard !newLayers.isEmpty else { return }
        layers = newLayers
        activeLayerIndex = min(max(0, activeIndex), newLayers.count - 1)
        invalidateComposite()
    }
}
