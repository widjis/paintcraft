import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Adjustment pipeline (non-destructive enhancements)
//
// SELF-TEST (manual, no UI automation available):
//  1. Layers > Adjustments… : move Brightness and confirm the live preview
//     thumbnail updates while sliding. Press "Apply adjustment": the canvas
//     updates and the entry appears under "Applied (non-destructive)".
//  2. Choose a preset (Vivid / Warm / Cool / Mono) and press "Add preset": the
//     canvas picks up the look and the chain lists the constituent adjustments.
//     Removing a chain entry or "Reset layer" restores the original.
//  3. Make a rectangular selection, tick "Apply inside selection", then apply an
//     adjustment: only pixels inside the selection change, the outside is
//     untouched, and one Cmd+Z restores it.
//  4. Same with a freeform selection (masked): only pixels inside the lasso
//     change.
//  5. Cmd+Z / Cmd+Shift+Z after applying to a selection restores/reapplies the
//     exact pixels (baked selection edits are undoable but destructive).
//
// Headless check (add to SelfTest.run() if desired):
//   let doc = Document(width: 16, height: 16)
//   doc.activeLayer!.raster.fill(.white)
//   doc.activeLayer!.raster.fill(rect: CGRect(x: 2, y: 2, width: 4, height: 4),
//                                with: PixelColor(r: 220, g: 20, b: 20))
//   doc.setSelection(SelectionModel(rect: CGRect(x: 0, y: 0, width: 8, height: 8)))
//   let ok = AdjustmentPipeline.bake([Adjustment(kind: .grayscale, amount: 1)],
//                                    into: doc, inside: doc.selection!, undoName: "Test")
//   // expected: ok == true; pixel (3,3) desaturated; pixel (10,10) still white;
//   //           doc.undo() restores the red pixel.

// MARK: - Presets

/// One-click looks built only from the existing non-destructive adjustment
/// kinds, so a preset appends to the layer's live chain (never bakes).
///
/// Note: the Core Image filter set exposed by `AdjustmentKind` has no white
/// balance/temperature filter, so Warm and Cool are honest approximations built
/// from sepia / hue rotation / saturation and contrast.
enum AdjustmentPreset: String, CaseIterable, Identifiable {
    case vivid
    case warm
    case cool
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vivid: return "Vivid"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .mono: return "Mono"
        }
    }

    var summary: String {
        switch self {
        case .vivid: return "More saturation, contrast and a light sharpen"
        case .warm: return "Sunny warmth via sepia and a hint of saturation"
        case .cool: return "Cooler, slightly desaturated with a hue shift"
        case .mono: return "High-contrast black & white"
        }
    }

    /// The adjustments appended to the layer chain when the preset is applied.
    var adjustments: [Adjustment] {
        switch self {
        case .vivid:
            return [
                Adjustment(kind: .brightnessContrast, amount: 0.03, amount2: 0.16),
                Adjustment(kind: .hueSaturation, amount: 0.0, amount2: 0.28),
                Adjustment(kind: .sharpen, amount: 0.35)
            ]
        case .warm:
            return [
                Adjustment(kind: .sepia, amount: 0.18),
                Adjustment(kind: .brightnessContrast, amount: 0.03, amount2: 0.05),
                Adjustment(kind: .hueSaturation, amount: -0.02, amount2: 0.06)
            ]
        case .cool:
            return [
                Adjustment(kind: .hueSaturation, amount: 0.04, amount2: -0.05),
                Adjustment(kind: .brightnessContrast, amount: -0.01, amount2: 0.06),
                Adjustment(kind: .exposure, amount: 0.02)
            ]
        case .mono:
            return [
                Adjustment(kind: .grayscale, amount: 1.0),
                Adjustment(kind: .brightnessContrast, amount: 0.02, amount2: 0.12)
            ]
        }
    }
}

// MARK: - Pipeline

