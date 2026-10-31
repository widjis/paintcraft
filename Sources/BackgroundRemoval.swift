import AppKit
import CoreGraphics

// MARK: - Background removal (Windows 11 Paint-style "Remove background")
//
// SELF-TEST (manual, no UI automation available):
//  1. Open a photo on the Background layer, choose Image > Remove background…
//     (once Lead wires `BackgroundRemovalAction.presentPanel`), keep tolerance
//     ~30 and feather 1 px, press Apply. The flat edge colour becomes
//     transparent and a "Removed N px" status is shown by the Lead's wiring.
//  2. Press Cmd+Z: the removed pixels come back (single undo step).
//  3. Make a rectangular selection around a region that contains background
//     touching its border, Apply: only pixels inside the selection change and
//     everything outside is bit-identical.
//  4. Lock the active layer: Apply is disabled and a friendly note is shown.
//  5. Raise tolerance above the background/subject colour distance and confirm
//     the subject survives; lower it to 0 and confirm only exact edge colours
//     are removed.
//
// Headless check (add to SelfTest.run() if desired):
//   let doc = Document(width: 32, height: 32)
//   doc.activeLayer!.raster.fill(.white)
//   doc.activeLayer!.raster.fill(rect: CGRect(x: 8, y: 8, width: 16, height: 16),
//                                with: PixelColor(r: 200, g: 30, b: 30))
//   let n = BackgroundRemoval.removeBackground(document: doc, tolerance: 8, feather: 1)
//   // expected: n > 0, doc.activeLayer!.raster.getPixel(0, 0).a == 0,
//   //           doc.activeLayer!.raster.getPixel(16, 16).a == 255

/// Flood-fill background removal with colour tolerance and edge feathering.
///
/// The algorithm marks background by flood filling from the image edges (or,
/// when a selection is active, from the selection's boundary) using colour
/// tolerance 0...255. Marked pixels are cleared to transparent; when `feather`
/// is 1...3 the retained pixels immediately next to removed areas get a short
/// alpha ramp so the cut-out edge is not aliased.
enum BackgroundRemoval {
    /// Supported feather radius in pixels (per requirements: 0...3).
    static let maximumFeather = 3

    /// Default tolerance used by the panel and the one-shot action helper.
    static let defaultTolerance = 30
    static let defaultFeather = 1

    // MARK: - Plan (computed before mutation so undo can be opened first)

    /// Immutable description of the pixels that will be removed/feathered.
    struct Plan {
        fileprivate var removed: [UInt8]        // 1 = remove, per canvas pixel
        fileprivate var distance: [UInt8]       // distance to removed region (0...200)
        fileprivate var mask: [UInt8]?          // selection mask; nil = all editable
        fileprivate var region: CGRect          // editable region in image space
        fileprivate var feather: Int
        fileprivate var width: Int
        fileprivate var height: Int
    }

    // MARK: - Public entry point

    /// Removes the background of the active layer.
    ///
    /// - Parameters:
    ///   - document: document whose active layer is edited.
    ///   - tolerance: 0...255 colour distance accepted as background.
    ///   - feather: 0...3 px alpha ramp on the retained edge.
    /// - Returns: number of pixels that became transparent (0 when nothing was
    ///   removed / layer locked / no active layer). The edit is one undo step.
    @discardableResult
    static func removeBackground(document: Document, tolerance: Int, feather: Int) -> Int {
        guard let layer = document.activeLayer, !layer.isLocked else { return 0 }
        let selection = document.selection.flatMap { $0.isEmpty ? nil : $0 }
        let raster = layer.raster
        guard let plan = makePlan(in: raster, selection: selection,
                                  tolerance: tolerance, feather: feather),
              let changeBounds = changedRegion(for: plan, in: raster) else { return 0 }

        // Snapshot before mutating so Cmd+Z restores exactly these pixels.
        let pending = document.beginUndo(named: "Remove Background", rects: [changeBounds])
        let removed = apply(plan, to: raster)
        document.commitUndo(pending)
        document.notifyChange(changeBounds)
        return removed
    }

