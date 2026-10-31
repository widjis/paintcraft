import AppKit

// MARK: - Small building blocks

/// A label that lets clicks fall through to its container (layer rows select on
/// click, so text inside them must not swallow the event).
final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One-pixel horizontal divider inside the inspector.
final class InspectorDivider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        Theme.inspectorBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// A 32x32 layer preview: checkerboard for transparency plus the layer bitmap
/// scaled to fit.
final class LayerThumbnailView: NSView {
    private weak var paintLayer: Layer?

    init(layer: Layer) {
        self.paintLayer = layer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Theme.Metrics.layerThumbnail).isActive = true
        heightAnchor.constraint(equalToConstant: Theme.Metrics.layerThumbnail).isActive = true
        toolTip = layer.name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        Theme.roundedPath(rect, radius: 3).addClip()
        Theme.drawCheckerboard(in: rect)
        if let paintLayer, let image = paintLayer.renderedImage() {
            let available = rect.insetBy(dx: 1, dy: 1)
            let scale = min(available.width / CGFloat(image.width),
                            available.height / CGFloat(image.height))
            let size = NSSize(width: CGFloat(image.width) * scale,
                              height: CGFloat(image.height) * scale)
            let target = NSRect(x: rect.midX - size.width / 2,
                                y: rect.midY - size.height / 2,
                                width: size.width, height: size.height)
            if let ctx = NSGraphicsContext.current?.cgContext {
                CGImageDrawing.drawUpright(image, in: target, into: ctx)
            }
        }
        NSColor.separatorColor.setStroke()
        let border = Theme.roundedPath(rect, radius: 3)
        border.lineWidth = 1
        border.stroke()
    }
}