/// Applies a chain of Core Image adjustments to a layer raster. Called every
/// time a layer renders, so results stay live when sliders move.
enum AdjustmentPipeline {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false,
                                                       .cacheIntermediates: false])

    /// Applies enabled adjustments and returns the composited image at native size.
    /// This API is relied on by `Layer.renderedImage()` and must stay stable.
    static func apply(_ adjustments: [Adjustment], to raster: Raster) -> CGImage? {
        guard let base = raster.makeImage() else { return nil }
        let enabled = adjustments.filter { $0.enabled }
        guard !enabled.isEmpty else { return base }

        var image = CIImage(cgImage: base)
        let extent = image.extent
        for adj in enabled {
            image = applyOne(adj, to: image)
            image = image.cropped(to: extent)
        }
        guard let cg = ciContext.createCGImage(image, from: extent, format: .RGBA8,
                                               colorSpace: raster.colorSpace) else { return base }
        return cg
    }

    private static func applyOne(_ adj: Adjustment, to input: CIImage) -> CIImage {
        switch adj.kind {
        case .brightnessContrast:
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.brightness = Float(adj.amount)
            f.contrast = Float(1.0 + adj.amount2)
            f.saturation = 1.0
            return f.outputImage ?? input

        case .hueSaturation:
            // CIHueAdjust rotates hue; CIColorControls scales saturation.
            let hue = CIFilter.hueAdjust()
            hue.inputImage = input
            hue.angle = Float(adj.amount * .pi)
            let saturated = hue.outputImage ?? input
            let f = CIFilter.colorControls()
            f.inputImage = saturated
            f.saturation = Float(1.0 + adj.amount2)
            f.brightness = 0
            f.contrast = 1.0
            return f.outputImage ?? saturated

        case .exposure:
            let f = CIFilter.exposureAdjust()
            f.inputImage = input
            f.ev = Float(adj.amount * 4.0)
            return f.outputImage ?? input

        case .grayscale:
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.saturation = Float(1.0 - adj.amount)
            f.brightness = 0
            f.contrast = 1.0
            return f.outputImage ?? input

        case .sepia:
            let f = CIFilter.sepiaTone()
            f.inputImage = input
            f.intensity = Float(adj.amount)
            return f.outputImage ?? input

        case .vignette:
            let f = CIFilter.vignette()
            f.inputImage = input
            f.intensity = Float(adj.amount * 3.0)
            f.radius = Float(adj.amount2 > 0 ? adj.amount2 * 2 : 1.5)
            return f.outputImage ?? input

        case .sharpen:
            let f = CIFilter.sharpenLuminance()
            f.inputImage = input
            f.sharpness = Float(adj.amount * 2.0)
            return f.outputImage ?? input

        case .gaussianBlur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = input
            f.radius = Float(adj.amount)
            return (f.outputImage ?? input).cropped(to: input.extent)
        }
    }

    /// Renders a raster through a temporary single adjustment, used for live
    /// preview before committing to the layer.
    static func preview(_ adj: Adjustment, raster: Raster) -> CGImage? {
        apply([adj], to: raster)
    }

    /// Returns the adjustments for a preset (fresh Adjustment values each call).
    static func presetAdjustments(_ preset: AdjustmentPreset) -> [Adjustment] {
        preset.adjustments
    }

    // MARK: - Apply to selection (bake)

    /// Non-destructive apply: appends the adjustments to the layer chain.
    /// Destructive apply inside a selection: bakes the filtered pixels into the
    /// raster (undoable) so only the selected area changes.
    ///
    /// - Parameters:
    ///   - adjustments: adjustments to apply (must contain at least one enabled).
    ///   - document: document whose active layer is edited.
    ///   - selection: when non-nil (and non-empty) the effect is baked inside the
    ///     selection; when nil the chain is extended (non-destructive).
    ///   - undoName: title shown for the undo step.
    /// - Returns: true when something was applied.
    @discardableResult
    static func apply(_ adjustments: [Adjustment], to document: Document,
                      inside selection: SelectionModel?, undoName: String) -> Bool {
        guard adjustments.contains(where: { $0.enabled }) else { return false }
        if let selection, !selection.isEmpty {
            return bake(adjustments, into: document, inside: selection, undoName: undoName)
        }
        guard let layer = document.activeLayer, !layer.isLocked else { return false }
        layer.adjustments.append(contentsOf: adjustments)
        layer.raster.bitmapContext.flush()
        document.markChanged()
        return true
    }

    /// Bakes `adjustments` into the active layer raster, clipped to `selection`,
    /// as a single undo step.
    ///
    /// Implementation note: the bake is computed from the raw raster (not from
    /// the layer's rendered chain) so that existing adjustments are not applied
    /// twice when the layer renders again. With a non-empty chain the visual
    /// order is therefore "new effect, then existing chain" inside the selection.
    @discardableResult
    static func bake(_ adjustments: [Adjustment], into document: Document,
                     inside selection: SelectionModel, undoName: String) -> Bool {
        guard let layer = document.activeLayer, !layer.isLocked else { return false }
        let enabled = adjustments.filter { $0.enabled }
        guard !enabled.isEmpty else { return false }
        let raster = layer.raster
        let region = selection.bounds.intersection(raster.bounds).integral
        guard region.width >= 1, region.height >= 1 else { return false }
        guard let adjustedCG = apply(enabled, to: raster) else { return false }
        let adjusted = Raster.from(cgImage: adjustedCG)
        guard adjusted.width == raster.width, adjusted.height == raster.height else { return false }

        let pending = document.beginUndo(named: undoName, rects: [region])
        copyPixels(from: adjusted, into: raster, inside: selection, region: region)
        document.commitUndo(pending)
        raster.bitmapContext.flush()
        document.notifyChange(region)
        return true
    }

    /// Copies the selected region of `source` over `destination` (raw bytes, so
    /// alpha is replaced rather than composited).
    private static func copyPixels(from source: Raster, into destination: Raster,
                                   inside selection: SelectionModel, region: CGRect) {
        let x0 = Int(region.minX), x1 = Int(region.maxX)
        let y0 = Int(region.minY), y1 = Int(region.maxY)
        let bpp = PixelFormat.bytesPerPixel
        let hasMask = selection.mask != nil
        for y in y0..<y1 {
            let srcRow = y * source.stride
            let dstRow = y * destination.stride
            for x in x0..<x1 {
                if hasMask && !selection.contains(CGPoint(x: CGFloat(x) + 0.5,
                                                          y: CGFloat(y) + 0.5)) {
                    continue
                }
                let s = srcRow + x * bpp
                let d = dstRow + x * bpp
                destination.data[d] = source.data[s]
                destination.data[d + 1] = source.data[s + 1]
                destination.data[d + 2] = source.data[s + 2]
                destination.data[d + 3] = source.data[s + 3]
            }
        }
    }

    // MARK: - Preview helpers

    /// Builds a downscaled raster of the layer's current appearance, used for
    /// the panel's live preview thumbnail.
    static func thumbnail(of layer: Layer, maxWidth: CGFloat, maxHeight: CGFloat) -> Raster? {
        guard let rendered = layer.renderedImage() else { return nil }
        let base = Raster.from(cgImage: rendered)
        guard base.width > 0, base.height > 0 else { return nil }
        let scale = min(1, min(maxWidth / CGFloat(base.width), maxHeight / CGFloat(base.height)))
        let width = max(1, Int((CGFloat(base.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(base.height) * scale).rounded()))
        return base.resized(to: width, newHeight: height)
    }
}