    // MARK: - Algorithm: plan

    /// Computes the removal plan without mutating the raster. Exposed for the
    /// live preview and for headless tests.
    static func makePlan(in raster: Raster, selection: SelectionModel?,
                         tolerance: Int, feather: Int) -> Plan? {
        let w = raster.width
        let h = raster.height
        guard w > 0, h > 0 else { return nil }
        let canvasRect = CGRect(x: 0, y: 0, width: w, height: h)

        let region = (selection?.bounds.intersection(canvasRect) ?? canvasRect).integral
        guard region.width >= 1, region.height >= 1 else { return nil }
        let x0 = Int(region.minX), x1 = Int(region.maxX)
        let y0 = Int(region.minY), y1 = Int(region.maxY)
        guard x0 >= 0, y0 >= 0, x1 <= w, y1 <= h else { return nil }

        let tol = max(0, min(255, tolerance))
        let featherRadius = max(0, min(maximumFeather, feather))

        // Freeform selections need a per-pixel mask; rectangular selections are
        // already fully described by `region`.
        var mask: [UInt8]? = nil
        if let sel = selection, sel.mask != nil {
            var bytes = [UInt8](repeating: 0, count: w * h)
            for y in y0..<y1 {
                for x in x0..<x1 where sel.contains(CGPoint(x: CGFloat(x) + 0.5,
                                                            y: CGFloat(y) + 0.5)) {
                    bytes[y * w + x] = 1
                }
            }
            mask = bytes
        }

        func editable(_ x: Int, _ y: Int) -> Bool {
            guard x >= x0, x < x1, y >= y0, y < y1 else { return false }
            guard let mask else { return true }
            return mask[y * w + x] != 0
        }

        // 1. Seeds: image edges when unrestricted, otherwise the selection
        //    boundary (so a selected background region is processed from its
        //    own edge, while nothing outside the selection is touched).
        var seeds: [Int] = []
        if selection == nil {
            for x in 0..<w {
                seeds.append(x)
                seeds.append((h - 1) * w + x)
            }
            for y in 0..<h {
                seeds.append(y * w)
                seeds.append(y * w + (w - 1))
            }
        } else {
            for y in y0..<y1 {
                for x in x0..<x1 where editable(x, y) {
                    let onCanvasEdge = x == 0 || y == 0 || x == w - 1 || y == h - 1
                    let boundary = !editable(x - 1, y) || !editable(x + 1, y) ||
                                   !editable(x, y - 1) || !editable(x, y + 1)
                    if onCanvasEdge || boundary { seeds.append(y * w + x) }
                }
            }
        }
        guard !seeds.isEmpty else { return nil }

        // 2. Scanline flood fill from every seed, matching each seed's colour
        //    within tolerance. Pixels already claimed by another flood are
        //    skipped, which keeps multi-coloured backgrounds (sky + wall) safe.
        var removed = [UInt8](repeating: 0, count: w * h)

        func matches(_ c: PixelColor, _ target: PixelColor) -> Bool {
            if tol <= 0 { return c == target }
            return abs(Int(c.r) - Int(target.r)) <= tol &&
                   abs(Int(c.g) - Int(target.g)) <= tol &&
                   abs(Int(c.b) - Int(target.b)) <= tol &&
                   abs(Int(c.a) - Int(target.a)) <= tol
        }

        var stack = seeds
        while let seedIndex = stack.popLast() {
            if removed[seedIndex] != 0 { continue }
            let sy = seedIndex / w
            let sx = seedIndex % w
            guard editable(sx, sy) else { continue }
            let target = raster.getPixel(sx, sy)

            var x = sx
            while x >= x0, removed[sy * w + x] == 0, editable(x, sy),
                  matches(raster.getPixel(x, sy), target) {
                x -= 1
            }
            x += 1
            var spanUp = false
            var spanDown = false
            while x < x1, removed[sy * w + x] == 0, editable(x, sy),
                  matches(raster.getPixel(x, sy), target) {
                let idx = sy * w + x
                removed[idx] = 1
                if sy > y0 {
                    let up = (sy - 1) * w + x
                    let upOK = removed[up] == 0 && editable(x, sy - 1) &&
                               matches(raster.getPixel(x, sy - 1), target)
                    if upOK {
                        if !spanUp { stack.append(up); spanUp = true }
                    } else {
                        spanUp = false
                    }
                }
                if sy < y1 - 1 {
                    let down = (sy + 1) * w + x
                    let downOK = removed[down] == 0 && editable(x, sy + 1) &&
                                 matches(raster.getPixel(x, sy + 1), target)
                    if downOK {
                        if !spanDown { stack.append(down); spanDown = true }
                    } else {
                        spanDown = false
                    }
                }
                x += 1
            }
        }

        // 3. Distance transform (1-1-1 chamfer) from removed pixels into the
        //    retained area; used only for the feather ramp.
        var distance = [UInt8](repeating: 200, count: w * h)
        if featherRadius > 0 {
            for i in 0..<(w * h) where removed[i] != 0 { distance[i] = 0 }
            let cap: UInt8 = UInt8(featherRadius + 1)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    var d = distance[i]
                    if d == 0 { continue }
                    if x > 0 { d = min(d, distance[i - 1] &+ 1) }
                    if y > 0 {
                        d = min(d, distance[i - w] &+ 1)
                        if x > 0 { d = min(d, distance[i - w - 1] &+ 1) }
                        if x < w - 1 { d = min(d, distance[i - w + 1] &+ 1) }
                    }
                    distance[i] = min(d, cap)
                }
            }
            for y in stride(from: h - 1, through: 0, by: -1) {
                for x in stride(from: w - 1, through: 0, by: -1) {
                    let i = y * w + x
                    var d = distance[i]
                    if d == 0 { continue }
                    if x < w - 1 { d = min(d, distance[i + 1] &+ 1) }
                    if y < h - 1 {
                        d = min(d, distance[i + w] &+ 1)
                        if x < w - 1 { d = min(d, distance[i + w + 1] &+ 1) }
                        if x > 0 { d = min(d, distance[i + w - 1] &+ 1) }
                    }
                    distance[i] = min(d, cap)
                }
            }
        }

        return Plan(removed: removed, distance: distance, mask: mask, region: region,
                    feather: featherRadius, width: w, height: h)
    }

    /// Bounding rect of pixels the plan will visibly change, or nil when the
    /// removal is a no-op (used for undo snapshot bounds and change regions).
    static func changedRegion(for plan: Plan, in raster: Raster) -> CGRect? {
        let w = plan.width
        let x0 = Int(plan.region.minX), x1 = Int(plan.region.maxX)
        let y0 = Int(plan.region.minY), y1 = Int(plan.region.maxY)
        let data = raster.data
        let stride = raster.stride
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in y0..<y1 {
            for x in x0..<x1 {
                let idx = y * w + x
                if let mask = plan.mask, mask[idx] == 0 { continue }
                // Alpha byte lives at offset +3 in the RGBA8 storage.
                let alpha = data[y * stride + x * PixelFormat.bytesPerPixel + 3]
                guard alpha > 0 else { continue }
                let changes = plan.removed[idx] != 0 ||
                    (plan.feather > 0 && plan.distance[idx] <= UInt8(plan.feather))
                guard changes else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1),
                      height: CGFloat(maxY - minY + 1))
    }

    // MARK: - Algorithm: apply

    /// Applies a plan to the raster and returns the number of removed pixels.
    @discardableResult
    static func apply(_ plan: Plan, to raster: Raster) -> Int {
        let w = plan.width
        let x0 = Int(plan.region.minX), x1 = Int(plan.region.maxX)
        let y0 = Int(plan.region.minY), y1 = Int(plan.region.maxY)
        let data = raster.data
        let stride = raster.stride
        let featherRadius = plan.feather
        var removedCount = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let idx = y * w + x
                if let mask = plan.mask, mask[idx] == 0 { continue }
                let i = y * stride + x * PixelFormat.bytesPerPixel
                if plan.removed[idx] != 0 {
                    if data[i + 3] != 0 { removedCount += 1 }
                    data[i] = 0
                    data[i + 1] = 0
                    data[i + 2] = 0
                    data[i + 3] = 0
                } else if featherRadius > 0, data[i + 3] != 0,
                          plan.distance[idx] <= UInt8(featherRadius) {
                    // Soften only the retained edge: scale the premultiplied
                    // channels together so the result stays valid premultiplied
                    // RGBA.
                    let scale = Double(plan.distance[idx]) / Double(featherRadius + 1)
                    data[i] = UInt8((Double(data[i]) * scale).rounded())
                    data[i + 1] = UInt8((Double(data[i + 1]) * scale).rounded())
                    data[i + 2] = UInt8((Double(data[i + 2]) * scale).rounded())
                    data[i + 3] = UInt8((Double(data[i + 3]) * scale).rounded())
                }
            }
        }
        return removedCount
    }

    // MARK: - Live preview (panel)/headless helper

    /// Builds the cached, downscaled copy of the layer used by the panel preview.
    /// Called once when the panel opens so slider changes never re-render the
    /// full-resolution layer.
    static func previewBase(for layer: Layer, maxDimension: CGFloat = 250) -> Raster? {
        guard let rendered = layer.renderedImage() else { return nil }
        let full = Raster.from(cgImage: rendered)
        guard full.width > 0, full.height > 0 else { return nil }
        let scale = min(1, maxDimension / CGFloat(max(full.width, full.height)))
        let tw = max(1, Int((CGFloat(full.width) * scale).rounded()))
        let th = max(1, Int((CGFloat(full.height) * scale).rounded()))
        return full.resized(to: tw, newHeight: th)
    }

    /// Renders a small "after removal" thumbnail from a cached preview base.
    /// Runs the real algorithm on the downscaled copy; selection is applied only
    /// when the user presses Apply, so the preview ignores it by design.
    static func previewImage(from base: Raster, tolerance: Int, feather: Int) -> NSImage? {
        let small = base.snapshot()
        if let plan = makePlan(in: small, selection: nil, tolerance: tolerance, feather: feather) {
            _ = apply(plan, to: small)
        }
        return imageOnCheckerboard(small.makeImage())
    }

    /// Convenience: builds the base and renders one preview image.
    static func previewImage(for layer: Layer, tolerance: Int, feather: Int,
                             maxDimension: CGFloat = 250) -> NSImage? {
        guard let base = previewBase(for: layer, maxDimension: maxDimension) else { return nil }
        return previewImage(from: base, tolerance: tolerance, feather: feather)
    }

    /// Composites an image over the classic transparency checkerboard.
    private static func imageOnCheckerboard(_ cgImage: CGImage?) -> NSImage? {
        guard let cgImage else { return nil }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(size: size, flipped: false) { rect in
            let cell: CGFloat = 8
            NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor(calibratedWhite: 0.80, alpha: 1).setFill()
            var row = 0
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX + (row % 2 == 0 ? 0 : cell)
                while x < rect.maxX {
                    NSBezierPath(rect: NSRect(x: x, y: y, width: cell, height: cell)).fill()
                    x += cell * 2
                }
                y += cell
                row += 1
            }
            NSImage(cgImage: cgImage, size: size).draw(in: rect)
            return true
        }
        return image
    }
}