/// A miniature swatch used by the "recent colours" strip.
final class RecentColorSwatchView: NSView {
    let color: PixelColor
    var onClick: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(color: PixelColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        toolTip = color.hexString
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        color.nsColor.setFill()
        rect.fill()
        if color.a < 255 {
            Theme.drawCheckerboard(in: rect)
            color.nsColor.setFill()
            rect.fill()
        }
        let border = NSBezierPath(rect: rect)
        border.lineWidth = hovered ? 2 : 1
        (hovered ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Inspector panel (Layers + History + Colors)

final class InspectorPanel: NSView {
    var document: Document
    var onLayerSelected: ((Int) -> Void)?
    var onDocumentChanged: (() -> Void)?

    private var segmented: NSSegmentedControl!
    private let contentScroll = NSScrollView()
    private var contentContainer: FlippedView!
    private var layersStack: NSStackView!
    private var historyStack: NSStackView!
    private var colorsStack: NSStackView!
    private var installedStack: NSStackView?
    private var stackConstraints: [NSLayoutConstraint] = []
    private var currentTab = 0

    // Colors tab widgets kept for lightweight refreshes.
    private var swatchPair: PaintSwatchPairView?
    private var paletteView: PaintPaletteGridView?
    private var hexField: NSTextField?
    private var editingSecondary = false
    private var colorsDirty = true

    private static let inset = Theme.Metrics.inspectorInset

    init(document: Document) {
        self.document = document
        super.init(frame: .zero)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(colorsDidChange),
                                               name: .paintCraftColorsDidChange, object: nil)
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Chrome

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // Design target: never narrower than 260 pt.
        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metrics.inspectorMinWidth)
        minWidth.priority = .required
        minWidth.isActive = true

        segmented = NSSegmentedControl(labels: ["Layers", "History", "Colors"],
                                       trackingMode: .selectOne, target: self,
                                       action: #selector(segmentChanged))
        segmented.selectedSegment = 0
        segmented.controlSize = .small
        segmented.segmentStyle = .rounded
        segmented.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segmented)

        contentScroll.hasVerticalScroller = true
        contentScroll.scrollerStyle = .overlay
        contentScroll.autohidesScrollers = true
        contentScroll.drawsBackground = false
        contentScroll.borderType = .noBorder
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentScroll)

        contentContainer = FlippedView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.documentView = contentContainer
        let fillHeight = contentContainer.heightAnchor.constraint(equalTo: contentScroll.contentView.heightAnchor)
        fillHeight.priority = NSLayoutConstraint.Priority(250)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: contentScroll.contentView.leadingAnchor),
            contentContainer.topAnchor.constraint(equalTo: contentScroll.contentView.topAnchor),
            contentContainer.widthAnchor.constraint(equalTo: contentScroll.contentView.widthAnchor),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualTo: contentScroll.contentView.heightAnchor),
            fillHeight
        ])

        layersStack = makeStack()
        historyStack = makeStack()
        colorsStack = makeStack()

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            segmented.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            segmented.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentScroll.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            contentScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        rebuildLayers()
        rebuildHistory()
        install(layersStack)
    }

    private func makeStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: Self.inset, bottom: 12, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func install(_ stack: NSStackView) {
        if installedStack === stack, stack.superview != nil { return }
        if let old = installedStack {
            NSLayoutConstraint.deactivate(stackConstraints)
            old.removeFromSuperview()
        }
        stackConstraints = []
        contentContainer.addSubview(stack)
        let constraints = [
            stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor)
        ]
        NSLayoutConstraint.activate(constraints)
        stackConstraints = constraints
        installedStack = stack
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.inspectorBackground.setFill()
        bounds.fill()
    }

    @objc private func segmentChanged() {
        currentTab = segmented.selectedSegment
        switch currentTab {
        case 1:
            rebuildHistory()
            install(historyStack)
        case 2:
            rebuildColors()
            install(colorsStack)
            colorsDirty = false
        default:
            rebuildLayers()
            install(layersStack)
        }
    }

    // MARK: Public API

    func refresh() {
        rebuildLayers()
        if currentTab == 1 { rebuildHistory() }
        if currentTab == 2 {
            rebuildColors()
            colorsDirty = false
        } else {
            colorsDirty = true
        }
    }

    func refreshHistory() {
        guard currentTab == 1 else { return }
        rebuildHistory()
    }

    private func notifyDocumentChanged() {
        // Defer: action senders (buttons/sliders) may be torn down when the
        // workspace refreshes the inspector.
        DispatchQueue.main.async { [weak self] in self?.onDocumentChanged?() }
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
    }

    private func fillWidth(_ view: NSView, in stack: NSStackView) {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                    constant: -2 * Self.inset).isActive = true
    }

    // MARK: Layers tab

    private func rebuildLayers() {
        clear(layersStack)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let add = iconButton("plus.rectangle.on.rectangle", #selector(addLayer), "Add layer")
        let duplicate = iconButton("plus.square.on.square", #selector(duplicateLayer), "Duplicate layer")
        let remove = iconButton("trash", #selector(deleteLayer), "Delete layer")
        let up = iconButton("chevron.up", #selector(moveLayerUp), "Move layer up")
        let down = iconButton("chevron.down", #selector(moveLayerDown), "Move layer down")
        toolbar.addArrangedSubview(add)
        toolbar.addArrangedSubview(duplicate)
        toolbar.addArrangedSubview(remove)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(up)
        toolbar.addArrangedSubview(down)
        layersStack.addArrangedSubview(toolbar)
        fillWidth(toolbar, in: layersStack)

        let divider = InspectorDivider()
        divider.translatesAutoresizingMaskIntoConstraints = false
        layersStack.addArrangedSubview(divider)
        fillWidth(divider, in: layersStack)

        if document.layers.isEmpty {
            let empty = Theme.label("No layers", font: Theme.bodyFont, color: Theme.secondaryText)
            layersStack.addArrangedSubview(empty)
        }

        for index in stride(from: document.layers.count - 1, through: 0, by: -1) {
            let layer = document.layers[index]
            let row = LayerRowView(layer: layer, index: index,
                                   selected: index == document.activeLayerIndex)
            row.onToggleVisible = { [weak self, weak layer] in
                guard let self, let layer else { return }
                layer.isVisible.toggle()
                self.document.markChanged()
                self.notifyDocumentChanged()
                self.rebuildLayers()
            }
            row.onSelect = { [weak self] in
                self?.onLayerSelected?(index)
                self?.rebuildLayers()
            }
            row.onOpacityChanged = { [weak self, weak layer] value in
                guard let self, let layer else { return }
                layer.opacity = Double(value)
                self.document.markChanged()
                (NSApp.delegate as? AppDelegate)?.workspace?.canvas.needsDisplay = true
                row.updateSubtitle()
            }
            row.onBlendChanged = { [weak self, weak layer] mode in
                guard let self, let layer else { return }
                layer.blendMode = mode
                self.document.markChanged()
                (NSApp.delegate as? AppDelegate)?.workspace?.canvas.needsDisplay = true
                row.updateSubtitle()
            }
            row.onRename = { [weak self, weak layer] name in
                guard let self, let layer else { return }
                layer.name = name
                self.notifyDocumentChanged()
            }
            row.onDelete = { [weak self] in
                guard let self else { return }
                self.document.removeLayer(at: index)
                self.notifyDocumentChanged()
                self.rebuildLayers()
            }
            layersStack.addArrangedSubview(row)
            fillWidth(row, in: layersStack)
        }

        let hint = Theme.label("\(document.layers.count) layer\(document.layers.count == 1 ? "" : "s") · \(Int(document.canvasSize.width)) × \(Int(document.canvasSize.height)) px",
                               font: Theme.toolLabelFont, color: Theme.headerText)
        layersStack.addArrangedSubview(hint)
    }

    private func iconButton(_ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
        let image = Theme.symbol(symbol, pointSize: 13) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    @objc private func addLayer() {
        _ = document.addLayer()
        notifyDocumentChanged()
        rebuildLayers()
    }

    @objc private func duplicateLayer() {
        document.duplicateLayer(at: document.activeLayerIndex)
        notifyDocumentChanged()
        rebuildLayers()
    }

    @objc private func deleteLayer() {
        document.removeLayer(at: document.activeLayerIndex)
        notifyDocumentChanged()
        rebuildLayers()
    }

    @objc private func moveLayerUp() {
        let index = document.activeLayerIndex
        document.moveLayer(from: index, to: min(index + 1, document.layers.count - 1))
        notifyDocumentChanged()
        rebuildLayers()
    }

    @objc private func moveLayerDown() {
        let index = document.activeLayerIndex
        document.moveLayer(from: index, to: max(index - 1, 0))
        notifyDocumentChanged()
        rebuildLayers()
    }

    // MARK: History tab

    private func rebuildHistory() {
        clear(historyStack)
        let items = document.undoStack.undoItems

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addArrangedSubview(Theme.label("Undo history", font: Theme.sectionTitleFont,
                                              color: Theme.secondaryText))
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(Theme.label("\(items.count)",
                                              font: Theme.monoFont, color: Theme.headerText))
        historyStack.addArrangedSubview(header)
        fillWidth(header, in: historyStack)

        let divider = InspectorDivider()
        divider.translatesAutoresizingMaskIntoConstraints = false
        historyStack.addArrangedSubview(divider)
        fillWidth(divider, in: historyStack)

        if items.isEmpty {
            let empty = Theme.label("No edits yet", font: Theme.bodyFont, color: Theme.secondaryText)
            historyStack.addArrangedSubview(empty)
            let hint = Theme.label("Your actions will be listed here, newest first.",
                                   font: Theme.toolLabelFont, color: Theme.headerText)
            hint.lineBreakMode = .byTruncatingTail
            historyStack.addArrangedSubview(hint)
        } else {
            for (index, item) in items.enumerated().reversed() {
                let row = HistoryRowView(number: index + 1, title: item.name,
                                         newest: index == items.count - 1)
                historyStack.addArrangedSubview(row)
                fillWidth(row, in: historyStack)
            }
        }

        let redo = document.undoStack.redoItems.count
        let footer = Theme.label(redo == 0 ? "Nothing to redo" : "\(redo) step\(redo == 1 ? "" : "s") to redo",
                                 font: Theme.toolLabelFont, color: Theme.headerText)
        historyStack.addArrangedSubview(footer)
    }

    // MARK: Colors tab

    private func rebuildColors() {
        clear(colorsStack)
        swatchPair = nil
        paletteView = nil
        hexField = nil

        let settings = (NSApp.delegate as? AppDelegate)?.workspace?.settings
        let palette = (NSApp.delegate as? AppDelegate)?.workspace?.palette
        let primary = settings?.primaryColor ?? palette?.primary ?? .black
        _ = settings?.secondaryColor ?? palette?.secondary ?? .white

        colorsStack.addArrangedSubview(Theme.label("Color", font: Theme.sectionTitleFont,
                                                   color: Theme.secondaryText))

        let pairRow = NSStackView()
        pairRow.orientation = .horizontal
        pairRow.spacing = 10
        pairRow.alignment = .centerY
        pairRow.translatesAutoresizingMaskIntoConstraints = false

        let pair = PaintSwatchPairView()
        pair.translatesAutoresizingMaskIntoConstraints = false
        pair.primaryProvider = { [weak self] in self?.currentPrimary ?? .black }
        pair.secondaryProvider = { [weak self] in self?.currentSecondary ?? .white }
        pair.onPrimaryClick = { [weak self] in self?.openColorPanel(secondary: false) }
        pair.onSecondaryClick = { [weak self] in self?.openColorPanel(secondary: true) }
        pair.widthAnchor.constraint(equalToConstant: 30).isActive = true
        pair.heightAnchor.constraint(equalToConstant: 30).isActive = true
        swatchPair = pair

        let info = NSStackView()
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2
        info.translatesAutoresizingMaskIntoConstraints = false
        info.addArrangedSubview(Theme.label("Primary color", font: Theme.toolLabelFont,
                                            color: Theme.headerText))
        let field = NSTextField(string: primary.hexString)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.controlSize = .small
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.alignment = .left
        field.target = self
        field.action = #selector(applyHexField(_:))
        field.toolTip = "Edit the primary colour as #RRGGBB"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        hexField = field
        info.addArrangedSubview(field)

        let swap = NSButton(image: Theme.symbol("arrow.up.arrow.down", pointSize: 13) ?? NSImage(),
                            target: self, action: #selector(swapColors))
        swap.isBordered = false
        swap.bezelStyle = .inline
        swap.imagePosition = .imageOnly
        swap.toolTip = "Swap primary and secondary colors"
        swap.contentTintColor = .secondaryLabelColor
        swap.translatesAutoresizingMaskIntoConstraints = false
        swap.widthAnchor.constraint(equalToConstant: 24).isActive = true
        swap.heightAnchor.constraint(equalToConstant: 24).isActive = true

        pairRow.addArrangedSubview(pair)
        pairRow.addArrangedSubview(info)
        pairRow.addArrangedSubview(swap)
        colorsStack.addArrangedSubview(pairRow)

        let dividerOne = dividerView()
        colorsStack.addArrangedSubview(dividerOne)
        fillWidth(dividerOne, in: colorsStack)

        colorsStack.addArrangedSubview(Theme.label("Classic palette", font: Theme.sectionTitleFont,
                                                   color: Theme.secondaryText))
        let grid = PaintPaletteGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.swatchSize = 14
        grid.gap = 1
        grid.primaryProvider = { [weak self] in self?.currentPrimary ?? .black }
        grid.secondaryProvider = { [weak self] in self?.currentSecondary ?? .white }
        grid.onPrimary = { [weak self] color in self?.applyColor(color, secondary: false) }
        grid.onSecondary = { [weak self] color in self?.applyColor(color, secondary: true) }
        paletteView = grid
        colorsStack.addArrangedSubview(grid)

        let dividerTwo = dividerView()
        colorsStack.addArrangedSubview(dividerTwo)
        fillWidth(dividerTwo, in: colorsStack)

        colorsStack.addArrangedSubview(Theme.label("Recent colors", font: Theme.sectionTitleFont,
                                                   color: Theme.secondaryText))
        let recents = palette?.recentColors ?? []
        if recents.isEmpty {
            colorsStack.addArrangedSubview(Theme.label("Colors you use will appear here.",
                                                       font: Theme.toolLabelFont, color: Theme.headerText))
        } else {
            let recentRow = NSStackView()
            recentRow.orientation = .horizontal
            recentRow.spacing = 2
            recentRow.translatesAutoresizingMaskIntoConstraints = false
            for color in recents.prefix(10) {
                let swatch = RecentColorSwatchView(color: color)
                swatch.onClick = { [weak self] in self?.applyColor(color, secondary: false) }
                recentRow.addArrangedSubview(swatch)
            }
            colorsStack.addArrangedSubview(recentRow)
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        let edit = linkButton("Edit colors…", #selector(openPickerFromPanel))
        let adjust = linkButton("Adjustments…", #selector(openAdjustments))
        actions.addArrangedSubview(edit)
        actions.addArrangedSubview(adjust)
        colorsStack.addArrangedSubview(actions)
    }

    private func dividerView() -> NSView {
        let divider = InspectorDivider()
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
    }

    private func linkButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = Theme.toolLabelFont
        button.contentTintColor = .linkColor
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: Color state helpers

    private var currentPrimary: PixelColor {
        if let settings = (NSApp.delegate as? AppDelegate)?.workspace?.settings {
            return settings.primaryColor
        }
        return .black
    }

    private var currentSecondary: PixelColor {
        if let settings = (NSApp.delegate as? AppDelegate)?.workspace?.settings {
            return settings.secondaryColor
        }
        return .white
    }

    private func applyColor(_ color: PixelColor, secondary: Bool) {
        guard let workspace = (NSApp.delegate as? AppDelegate)?.workspace else { return }
        if secondary {
            workspace.settings.secondaryColor = color
            workspace.palette.secondary = color
        } else {
            workspace.settings.primaryColor = color
            workspace.palette.primary = color
        }
        hexField?.stringValue = workspace.settings.primaryColor.hexString
        swatchPair?.needsDisplay = true
        paletteView?.needsDisplay = true
        NotificationCenter.default.post(name: .paintCraftColorsDidChange, object: nil)
    }

    @objc private func applyHexField(_ sender: NSTextField) {
        guard let color = PixelColor(hex: sender.stringValue) else {
            sender.stringValue = currentPrimary.hexString
            NSSound.beep()
            return
        }
        applyColor(color, secondary: false)
        sender.stringValue = color.hexString
    }

    @objc private func swapColors() {
        guard let workspace = (NSApp.delegate as? AppDelegate)?.workspace else { return }
        let primary = workspace.settings.primaryColor
        workspace.settings.primaryColor = workspace.settings.secondaryColor
        workspace.settings.secondaryColor = primary
        workspace.palette.swap()
        hexField?.stringValue = workspace.settings.primaryColor.hexString
        swatchPair?.needsDisplay = true
        paletteView?.needsDisplay = true
        NotificationCenter.default.post(name: .paintCraftColorsDidChange, object: nil)
    }

    private func openColorPanel(secondary: Bool) {
        guard let workspace = (NSApp.delegate as? AppDelegate)?.workspace else { return }
        editingSecondary = secondary
        let panel = NSColorPanel.shared
        panel.color = (secondary ? workspace.settings.secondaryColor : workspace.settings.primaryColor).nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        applyColor(PixelColor.from(sender.color), secondary: editingSecondary)
    }

    @objc private func openPickerFromPanel() { openColorPanel(secondary: false) }

    @objc private func colorsDidChange() {
        if currentTab == 2 {
            if swatchPair == nil { rebuildColors(); install(colorsStack) } else {
                swatchPair?.needsDisplay = true
                paletteView?.needsDisplay = true
                if hexField?.currentEditor() == nil {
                    hexField?.stringValue = currentPrimary.hexString
                }
            }
        } else {
            colorsDirty = true
        }
    }

    @objc private func openAdjustments() {
        guard let workspace = (NSApp.delegate as? AppDelegate)?.workspace else { return }
        AdjustmentsPanel.present(for: workspace.window, document: document) { [weak self] in
            self?.onDocumentChanged?()
        }
    }
}

// MARK: - A layer row

final class LayerRowView: NSView {
    var onSelect: (() -> Void)?
    var onToggleVisible: (() -> Void)?
    var onOpacityChanged: ((Double) -> Void)?
    var onBlendChanged: ((BlendMode) -> Void)?
    var onRename: ((String) -> Void)?
    var onDelete: (() -> Void)?

    private let paintLayer: Layer
    private let index: Int
    private let isSelected: Bool
    private var subtitleLabel: NSTextField?
    private var hovering = false
    private var hoverTracking: NSTrackingArea?

    init(layer: Layer, index: Int, selected: Bool) {
        self.paintLayer = layer
        self.index = index
        self.isSelected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: selected ? 84 : 44).isActive = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let topRow = NSView()
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let visibility = NSButton(image: Theme.symbol(paintLayer.isVisible ? "eye" : "eye.slash",
                                                      pointSize: 12) ?? NSImage(),
                                  target: self, action: #selector(toggleVisible))
        visibility.isBordered = false
        visibility.bezelStyle = .inline
        visibility.imagePosition = .imageOnly
        visibility.contentTintColor = paintLayer.isVisible ? .secondaryLabelColor : .tertiaryLabelColor
        visibility.toolTip = paintLayer.isVisible ? "Hide layer" : "Show layer"
        visibility.translatesAutoresizingMaskIntoConstraints = false
        visibility.widthAnchor.constraint(equalToConstant: 18).isActive = true
        visibility.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let thumbnail = LayerThumbnailView(layer: paintLayer)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let name = ClickThroughLabel(labelWithString: paintLayer.name)
        name.font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = ClickThroughLabel(labelWithString: subtitleText())
        subtitle.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitleLabel = subtitle
        textStack.addArrangedSubview(name)
        textStack.addArrangedSubview(subtitle)

        let remove = NSButton(image: Theme.symbol("xmark.circle.fill", pointSize: 12) ?? NSImage(),
                              target: self, action: #selector(deleteLayer))
        remove.isBordered = false
        remove.bezelStyle = .inline
        remove.imagePosition = .imageOnly
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = "Delete layer"
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.widthAnchor.constraint(equalToConstant: 16).isActive = true
        remove.heightAnchor.constraint(equalToConstant: 16).isActive = true

        topRow.addSubview(visibility)
        topRow.addSubview(thumbnail)
        topRow.addSubview(textStack)
        topRow.addSubview(remove)

        addSubview(topRow)
        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            topRow.heightAnchor.constraint(equalToConstant: 32),

            visibility.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
            visibility.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: visibility.trailingAnchor, constant: 6),
            thumbnail.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 6),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -6),
            textStack.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 16),
            remove.heightAnchor.constraint(equalToConstant: 16)
        ])

        if isSelected {
            let opacityRow = makeOpacityRow()
            addSubview(opacityRow)
            let blendRow = makeBlendRow()
            addSubview(blendRow)
            NSLayoutConstraint.activate([
                opacityRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                opacityRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                opacityRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 6),
                opacityRow.heightAnchor.constraint(equalToConstant: 16),

                blendRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                blendRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                blendRow.topAnchor.constraint(equalTo: opacityRow.bottomAnchor, constant: 4),
                blendRow.heightAnchor.constraint(equalToConstant: 18)
            ])
        }
        _ = index
    }

    private func subtitleText() -> String {
        "\(paintLayer.blendMode.title) · \(Int((paintLayer.opacity * 100).rounded()))%"
    }

    func updateSubtitle() {
        subtitleLabel?.stringValue = subtitleText()
    }

    private func makeOpacityRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = Theme.label("Opacity", font: NSFont.systemFont(ofSize: 9), color: Theme.headerText)
        label.translatesAutoresizingMaskIntoConstraints = false
        let slider = NSSlider(value: paintLayer.opacity, minValue: 0, maxValue: 1,
                              target: self, action: #selector(opacityChanged(_:)))
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        let value = Theme.label("\(Int((paintLayer.opacity * 100).rounded()))%",
                                font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                color: Theme.secondaryText)
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 32).isActive = true
        value.alignment = .right
        container.addSubview(label)
        container.addSubview(slider)
        container.addSubview(value)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 40),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            slider.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            value.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 4),
            value.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            value.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func makeBlendRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = Theme.label("Blend", font: NSFont.systemFont(ofSize: 9), color: Theme.headerText)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let popup = NSPopUpButton()
        popup.addItems(withTitles: BlendMode.allCases.map { $0.title })
        popup.selectItem(withTitle: paintLayer.blendMode.title)
        popup.controlSize = .mini
        popup.font = NSFont.systemFont(ofSize: 9)
        popup.target = self
        popup.action = #selector(blendChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = Theme.roundedPath(bounds.insetBy(dx: 0.5, dy: 0.5), radius: 5)
        if isSelected {
            Theme.rowSelectedFill.setFill()
            path.fill()
        } else if hovering {
            Theme.hoverFill.setFill()
            path.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        super.mouseDown(with: event)
    }

    @objc private func toggleVisible() { onToggleVisible?() }
    @objc private func deleteLayer() { onDelete?() }
    @objc private func opacityChanged(_ sender: NSSlider) {
        onOpacityChanged?(sender.doubleValue)
    }
    @objc private func blendChanged(_ sender: NSPopUpButton) {
        if BlendMode.allCases.indices.contains(sender.indexOfSelectedItem) {
            onBlendChanged?(BlendMode.allCases[sender.indexOfSelectedItem])
        }
    }
}

// MARK: - History row

final class HistoryRowView: NSView {
    private let newest: Bool

    init(number: Int, title: String, newest: Bool) {
        self.newest = newest
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolTip = "\(number). \(title)"

        let label = ClickThroughLabel(labelWithString: "\(number). \(title)")
        label.font = newest ? NSFont.systemFont(ofSize: 10.5, weight: .semibold) : Theme.historyFont
        label.textColor = newest ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        if newest {
            Theme.rowSelectedFill.setFill()
            Theme.roundedPath(rect, radius: 3).fill()
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 4, width: 3, height: rect.height - 8).fill()
        }
    }
}