// MARK: - Adjustments panel

/// Sheet with a live preview, single adjustments, one-click presets, an
/// optional "apply inside selection" mode and the non-destructive chain list.
final class AdjustmentsPanel: NSWindowController {
    var onChanged: (() -> Void)?

    private weak var paintingDocument: Document?
    private var layer: Layer?
    private var kindPopup: NSPopUpButton!
    private var amountSlider: NSSlider!
    private var amount2Slider: NSSlider!
    private var amountLabel: NSTextField!
    private var amount2Label: NSTextField!
    private var amountValueLabel: NSTextField!
    private var amount2ValueLabel: NSTextField!
    private var amount2Row: NSView!
    private var appliedList: NSStackView!
    private var presetPopup: NSPopUpButton!
    private var insideSelectionCheckbox: NSButton!
    private var selectionInfo: NSTextField!
    private var previewView: NSImageView!
    private var previewBase: Raster?
    private var applyButton: NSButton!
    private var resetButton: NSButton!
    private var statusLabel: NSTextField!
    private var currentKind: AdjustmentKind = .brightnessContrast

    private let previewMaxWidth: CGFloat = 268
    private let previewMaxHeight: CGFloat = 168

    init(document: Document) {
        self.paintingDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Adjustments"
        super.init(window: window)
        self.layer = document.activeLayer
        build()
        syncSlidersForKind()
        rebuildPreviewBase()
        refreshPreview()
        updateSelectionUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Presents the panel as a sheet on `parent` (standalone when nil).
    static func present(for parent: NSWindow?, document: Document,
                        onChanged: @escaping () -> Void) {
        let panel = AdjustmentsPanel(document: document)
        panel.onChanged = onChanged
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
        root.spacing = 9
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let target = NSTextField(labelWithString: "Layer: \(layer?.name ?? "—")")
        target.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        target.textColor = .secondaryLabelColor
        root.addArrangedSubview(target)

        // Live preview thumbnail.
        previewView = NSImageView()
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.borderWidth = 1
        previewView.layer?.borderColor = NSColor.separatorColor.cgColor
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.widthAnchor.constraint(equalToConstant: previewMaxWidth).isActive = true
        previewView.heightAnchor.constraint(equalToConstant: previewMaxHeight).isActive = true
        root.addArrangedSubview(previewView)

        let previewHint = NSTextField(labelWithString: "Live preview (current slider settings)")
        previewHint.font = NSFont.systemFont(ofSize: 9)
        previewHint.textColor = .tertiaryLabelColor
        root.addArrangedSubview(previewHint)

        // Kind / sliders.
        kindPopup = NSPopUpButton()
        kindPopup.addItems(withTitles: AdjustmentKind.allCases.map { $0.title })
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        root.addArrangedSubview(kindPopup)

        let a1 = NSStackView()
        a1.orientation = .horizontal
        a1.spacing = 8
        a1.alignment = .centerY
        amountLabel = NSTextField(labelWithString: "Amount")
        amountLabel.font = NSFont.systemFont(ofSize: 10)
        amountLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        amountSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: self, action: #selector(amountChanged))
        amountSlider.controlSize = .small
        amountSlider.isContinuous = true
        amountSlider.translatesAutoresizingMaskIntoConstraints = false
        amountSlider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        amountValueLabel = NSTextField(labelWithString: "0.00")
        amountValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        amountValueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        a1.addArrangedSubview(amountLabel)
        a1.addArrangedSubview(amountSlider)
        a1.addArrangedSubview(amountValueLabel)
        root.addArrangedSubview(a1)

        let a2 = NSStackView()
        a2.orientation = .horizontal
        a2.spacing = 8
        a2.alignment = .centerY
        amount2Label = NSTextField(labelWithString: "Amount 2")
        amount2Label.font = NSFont.systemFont(ofSize: 10)
        amount2Label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        amount2Slider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: self, action: #selector(amount2Changed))
        amount2Slider.controlSize = .small
        amount2Slider.isContinuous = true
        amount2Slider.translatesAutoresizingMaskIntoConstraints = false
        amount2Slider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        amount2ValueLabel = NSTextField(labelWithString: "0.00")
        amount2ValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        amount2ValueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        a2.addArrangedSubview(amount2Label)
        a2.addArrangedSubview(amount2Slider)
        a2.addArrangedSubview(amount2ValueLabel)
        amount2Row = a2
        root.addArrangedSubview(a2)

        // Apply / reset row.
        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.spacing = 8
        applyButton = NSButton(title: "Apply adjustment", target: self, action: #selector(applyAdjustment))
        applyButton.bezelStyle = .rounded
        resetButton = NSButton(title: "Reset layer", target: self, action: #selector(resetLayer))
        resetButton.bezelStyle = .rounded
        addRow.addArrangedSubview(applyButton)
        addRow.addArrangedSubview(resetButton)
        root.addArrangedSubview(addRow)

        // Preset row.
        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.spacing = 8
        presetRow.alignment = .centerY
        let presetTitle = NSTextField(labelWithString: "Preset")
        presetTitle.font = NSFont.systemFont(ofSize: 10)
        presetTitle.widthAnchor.constraint(equalToConstant: 70).isActive = true
        presetPopup = NSPopUpButton()
        presetPopup.addItems(withTitles: AdjustmentPreset.allCases.map { $0.title })
        presetPopup.selectItem(at: 0)
        presetPopup.toolTip = AdjustmentPreset.allCases.map { "\($0.title): \($0.summary)" }
            .joined(separator: "\n")
        let addPreset = NSButton(title: "Add preset", target: self, action: #selector(addPresetTapped))
        addPreset.bezelStyle = .rounded
        presetRow.addArrangedSubview(presetTitle)
        presetRow.addArrangedSubview(presetPopup)
        presetRow.addArrangedSubview(addPreset)
        root.addArrangedSubview(presetRow)

        // Selection mode.
        insideSelectionCheckbox = NSButton(checkboxWithTitle: "Apply inside selection",
                                           target: self, action: #selector(insideSelectionToggled))
        insideSelectionCheckbox.font = NSFont.systemFont(ofSize: 11)
        root.addArrangedSubview(insideSelectionCheckbox)
        selectionInfo = NSTextField(labelWithString: "")
        selectionInfo.font = NSFont.systemFont(ofSize: 9)
        selectionInfo.textColor = .tertiaryLabelColor
        selectionInfo.translatesAutoresizingMaskIntoConstraints = false
        selectionInfo.widthAnchor.constraint(equalToConstant: previewMaxWidth).isActive = true
        root.addArrangedSubview(selectionInfo)

        // Non-destructive chain list.
        let listTitle = NSTextField(labelWithString: "Applied (non-destructive)")
        listTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        listTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(listTitle)
        appliedList = NSStackView()
        appliedList.orientation = .vertical
        appliedList.alignment = .leading
        appliedList.spacing = 3
        root.addArrangedSubview(appliedList)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 9)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(equalToConstant: previewMaxWidth).isActive = true
        root.addArrangedSubview(statusLabel)

        let close = NSButton(title: "Done", target: self, action: #selector(done))
        close.keyEquivalent = "\r"
        close.bezelStyle = .rounded
        let closeRow = NSStackView()
        closeRow.orientation = .horizontal
        closeRow.addArrangedSubview(NSView())
        closeRow.addArrangedSubview(close)
        root.addArrangedSubview(closeRow)

        rebuildAppliedList()
    }

    private func syncSlidersForKind() {
        let k = currentKind
        amountLabel.stringValue = k == .brightnessContrast ? "Brightness" : "Amount"
        amountSlider.minValue = k.amountRange.lowerBound
        amountSlider.maxValue = k.amountRange.upperBound
        amountSlider.doubleValue = k.defaultAmounts.0
        amount2Label.stringValue = k == .brightnessContrast ? "Contrast" : "Amount 2"
        amount2Slider.isEnabled = (k == .brightnessContrast || k == .hueSaturation || k == .vignette)
        amount2Row.isHidden = !amount2Slider.isEnabled
        amount2Slider.doubleValue = k.defaultAmounts.1
        updateValueLabels()
    }

    private func updateValueLabels() {
        amountValueLabel.stringValue = String(format: "%.2f", amountSlider.doubleValue)
        amount2ValueLabel.stringValue = String(format: "%.2f", amount2Slider.doubleValue)
    }

    private func currentAdjustment() -> Adjustment {
        var adj = Adjustment(kind: currentKind, amount: amountSlider.doubleValue,
                             amount2: amount2Slider.doubleValue)
        adj.enabled = true
        return adj
    }

    private func updateSelectionUI() {
        guard let doc = paintingDocument else { return }
        let selection = doc.selection.flatMap { $0.isEmpty ? nil : $0 }
        let hasSelection = selection != nil
        insideSelectionCheckbox.isEnabled = hasSelection && !(layer?.isLocked ?? true)
        if !hasSelection {
            insideSelectionCheckbox.state = .off
            selectionInfo.stringValue = "No selection: adjustments extend the live chain (non-destructive)."
        } else if let selection {
            insideSelectionCheckbox.state = .on
            selectionInfo.stringValue = String(format:
                "Selection %.0f × %.0f px: applies only inside it, baked as one undo step.",
                selection.bounds.width, selection.bounds.height)
        }
        let locked = layer?.isLocked ?? true
        applyButton.isEnabled = !locked
        resetButton.isEnabled = !locked
        if locked {
            statusLabel.stringValue = "The active layer is locked."
        }
    }

    // MARK: Preview

    private func rebuildPreviewBase() {
        guard let layer else {
            previewBase = nil
            return
        }
        previewBase = AdjustmentPipeline.thumbnail(of: layer,
                                                   maxWidth: previewMaxWidth,
                                                   maxHeight: previewMaxHeight)
    }

    private func refreshPreview() {
        guard let base = previewBase else {
            previewView?.image = nil
            return
        }
        let image = AdjustmentPipeline.preview(currentAdjustment(), raster: base)
            ?? base.makeImage()
        guard let image else {
            previewView?.image = nil
            return
        }
        previewView?.image = NSImage(cgImage: image,
                                     size: NSSize(width: image.width, height: image.height))
    }

    // MARK: Actions

    @objc private func kindChanged() {
        if AdjustmentKind.allCases.indices.contains(kindPopup.indexOfSelectedItem) {
            currentKind = AdjustmentKind.allCases[kindPopup.indexOfSelectedItem]
            syncSlidersForKind()
            refreshPreview()
        }
    }

    @objc private func amountChanged() {
        updateValueLabels()
        refreshPreview()
    }

    @objc private func amount2Changed() {
        updateValueLabels()
        refreshPreview()
    }

    @objc private func insideSelectionToggled() {
        // No pixel change; just reflects the mode used by Apply.
    }

    private func applyOrExtend(_ adjustments: [Adjustment], undoName: String) {
        guard let doc = paintingDocument, let layer, !layer.isLocked else { return }
        guard adjustments.contains(where: { $0.enabled }) else { return }
        let useSelection = insideSelectionCheckbox.state == .on
        let selection = useSelection ? doc.selection.flatMap { $0.isEmpty ? nil : $0 } : nil
        let changed = AdjustmentPipeline.apply(adjustments, to: doc, inside: selection,
                                               undoName: undoName)
        guard changed else { return }
        if selection == nil {
            statusLabel.stringValue = "Added to the live chain: \(adjustments.count) adjustment(s)."
        } else {
            statusLabel.stringValue = "Baked inside the selection (Cmd+Z to undo)."
        }
        onChanged?()
        rebuildPreviewBase()
        rebuildAppliedList()
        refreshPreview()
    }

    @objc private func applyAdjustment() {
        applyOrExtend([currentAdjustment()], undoName: currentKind.title)
    }

    @objc private func addPresetTapped() {
        let index = presetPopup.indexOfSelectedItem
        guard AdjustmentPreset.allCases.indices.contains(index) else { return }
        let preset = AdjustmentPreset.allCases[index]
        applyOrExtend(preset.adjustments, undoName: "Preset: \(preset.title)")
    }

    @objc private func resetLayer() {
        guard let layer, !layer.isLocked else { return }
        layer.adjustments.removeAll()
        layer.raster.bitmapContext.flush()
        paintingDocument?.markChanged()
        statusLabel.stringValue = "Live adjustment chain cleared (selection bakes remain)."
        onChanged?()
        rebuildPreviewBase()
        refreshPreview()
        rebuildAppliedList()
    }

    private func rebuildAppliedList() {
        for v in appliedList.arrangedSubviews { v.removeFromSuperview() }
        guard let layer, !layer.adjustments.isEmpty else {
            let empty = NSTextField(labelWithString: "None")
            empty.font = NSFont.systemFont(ofSize: 10)
            empty.textColor = .tertiaryLabelColor
            appliedList.addArrangedSubview(empty)
            return
        }
        for (i, adj) in layer.adjustments.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let label = NSTextField(labelWithString: "\(adj.kind.title) (\(String(format: "%.2f", adj.amount)))")
            label.font = NSFont.systemFont(ofSize: 10)
            let remove = NSButton(title: "✕", target: self, action: #selector(removeAdjustment(_:)))
            remove.tag = i
            remove.bezelStyle = .inline
            remove.font = NSFont.systemFont(ofSize: 9)
            row.addArrangedSubview(label)
            row.addArrangedSubview(remove)
            appliedList.addArrangedSubview(row)
        }
    }

    @objc private func removeAdjustment(_ sender: NSButton) {
        guard let layer, !layer.isLocked,
              layer.adjustments.indices.contains(sender.tag) else { return }
        layer.adjustments.remove(at: sender.tag)
        paintingDocument?.markChanged()
        onChanged?()
        rebuildPreviewBase()
        refreshPreview()
        rebuildAppliedList()
    }

    @objc private func done() {
        window?.sheetParent?.endSheet(window!) ?? close()
    }
}