// MARK: - One-shot action helper for the Lead's menu/ribbon wiring

/// `@objc`-free helper so the Lead can wire a menu item / ribbon button without
/// exposing implementation details. Intentionally has no Objective-C selector
/// requirement: call it from the Lead's own `@objc` action.
enum BackgroundRemovalAction {
    /// Presents the tolerance/feather settings panel.
    /// - Parameters:
    ///   - parent: window to attach the sheet to (nil shows a standalone panel).
    ///   - document: document to edit.
    ///   - onApplied: called on the main thread with the number of removed
    ///     pixels after a successful apply (Lead can show a status message and
    ///     refresh the inspector/canvas).
    static func presentPanel(for parent: NSWindow?, document: Document,
                             onApplied: ((Int) -> Void)? = nil) {
        BackgroundRemovalPanel.present(for: parent, document: document, onApplied: onApplied)
    }

    /// Applies background removal immediately with the supplied settings
    /// (no panel). Returns the number of removed pixels.
    @discardableResult
    static func applyNow(document: Document,
                         tolerance: Int = BackgroundRemoval.defaultTolerance,
                         feather: Int = BackgroundRemoval.defaultFeather) -> Int {
        BackgroundRemoval.removeBackground(document: document, tolerance: tolerance, feather: feather)
    }
}