// MARK: - Status bar

final class StatusBarView: NSView {
    var zoom: CGFloat = 1.0 { didSet { refreshTexts() } }
    var cursorPoint: CGPoint? = nil { didSet { refreshTexts() } }
    var selectionSize: CGSize? = nil { didSet { refreshTexts() } }
    var canvasSize: CGSize = .zero { didSet { refreshTexts() } }
    var message: String = "" { didSet { messageLabel.stringValue = message } }

    private var positionLabel: NSTextField!
    private var selectionLabel: NSTextField!
    private var sizeLabel: NSTextField!
    private var zoomLabel: NSTextField!
    private var messageLabel: NSTextField!
    private var zoomSlider: NSSlider!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        positionLabel = smallLabel("")
        selectionLabel = smallLabel("")
        sizeLabel = smallLabel("")
        messageLabel = smallLabel("")
        messageLabel.textColor = .secondaryLabelColor

        zoomSlider = NSSlider(value: 1, minValue: 0.125, maxValue: 8, target: self,
                              action: #selector(zoomSliderChanged(_:)))
        zoomSlider.controlSize = .mini
        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        zoomLabel = smallLabel("100%")
        zoomLabel.font = Theme.monoFont

        stack.addArrangedSubview(positionLabel)
        stack.addArrangedSubview(selectionLabel)
        stack.addArrangedSubview(sizeLabel)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(zoomSlider)
        stack.addArrangedSubview(zoomLabel)
        refreshTexts()
    }

