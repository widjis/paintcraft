import AppKit

// MARK: - Ribbon group container

/// One ribbon group: a content area on top and the small uppercase group header
/// underneath, matching the Windows 11 Paint ribbon rhythm. A hairline
/// separator is drawn at the trailing edge.
final class RibbonGroupView: NSView {
    private let header: NSTextField
    private let content: NSView
    var showsTrailingSeparator = true

    init(title: String, content: NSView) {
        self.content = content
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: Theme.groupHeaderFont,
            .foregroundColor: Theme.headerText,
            .kern: 0.6
        ])
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        self.header = label

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(label)

        let topAlign = content.topAnchor.constraint(equalTo: topAnchor, constant: 3)
        topAlign.priority = NSLayoutConstraint.Priority(749)
        NSLayoutConstraint.activate([
            topAlign,
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            // The group is exactly as wide as its content plus side padding.
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            content.bottomAnchor.constraint(lessThanOrEqualTo: label.topAnchor, constant: -2),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            heightAnchor.constraint(equalToConstant: Theme.Metrics.ribbonGroupHeight)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard showsTrailingSeparator else { return }
        Theme.groupSeparator.setFill()
        NSRect(x: bounds.maxX - 1, y: 10, width: 1, height: bounds.height - 20).fill()
    }
}

/// A screen-wide hairline used between ribbon groups when a group cannot draw
/// its own separator (e.g. first/last group).
final class RibbonSeparatorView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: Theme.Metrics.ribbonGroupHeight) }
    override func draw(_ dirtyRect: NSRect) {
        Theme.groupSeparator.setFill()
        NSRect(x: bounds.midX - 0.5, y: 10, width: 1, height: bounds.height - 20).fill()
    }
}

// MARK: - Tool ribbon

/// The Paint-style ribbon: tab contents inside a horizontal scroll view (no
/// visible scroller), grouped commands with small uppercase headers, a classic
/// two-row colour palette and the primary/secondary colour swatches.
final class ToolRibbon: NSView {
    let settings: ToolSettings
    var onSelectTool: ((ToolKind) -> Void)?
    var onOpenColorPicker: (() -> Void)?
    var onResizeCanvas: (() -> Void)?

    private var toolButtons: [ToolKind: PaintRibbonButton] = [:]
    private var sizeSlider: NSSlider!
    private var sizeLabel: NSTextField!
    private var paletteView: PaintPaletteGridView!
    private var swatchPair: PaintSwatchPairView!
    private var outlineCheck: NSButton!
    private var fillCheck: NSButton!
    private var lineStylePopup: NSPopUpButton!
    private var gridToggle: PaintRibbonButton!
    private var rulersToggle: PaintRibbonButton!
    private var zoomPopup: NSPopUpButton!
    private var zoomValueLabel: NSTextField!

    private var sections: [String: NSView] = [:]
    private var currentTab = "home"
    private var scrollView: NSScrollView!

    private static let primaryTools: [ToolKind] = [
        .pencil, .fill, .eraser, .text, .brush, .airbrush, .eyedropper, .magnifier
    ]
    private static let shapeTools: [ToolKind] = [
        .line, .curve, .rectangle, .roundedRectangle, .ellipse,
        .triangle, .polygon, .diamond, .arrow, .star
    ]
    private static let selectTools: [ToolKind] = [.selectRect, .selectFreeform, .magicWand]

    private static let shortTitles: [ToolKind: String] = [
        .pencil: "Pencil", .fill: "Fill", .eraser: "Eraser", .text: "Text",
        .brush: "Brush", .airbrush: "Airbrush", .eyedropper: "Picker",
        .magnifier: "Magnifier"
    ]

    init(settings: ToolSettings) {
        self.settings = settings
        super.init(frame: .zero)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(colorsDidChange),
                                               name: .paintCraftColorsDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        addSubview(scrollView)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .bottom
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let home = makeHomeSection()
        let view = makeViewSection()
        let file = makeFileSection()
        sections["home"] = home
        sections["view"] = view
        sections["file"] = file
        for section in [home, view, file] {
            stack.addArrangedSubview(section)
            section.isHidden = (section !== home)
        }
        // Let the Colors group settle against the right edge on wide windows.
        view.isHidden = true
        file.isHidden = true

        refresh()
        selectToolButton(settings.tool)
    }