// MARK: - Settings panel

/// Small sheet with a tolerance slider, feather popup and a live preview.
final class BackgroundRemovalPanel: NSWindowController {
    private weak var paintingDocument: Document?
    private var tolerance: Int = BackgroundRemoval.defaultTolerance
    private var feather: Int = BackgroundRemoval.defaultFeather
    private var onApplied: ((Int) -> Void)?

    private var toleranceSlider: NSSlider!
    private var toleranceValueLabel: NSTextField!
    private var featherPopup: NSPopUpButton!
    private var previewView: NSImageView!
    private var applyButton: NSButton!
    private var statusLabel: NSTextField!
    private var selectionNote: NSTextField!
    private var previewBase: Raster?

    init(document: Document) {
        self.paintingDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Remove Background"
        super.init(window: window)
        if let layer = document.activeLayer {
            previewBase = BackgroundRemoval.previewBase(for: layer)
        }
        build()
        refreshPreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Presents the panel as a sheet on `parent` (or standalone when nil).
    static func present(for parent: NSWindow?, document: Document,
                        onApplied: ((Int) -> Void)? = nil) {
        let panel = BackgroundRemovalPanel(document: document)
        panel.onApplied = onApplied
        if let parent {
            parent.beginSheet(panel.window!) { _ in panel.close() }
        } else {
            panel.window?.center()
            panel.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: UI

    private func build() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let target = NSTextField(labelWithString: "Layer: \(paintingDocument?.activeLayer?.name ?? "—")")
        target.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        target.textColor = .secondaryLabelColor
        root.addArrangedSubview(target)

        previewView = NSImageView()
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.borderWidth = 1
        previewView.layer?.borderColor = NSColor.separatorColor.cgColor
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.widthAnchor.constraint(equalToConstant: 388).isActive = true
        previewView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        root.addArrangedSubview(previewView)

        let previewHint = NSTextField(labelWithString: "Preview (reduced size, selection applied on Apply)")
        previewHint.font = NSFont.systemFont(ofSize: 9)
        previewHint.textColor = .tertiaryLabelColor
        root.addArrangedSubview(previewHint)

        // Tolerance
        let toleranceRow = NSStackView()
        toleranceRow.orientation = .horizontal
        toleranceRow.spacing = 8
        toleranceRow.alignment = .centerY
        let toleranceTitle = NSTextField(labelWithString: "Tolerance")
        toleranceTitle.font = NSFont.systemFont(ofSize: 11)
        toleranceTitle.widthAnchor.constraint(equalToConstant: 70).isActive = true
        toleranceSlider = NSSlider(value: Double(tolerance), minValue: 0, maxValue: 255,
                                   target: self, action: #selector(toleranceChanged))
        toleranceSlider.controlSize = .small
        toleranceSlider.isContinuous = true
        toleranceSlider.translatesAutoresizingMaskIntoConstraints = false
        toleranceSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        toleranceValueLabel = NSTextField(labelWithString: "\(tolerance)")
        toleranceValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        toleranceValueLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        toleranceRow.addArrangedSubview(toleranceTitle)
        toleranceRow.addArrangedSubview(toleranceSlider)
        toleranceRow.addArrangedSubview(toleranceValueLabel)
        root.addArrangedSubview(toleranceRow)

        // Feather
        let featherRow = NSStackView()
        featherRow.orientation = .horizontal
        featherRow.spacing = 8
        featherRow.alignment = .centerY
        let featherTitle = NSTextField(labelWithString: "Feather")
        featherTitle.font = NSFont.systemFont(ofSize: 11)
        featherTitle.widthAnchor.constraint(equalToConstant: 70).isActive = true
        featherPopup = NSPopUpButton()
        featherPopup.addItems(withTitles: ["None", "1 px", "2 px", "3 px"])
        featherPopup.selectItem(at: feather)
        featherPopup.target = self
        featherPopup.action = #selector(featherChanged)
        featherRow.addArrangedSubview(featherTitle)
        featherRow.addArrangedSubview(featherPopup)
        root.addArrangedSubview(featherRow)

        selectionNote = NSTextField(labelWithString: "")
        selectionNote.font = NSFont.systemFont(ofSize: 10)
        selectionNote.textColor = .secondaryLabelColor
        root.addArrangedSubview(selectionNote)

        let info = NSTextField(wrappingLabelWithString:
            "Flood-fills the background colour from the image edges (or from the selection edge when a selection is active). The change is one undo step.")
        info.font = NSFont.systemFont(ofSize: 10)
        info.textColor = .tertiaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false
        info.widthAnchor.constraint(equalToConstant: 388).isActive = true
        root.addArrangedSubview(info)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .systemOrange
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(equalToConstant: 388).isActive = true
        root.addArrangedSubview(statusLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(NSView())
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        applyButton = NSButton(title: "Apply", target: self, action: #selector(applyTapped))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(cancel)
        buttonRow.addArrangedSubview(applyButton)
        root.addArrangedSubview(buttonRow)

        configureForDocument()
    }

    private func configureForDocument() {
        guard let doc = paintingDocument else { return }
        if let selection = doc.selection, !selection.isEmpty {
            selectionNote.stringValue = String(format: "Selection: %.0f × %.0f px (only selected pixels are edited)",
                                               selection.bounds.width, selection.bounds.height)
        } else {
            selectionNote.stringValue = "No selection: the whole layer is processed."
        }
        let locked = doc.activeLayer?.isLocked ?? true
        applyButton.isEnabled = !locked
        if locked {
            statusLabel.stringValue = "The active layer is locked. Unlock it to remove its background."
        }
    }

    // MARK: Actions

    @objc private func toleranceChanged() {
        tolerance = Int(toleranceSlider.doubleValue.rounded())
        toleranceValueLabel.stringValue = "\(tolerance)"
        refreshPreview()
    }

    @objc private func featherChanged() {
        feather = max(0, min(BackgroundRemoval.maximumFeather, featherPopup.indexOfSelectedItem))
        refreshPreview()
    }

    private func refreshPreview() {
        guard let previewBase else {
            previewView?.image = nil
            return
        }
        previewView?.image = BackgroundRemoval.previewImage(from: previewBase,
                                                            tolerance: tolerance,
                                                            feather: feather)
    }

    @objc private func applyTapped() {
        guard let doc = paintingDocument else { return }
        guard let layer = doc.activeLayer, !layer.isLocked else {
            statusLabel.stringValue = "The active layer is locked."
            return
        }
        let count = BackgroundRemoval.removeBackground(document: doc,
                                                       tolerance: tolerance,
                                                       feather: feather)
        guard count > 0 else {
            statusLabel.stringValue = "Nothing to remove at tolerance \(tolerance). Try raising it."
            return
        }
        endSheetOrClose()
        onApplied?(count)
    }

    @objc private func cancelTapped() {
        endSheetOrClose()
    }

    private func endSheetOrClose() {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            close()
        }
    }
}