    private func smallLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = Theme.monoFont
        label.textColor = .secondaryLabelColor
        return label
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.ribbonBackground.setFill()
        bounds.fill()
        Theme.ribbonBorder.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func refreshTexts() {
        if let point = cursorPoint {
            positionLabel.stringValue = "\(Int(point.x)), \(Int(point.y)) px"
        } else {
            positionLabel.stringValue = "—"
        }
        if let selection = selectionSize {
            selectionLabel.stringValue = "Sel \(Int(selection.width)) × \(Int(selection.height))"
        } else {
            selectionLabel.stringValue = ""
        }
        sizeLabel.stringValue = "\(Int(canvasSize.width)) × \(Int(canvasSize.height))"
        zoomLabel.stringValue = String(format: "%.0f%%", zoom * 100)
        zoomSlider.doubleValue = Double(zoom)
    }

    @objc private func zoomSliderChanged(_ sender: NSSlider) {
        guard let workspace = (NSApp.delegate as? AppDelegate)?.workspace else { return }
        workspace.canvas.setZoom(CGFloat(sender.doubleValue),
                                 anchor: CGPoint(x: workspace.canvas.bounds.midX,
                                                 y: workspace.canvas.bounds.midY))
    }
}

// MARK: - Resize dialog

final class ResizeDialog: NSWindowController {
    enum Mode { case canvas, image }
    var onApply: ((CGSize, Mode) -> Void)?
    private var widthField: NSTextField!
    private var heightField: NSTextField!
    private var modeControl: NSSegmentedControl!
    private var current: CGSize