    private func makeHomeSection() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        row.addArrangedSubview(RibbonGroupView(title: "Tools", content: makeToolGrid()))

        let shapeRow = makeShapeGallery()
        row.addArrangedSubview(RibbonGroupView(title: "Shapes", content: shapeRow))

        row.addArrangedSubview(RibbonGroupView(title: "Select", content: makeSelectTools()))
        row.addArrangedSubview(RibbonGroupView(title: "Size", content: makeSizeOptions()))
        row.addArrangedSubview(RibbonGroupView(title: "Image", content: makeImageOps()))

        // Flexible spacer keeps Colors pinned to the right on wide windows.
        row.addArrangedSubview(makeFlexibleSpacer())

        let colorsGroup = RibbonGroupView(title: "Colors", content: makeColors())
        colorsGroup.showsTrailingSeparator = false
        row.addArrangedSubview(colorsGroup)
        return row
    }

    /// A zero-intrinsic-width view that absorbs leftover ribbon width so groups
    /// keep their natural size and stay left-aligned.
    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        return spacer
    }

    private func makeToolGrid() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = 2
        grid.translatesAutoresizingMaskIntoConstraints = false
        let first = NSStackView()
        let second = NSStackView()
        for stack in [first, second] {
            stack.orientation = .horizontal
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false
            grid.addArrangedSubview(stack)
        }
        for (index, kind) in Self.primaryTools.enumerated() {
            let button = PaintRibbonButton(symbol: kind.symbolName,
                                           title: Self.shortTitles[kind] ?? kind.title,
                                           style: .labeled, target: self,
                                           action: #selector(toolClicked(_:)), toggles: true)
            button.tag = ToolKind.allCases.firstIndex(of: kind) ?? 0
            button.widthAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonHeight).isActive = true
            toolButtons[kind] = button
            if index < 4 { first.addArrangedSubview(button) } else { second.addArrangedSubview(button) }
        }
        return grid
    }

    private func makeShapeGallery() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = 2
        grid.translatesAutoresizingMaskIntoConstraints = false
        let first = NSStackView()
        let second = NSStackView()
        for stack in [first, second] {
            stack.orientation = .horizontal
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false
            grid.addArrangedSubview(stack)
        }
        for (index, kind) in Self.shapeTools.enumerated() {
            let button = PaintRibbonButton()
            button.image = Theme.shapeThumbnail(kind)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.bezelStyle = .inline
            button.setButtonType(.pushOnPushOff)
            button.focusRingType = .none
            button.target = self
            button.action = #selector(toolClicked(_:))
            button.tag = ToolKind.allCases.firstIndex(of: kind) ?? 0
            button.toolTip = kind.title
            button.contentTintColor = .secondaryLabelColor
            button.widthAnchor.constraint(equalToConstant: Theme.Metrics.shapeButton).isActive = true
            button.heightAnchor.constraint(equalToConstant: Theme.Metrics.shapeButton).isActive = true
            toolButtons[kind] = button
            if index < 5 { first.addArrangedSubview(button) } else { second.addArrangedSubview(button) }
        }
        return grid
    }

    private func makeSelectTools() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        for kind in Self.selectTools {
            let button = PaintRibbonButton(symbol: kind.symbolName, title: kind.title,
                                           style: .iconOnly, target: self,
                                           action: #selector(toolClicked(_:)), toggles: true)
            button.tag = ToolKind.allCases.firstIndex(of: kind) ?? 0
            button.widthAnchor.constraint(equalToConstant: Theme.Metrics.iconButton).isActive = true
            button.heightAnchor.constraint(equalToConstant: Theme.Metrics.iconButton).isActive = true
            toolButtons[kind] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    private func makeSizeOptions() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false

        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 8
        sliderRow.translatesAutoresizingMaskIntoConstraints = false
        let sizeTitle = Theme.label("Size", font: Theme.buttonLabelFont, color: Theme.secondaryText)
        sizeSlider = NSSlider(value: Double(settings.strokeWidth), minValue: 1, maxValue: 72,
                              target: self, action: #selector(sizeChanged(_:)))
        sizeSlider.controlSize = .small
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 104).isActive = true
        sizeLabel = Theme.label("\(Int(settings.strokeWidth)) px", font: Theme.monoFont,
                                color: Theme.secondaryText)
        sliderRow.addArrangedSubview(sizeTitle)
        sliderRow.addArrangedSubview(sizeSlider)
        sliderRow.addArrangedSubview(sizeLabel)

        let styleRow = NSStackView()
        styleRow.orientation = .horizontal
        styleRow.alignment = .centerY
        styleRow.spacing = 6
        styleRow.translatesAutoresizingMaskIntoConstraints = false
        outlineCheck = NSButton(checkboxWithTitle: "Outline", target: self, action: #selector(styleChanged(_:)))
        fillCheck = NSButton(checkboxWithTitle: "Fill", target: self, action: #selector(styleChanged(_:)))
        for check in [outlineCheck!, fillCheck!] {
            check.controlSize = .small
            check.font = Theme.toolLabelFont
        }
        outlineCheck.state = settings.shapeStyle.outlineEnabled ? .on : .off
        fillCheck.state = settings.shapeStyle.fillEnabled ? .on : .off
        lineStylePopup = NSPopUpButton()
        lineStylePopup.addItems(withTitles: LineStyle.allCases.map { styleName($0) })
        lineStylePopup.controlSize = .small
        lineStylePopup.font = Theme.toolLabelFont
        lineStylePopup.target = self
        lineStylePopup.action = #selector(lineStyleChanged(_:))
        lineStylePopup.translatesAutoresizingMaskIntoConstraints = false
        lineStylePopup.widthAnchor.constraint(equalToConstant: 82).isActive = true
        styleRow.addArrangedSubview(outlineCheck)
        styleRow.addArrangedSubview(fillCheck)
        styleRow.addArrangedSubview(lineStylePopup)

        column.addArrangedSubview(sliderRow)
        column.addArrangedSubview(styleRow)
        return column
    }

    private func makeImageOps() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false

        let bigRow = NSStackView()
        bigRow.orientation = .horizontal
        bigRow.spacing = 2
        bigRow.translatesAutoresizingMaskIntoConstraints = false
        let crop = PaintRibbonButton(symbol: "crop", title: "Crop", style: .labeled,
                                     target: nil, action: #selector(WorkspaceController.cropToSelection(_:)))
        crop.widthAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonWidth).isActive = true
        crop.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonHeight).isActive = true
        let resize = PaintRibbonButton(symbol: "arrow.up.left.and.arrow.down.right", title: "Resize",
                                       style: .labeled, target: nil,
                                       action: #selector(WorkspaceController.resizeImage(_:)))
        resize.widthAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonWidth).isActive = true
        resize.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonHeight).isActive = true
        bigRow.addArrangedSubview(crop)
        bigRow.addArrangedSubview(resize)

        let smallRow = NSStackView()
        smallRow.orientation = .horizontal
        smallRow.spacing = 2
        smallRow.translatesAutoresizingMaskIntoConstraints = false
        let smallOps: [(String, String, Selector)] = [
            ("Rotate", "rotate.right", #selector(WorkspaceController.rotateCanvas(_:))),
            ("Flip h", "arrow.left.and.right.righttriangle.left.righttriangle.right",
             #selector(WorkspaceController.flipCanvasHorizontal(_:))),
            ("Flip v", "arrow.up.and.down.righttriangle.up.righttriangle.down",
             #selector(WorkspaceController.flipCanvasVertical(_:))),
            ("Invert", "circle.lefthalf.filled", #selector(WorkspaceController.invertColors(_:)))
        ]
        for op in smallOps {
            let button = PaintRibbonButton(symbol: op.1, title: op.0, style: .iconOnly,
                                           target: nil, action: op.2)
            button.widthAnchor.constraint(equalToConstant: Theme.Metrics.iconButton).isActive = true
            button.heightAnchor.constraint(equalToConstant: Theme.Metrics.iconButton).isActive = true
            smallRow.addArrangedSubview(button)
        }

        column.addArrangedSubview(bigRow)
        column.addArrangedSubview(smallRow)
        return column
    }

    private func makeColors() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        swatchPair = PaintSwatchPairView()
        swatchPair.translatesAutoresizingMaskIntoConstraints = false
        swatchPair.widthAnchor.constraint(equalToConstant: 28).isActive = true
        swatchPair.heightAnchor.constraint(equalToConstant: 28).isActive = true
        swatchPair.primaryProvider = { [weak self] in self?.settings.primaryColor ?? .black }
        swatchPair.secondaryProvider = { [weak self] in self?.settings.secondaryColor ?? .white }
        swatchPair.onPrimaryClick = { [weak self] in self?.onOpenColorPicker?() }
        swatchPair.onSecondaryClick = { [weak self] in self?.onOpenColorPicker?() }

        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 1
        right.translatesAutoresizingMaskIntoConstraints = false

        paletteView = PaintPaletteGridView()
        paletteView.translatesAutoresizingMaskIntoConstraints = false
        paletteView.primaryProvider = { [weak self] in self?.settings.primaryColor ?? .black }
        paletteView.secondaryProvider = { [weak self] in self?.settings.secondaryColor ?? .white }
        paletteView.onPrimary = { [weak self] color in nextPrimaryColor(color, self) }
        paletteView.onSecondary = { [weak self] color in nextSecondaryColor(color, self) }

        let edit = NSButton(title: "Edit colors…", target: self, action: #selector(editColors))
        edit.isBordered = false
        edit.bezelStyle = .inline
        edit.font = Theme.toolLabelFont
        edit.contentTintColor = .linkColor
        edit.alignment = .left
        edit.translatesAutoresizingMaskIntoConstraints = false

        right.addArrangedSubview(paletteView)
        right.addArrangedSubview(edit)
        row.addArrangedSubview(swatchPair)
        row.addArrangedSubview(right)
        return row
    }

    private func makeViewSection() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        row.addArrangedSubview(RibbonGroupView(title: "Zoom", content: makeZoomControls()))
        row.addArrangedSubview(RibbonGroupView(title: "Show", content: makeShowControls()))
        let layers = RibbonGroupView(title: "Layers", content: makeLayerControls())
        layers.showsTrailingSeparator = false
        row.addArrangedSubview(layers)
        row.addArrangedSubview(makeFlexibleSpacer())
        return row
    }

    private func makeZoomControls() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false
        zoomPopup = NSPopUpButton()
        zoomPopup.addItems(withTitles: ZoomLevel.presets.map { $0.title })
        zoomPopup.controlSize = .small
        zoomPopup.font = Theme.toolLabelFont
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomPresetChanged(_:))
        zoomPopup.translatesAutoresizingMaskIntoConstraints = false
        zoomPopup.widthAnchor.constraint(equalToConstant: 88).isActive = true
        zoomValueLabel = Theme.label("100%", font: Theme.monoFont, color: Theme.secondaryText)
        top.addArrangedSubview(zoomPopup)
        top.addArrangedSubview(zoomValueLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let ops: [(String, String, Selector)] = [
            ("Zoom out", "minus.magnifyingglass", #selector(WorkspaceController.zoomOut(_:))),
            ("Zoom in", "plus.magnifyingglass", #selector(WorkspaceController.zoomIn(_:))),
            ("Actual size", "1.magnifyingglass", #selector(WorkspaceController.zoomActual(_:))),
            ("Fit to window", "arrow.up.left.and.down.right.magnifyingglass",
             #selector(WorkspaceController.zoomFit(_:)))
        ]
        for op in ops {
            let button = PaintRibbonButton(symbol: op.1, title: op.0, style: .iconOnly,
                                           target: nil, action: op.2)
            button.widthAnchor.constraint(equalToConstant: Theme.Metrics.iconButton).isActive = true
            button.heightAnchor.constraint(equalToConstant: Theme.Metrics.iconButton).isActive = true
            buttons.addArrangedSubview(button)
        }
        column.addArrangedSubview(top)
        column.addArrangedSubview(buttons)
        return column
    }

    private func makeShowControls() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false

        gridToggle = PaintRibbonButton(symbol: "square.grid.3x3", title: "Pixel grid",
                                       style: .labeled, target: self,
                                       action: #selector(toggleGrid(_:)), toggles: true)
        gridToggle.state = settings.showPixelGrid ? .on : .off
        gridToggle.widthAnchor.constraint(equalToConstant: 54).isActive = true
        gridToggle.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonHeight).isActive = true
        rulersToggle = PaintRibbonButton(symbol: "ruler", title: "Rulers",
                                         style: .labeled, target: self,
                                         action: #selector(toggleRulers(_:)), toggles: true)
        rulersToggle.state = settings.showRulers ? .on : .off
        rulersToggle.widthAnchor.constraint(equalToConstant: 54).isActive = true
        rulersToggle.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonHeight).isActive = true
        row.addArrangedSubview(gridToggle)
        row.addArrangedSubview(rulersToggle)
        return row
    }

    private func makeLayerControls() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        let add = PaintRibbonButton(symbol: "plus.square.on.square", title: "Add layer",
                                    style: .labeled, target: nil,
                                    action: #selector(WorkspaceController.addLayerAction(_:)))
        add.widthAnchor.constraint(equalToConstant: 56).isActive = true
        add.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonHeight).isActive = true
        let merge = PaintRibbonButton(symbol: "arrow.triangle.merge", title: "Merge down",
                                      style: .labeled, target: nil,
                                      action: #selector(WorkspaceController.mergeLayerAction(_:)))
        merge.widthAnchor.constraint(equalToConstant: 56).isActive = true
        merge.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonHeight).isActive = true
        row.addArrangedSubview(add)
        row.addArrangedSubview(merge)
        return row
    }

    // MARK: File tab (quick actions)

    private func makeFileSection() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false
        let ops: [(String, String, Selector)] = [
            ("New", "doc.badge.plus", #selector(WorkspaceController.newDocument(_:))),
            ("Open…", "folder", #selector(WorkspaceController.openDocument(_:))),
            ("Save", "square.and.arrow.down", #selector(WorkspaceController.saveDocument(_:))),
            ("Export…", "square.and.arrow.up", #selector(WorkspaceController.exportImage(_:)))
        ]
        for op in ops {
            let button = PaintRibbonButton(symbol: op.1, title: op.0, style: .labeled,
                                           target: nil, action: op.2)
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            button.heightAnchor.constraint(equalToConstant: Theme.Metrics.toolButtonHeight).isActive = true
            actions.addArrangedSubview(button)
        }
        let fileGroup = RibbonGroupView(title: "File", content: actions)

        let help = Theme.label("New, open, save or export your painting.",
                               font: Theme.bodyFont, color: Theme.secondaryText)
        let helpGroup = RibbonGroupView(title: "Start", content: help)
        helpGroup.showsTrailingSeparator = false

        row.addArrangedSubview(fileGroup)
        row.addArrangedSubview(helpGroup)
        row.addArrangedSubview(makeFlexibleSpacer())
        return row
    }

    // MARK: Actions

    @objc private func toolClicked(_ sender: NSButton) {
        let all = ToolKind.allCases
        guard all.indices.contains(sender.tag) else { return }
        let kind = all[sender.tag]
        selectToolButton(kind)
        onSelectTool?(kind)
    }

    func selectToolButton(_ kind: ToolKind) {
        for (candidate, button) in toolButtons {
            let selected = candidate == kind
            button.setAccentSelected(selected)
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.needsDisplay = true
        }
    }

    @objc private func editColors() { onOpenColorPicker?() }

    @objc private func sizeChanged(_ sender: NSSlider) {
        settings.strokeWidth = CGFloat(sender.doubleValue)
        settings.shapeLineWidth = CGFloat(sender.doubleValue)
        settings.airbrushSize = max(8, CGFloat(sender.doubleValue) * 4)
        sizeLabel.stringValue = "\(Int(sender.doubleValue)) px"
    }

    @objc private func styleChanged(_ sender: NSButton) {
        settings.shapeStyle.outlineEnabled = outlineCheck.state == .on
        settings.shapeStyle.fillEnabled = fillCheck.state == .on
    }

    /// Display names for the Paint line-style options.
    private func styleName(_ style: LineStyle) -> String {
        switch style {
        case .solid: return "Solid"
        case .dash: return "Dash"
        case .dot: return "Dot"
        case .dashDot: return "Dash-dot"
        case .dashDotDot: return "Dash-dot-dot"
        }
    }

    @objc private func lineStyleChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard LineStyle.allCases.indices.contains(index) else { return }
        settings.shapeStyle.lineStyle = LineStyle.allCases[index]
    }

    @objc private func zoomPresetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ZoomLevel.presets.indices.contains(index) else { return }
        guard let workspace = (NSApp.delegate as? AppDelegate)?.workspace else { return }
        workspace.canvas.setZoom(ZoomLevel.presets[index].scale, anchor: .zero)
        workspace.canvas.centerCanvas(zoomToFit: false)
    }

    @objc private func toggleGrid(_ sender: NSButton) {
        settings.showPixelGrid = sender.state == .on
        (NSApp.delegate as? AppDelegate)?.workspace?.canvas.needsDisplay = true
    }

    @objc private func toggleRulers(_ sender: NSButton) {
        settings.showRulers = sender.state == .on
        (NSApp.delegate as? AppDelegate)?.workspace?.canvas.needsDisplay = true
    }

    @objc private func colorsDidChange() {
        refreshColors()
    }

    // MARK: Public API used by the workspace controller

    func show(tab: String) {
        currentTab = ["home", "view", "file"].contains(tab) ? tab : "home"
        for (name, section) in sections {
            section.isHidden = name != currentTab
        }
        let clip = scrollView.contentView
        if clip.bounds.origin != .zero {
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
        }
        refresh()
    }

    func refresh() {
        sizeSlider?.doubleValue = Double(settings.strokeWidth)
        sizeLabel?.stringValue = "\(Int(settings.strokeWidth)) px"
        outlineCheck?.state = settings.shapeStyle.outlineEnabled ? .on : .off
        fillCheck?.state = settings.shapeStyle.fillEnabled ? .on : .off
        if let index = LineStyle.allCases.firstIndex(of: settings.shapeStyle.lineStyle) {
            lineStylePopup?.selectItem(at: index)
        }
        gridToggle?.setAccentSelected(settings.showPixelGrid)
        rulersToggle?.setAccentSelected(settings.showRulers)
        paletteView?.needsDisplay = true
        swatchPair?.needsDisplay = true
        if let workspace = (NSApp.delegate as? AppDelegate)?.workspace {
            zoomValueLabel?.stringValue = String(format: "%.0f%%", workspace.canvas.zoomScale * 100)
        }
    }

    func refreshColors() {
        paletteView?.needsDisplay = true
        swatchPair?.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.ribbonBackground.setFill()
        bounds.fill()
        Theme.ribbonBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Colour plumbing (file-level helpers keep closures small)

private func nextPrimaryColor(_ color: PixelColor, _ ribbon: ToolRibbon?) {
    guard let ribbon else { return }
    ribbon.settings.primaryColor = color
    (NSApp.delegate as? AppDelegate)?.workspace?.palette.primary = color
    ribbon.refreshColors()
    NotificationCenter.default.post(name: .paintCraftColorsDidChange, object: nil)
}

private func nextSecondaryColor(_ color: PixelColor, _ ribbon: ToolRibbon?) {
    guard let ribbon else { return }
    ribbon.settings.secondaryColor = color
    (NSApp.delegate as? AppDelegate)?.workspace?.palette.secondary = color
    ribbon.refreshColors()
    NotificationCenter.default.post(name: .paintCraftColorsDidChange, object: nil)
}