    init(current: CGSize) {
        self.current = current
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 190),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Resize"
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        modeControl = NSSegmentedControl(labels: ["Resize image", "Resize canvas"],
                                         trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modeControl.selectedSegment = 0
        stack.addArrangedSubview(modeControl)

        let sizeRow = NSStackView()
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8
        widthField = NSTextField(string: "\(Int(current.width))")
        heightField = NSTextField(string: "\(Int(current.height))")
        for field in [widthField!, heightField!] {
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
            field.alignment = .right
        }
        sizeRow.addArrangedSubview(NSTextField(labelWithString: "Width"))
        sizeRow.addArrangedSubview(widthField)
        sizeRow.addArrangedSubview(NSTextField(labelWithString: "Height"))
        sizeRow.addArrangedSubview(heightField)
        stack.addArrangedSubview(sizeRow)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .trailing
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply))
        apply.keyEquivalent = "\r"
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(apply)
        stack.addArrangedSubview(buttons)
    }

    @objc private func modeChanged() {}

    @objc private func apply() {
        let width = max(1, widthField.integerValue)
        let height = max(1, heightField.integerValue)
        let mode: Mode = modeControl.selectedSegment == 0 ? .image : .canvas
        onApply?(CGSize(width: width, height: height), mode)
        window?.sheetParent?.endSheet(window!) ?? window?.close()
    }

    @objc private func cancel() {
        window?.sheetParent?.endSheet(window!) ?? window?.close()
    }

    func present(for parent: NSWindow?) {
        guard let parent else { window?.makeKeyAndOrderFront(nil); return }
        parent.beginSheet(window!)
    }
}
