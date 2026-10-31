import AppKit

/// The main window: title bar, ribbon tabs, tool ribbon, canvas, inspector and
/// status bar. Owns the editing session (document, palette, tool settings).
final class WorkspaceController: NSWindowController, NSWindowDelegate {
    private(set) var canvasDocument: Document
    let settings = ToolSettings()
    let palette = ColorPalette()
    let tools = ToolRegistry()
    private(set) var canvas: CanvasView!

    private var ribbon: ToolRibbon!
    private var inspector: InspectorPanel!
    private var statusBar: StatusBarView!
    private var tabButtons: [NSButton] = []
    private var activeTab: RibbonTab = .home

    private enum RibbonTab: Int, CaseIterable {
        case file = 0, home = 1, view = 2
        var title: String {
            switch self {
            case .file: return "File"
            case .home: return "Home"
            case .view: return "View"
            }
        }
    }

    init(document: Document? = nil) {
        self.canvasDocument = document ?? Document(width: 1024, height: 768)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 900, height: 620)
        window.title = canvasDocument.documentName
        window.setFrameAutosaveName("PaintCraftMainWindow")
        super.init(window: window)
        window.delegate = self
        window.center()
        canvasDocument.delegate = self
        buildContent()
        syncTool()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.canvas.centerCanvas(zoomToFit: true)
            self?.canvas.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func showWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSLog("PaintCraft window frame=\(window?.frame.debugDescription ?? "nil") visible=\(window?.isVisible ?? false)")
    }

    // MARK: Content assembly

    private func buildContent() {
        guard let window, let contentView = window.contentView else { return }
        // A small strip for the traffic lights + our tab row.
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let tabRow = buildTabRow()
        ribbon = ToolRibbon(settings: settings)
        ribbon.onSelectTool = { [weak self] kind in self?.select(tool: kind) }
        ribbon.onOpenColorPicker = { [weak self] in self?.showColorPicker() }
        ribbon.onResizeCanvas = { [weak self] in self?.showResizeDialog() }

        canvas = CanvasView(document: canvasDocument, settings: settings, tools: tools)
        canvas.context.canvasView = canvas
        canvas.onZoomChanged = { [weak self] z in
            self?.statusBar?.zoom = z
            self?.canvas.needsDisplay = true
        }
        canvas.onCursorMoved = { [weak self] p in self?.statusBar?.cursorPoint = p }
        canvas.onStatusMessage = { [weak self] m in self?.statusBar?.message = m }
        canvas.onToolShortcut = { [weak self] kind in self?.select(tool: kind) }
        canvas.onZoomChanged?(canvas.zoomScale)

        inspector = InspectorPanel(document: canvasDocument)
        inspector.onLayerSelected = { [weak self] idx in
            self?.canvasDocument.activeLayerIndex = idx
            self?.inspector.refresh()
        }
        inspector.onDocumentChanged = { [weak self] in self?.refreshAll() }

        statusBar = StatusBarView()
        statusBar.zoom = canvas.zoomScale
        statusBar.canvasSize = canvasDocument.canvasSize

        let middle = NSSplitView()
        middle.isVertical = true
        middle.dividerStyle = .thin
        middle.addArrangedSubview(canvas)
        middle.addArrangedSubview(inspector)
        inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        inspector.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        // Explicit constraints instead of a vertical NSStackView: the middle
        // split view has no intrinsic height and would collapse inside a stack.
        for v in [tabRow, ribbon, middle, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabRow.topAnchor.constraint(equalTo: root.topAnchor),
            tabRow.heightAnchor.constraint(equalToConstant: 40),

            ribbon.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ribbon.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ribbon.topAnchor.constraint(equalTo: tabRow.bottomAnchor),
            ribbon.heightAnchor.constraint(equalToConstant: 96),

            middle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            middle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            middle.topAnchor.constraint(equalTo: ribbon.bottomAnchor),
            middle.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26)
        ])
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
    }

    private func buildTabRow() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 92),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        for tab in RibbonTab.allCases {
            let b = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
            b.tag = tab.rawValue
            b.bezelStyle = .recessed
            b.setButtonType(.pushOnPushOff)
            b.isBordered = false
            b.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            b.contentTintColor = .secondaryLabelColor
            stack.addArrangedSubview(b)
            tabButtons.append(b)
        }
        // App title to the right of tabs, like classic Paint.
        let title = NSTextField(labelWithString: "PaintCraft")
        title.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        title.textColor = .tertiaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(title)
        NSLayoutConstraint.activate([
            title.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            title.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func updateTabSelection() {
        for b in tabButtons {
            let selected = b.tag == activeTab.rawValue
            b.contentTintColor = selected ? .labelColor : .secondaryLabelColor
            b.state = selected ? .on : .off
        }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        activeTab = RibbonTab(rawValue: sender.tag) ?? .home
        updateTabSelection()
        ribbon.show(tab: activeTab.title.lowercased())
    }

    // MARK: Tool plumbing

    private func syncTool() {
        canvas?.currentTool?.deactivate(in: canvas.context)
        if let tool = tools.instance(for: settings.tool) {
            canvas?.currentTool = tool
            tool.activate(in: canvas.context)
        }
        canvas?.window?.invalidateCursorRects(for: canvas)
        ribbon?.selectToolButton(settings.tool)
    }

    @objc func selectToolFromMenu(_ sender: NSMenuItem) {
        guard ToolKind.allCases.indices.contains(sender.tag) else { return }
        select(tool: ToolKind.allCases[sender.tag])
    }

    func select(tool kind: ToolKind) {
        settings.tool = kind
        syncTool()
    }

    // MARK: Actions

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscardIfNeeded() else { return }
        // Build a fresh document and swap it in through the same path used when
        // opening a file, so delegate wiring and canvas rebuild stay consistent.
        replaceDocument(Document(width: 1024, height: 768))
        window?.title = canvasDocument.documentName
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileIO.readableTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirmDiscardIfNeeded() else { return }
        do {
            let (doc, warnings) = try FileIO.open(url: url)
            canvasDocument = doc
            canvasDocument.delegate = self
            rebuildCanvas()
            refreshAll()
            if !warnings.isEmpty {
                statusBar.message = warnings.joined(separator: " · ")
            }
        } catch {
            presentError(error, message: "Could not open \(url.lastPathComponent)")
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let url = canvasDocument.fileURL {
            performSave(to: url)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "paintcraft") ?? .data]
        panel.nameFieldStringValue = canvasDocument.documentName + ".paintcraft"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performSave(to: url)
    }

    @objc func exportImage(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp]
        panel.nameFieldStringValue = canvasDocument.documentName + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileIO.exportImage(document: canvasDocument, to: url)
            statusBar.message = "Exported \(url.lastPathComponent)"
        } catch {
            presentError(error, message: "Export failed")
        }
    }

    private func performSave(to url: URL) {
        do {
            try FileIO.save(document: canvasDocument, to: url)
            canvasDocument.fileURL = url
            canvasDocument.documentName = url.deletingPathExtension().lastPathComponent
            window?.title = canvasDocument.documentName
            canvasDocument.dirty = false
            statusBar.message = "Saved \(url.lastPathComponent)"
        } catch {
            presentError(error, message: "Save failed")
        }
    }

    @objc func undo(_ sender: Any?) { canvasDocument.undo(); refreshAll() }
    @objc func redo(_ sender: Any?) { canvasDocument.redo(); refreshAll() }

    @objc override func selectAll(_ sender: Any?) { canvasDocument.selectAll(); canvas.needsDisplay = true }

    @objc(copy:)
    func copyAction(_ sender: Any?) {
        if canvasDocument.copySelection() { statusBar.message = "Copied selection" }
    }

    @objc(cut:)
    func cutAction(_ sender: Any?) {
        if canvasDocument.cutSelection() { statusBar.message = "Cut selection"; refreshAll() }
    }

    @objc(paste:)
    func pasteAction(_ sender: Any?) {
        if canvasDocument.pasteSelection() { statusBar.message = "Pasted"; refreshAll() }
    }

    @objc func deleteSelection(_ sender: Any?) {
        if canvasDocument.deleteSelection() { statusBar.message = "Deleted selection"; refreshAll() }
    }

    @objc func nudgeSelectionLeft(_ sender: Any?) { _ = canvasDocument.nudgeSelection(dx: -1, dy: 0); refreshAll() }
    @objc func nudgeSelectionRight(_ sender: Any?) { _ = canvasDocument.nudgeSelection(dx: 1, dy: 0); refreshAll() }
    @objc func nudgeSelectionUp(_ sender: Any?) { _ = canvasDocument.nudgeSelection(dx: 0, dy: -1); refreshAll() }
    @objc func nudgeSelectionDown(_ sender: Any?) { _ = canvasDocument.nudgeSelection(dx: 0, dy: 1); refreshAll() }


    @objc func deselect(_ sender: Any?) { canvasDocument.deselect(); canvas.needsDisplay = true }

    @objc func zoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomOut() }

    @objc func zoomActual(_ sender: Any?) {
        canvas.setZoom(1.0, anchor: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
    }

    @objc func zoomFit(_ sender: Any?) { canvas.centerCanvas(zoomToFit: true) }

    @objc func toggleInspector(_ sender: Any?) {
        inspector.isHidden.toggle()
    }

    @objc func rotateCanvas(_ sender: Any?) {
        canvasDocument.rotate90(clockwise: true)
        refreshAll()
    }

    @objc func flipCanvasHorizontal(_ sender: Any?) {
        canvasDocument.flip(horizontal: true)
        refreshAll()
    }

    @objc func flipCanvasVertical(_ sender: Any?) {
        canvasDocument.flip(horizontal: false)
        refreshAll()
    }

    @objc func invertColors(_ sender: Any?) {
        canvasDocument.invertColors()
        refreshAll()
    }

    @objc func resizeImage(_ sender: Any?) { showResizeDialog() }

    @objc func adjustmentsAction(_ sender: Any?) {
        AdjustmentsPanel.present(for: window, document: canvasDocument) { [weak self] in
            self?.refreshAll()
        }
    }

    @objc func removeBackgroundAction(_ sender: Any?) {
        BackgroundRemovalAction.presentPanel(for: window, document: canvasDocument) { [weak self] count in
            self?.statusBar.message = "Removed \(count) background pixels"
            self?.refreshAll()
        }
    }

    @objc func createImageAction(_ sender: Any?) {
        ImageCreatorPanel.present(for: window, document: canvasDocument) { [weak self] in
            self?.refreshAll()
        }
    }

    @objc func duplicateLayerAction(_ sender: Any?) {
        canvasDocument.duplicateLayer(at: canvasDocument.activeLayerIndex)
        refreshAll()
    }

    @objc func cropToSelection(_ sender: Any?) {
        guard let sel = canvasDocument.selection, !sel.isEmpty else {
            statusBar.message = "Select an area first"
            return
        }
        canvasDocument.crop(to: sel.bounds)
        refreshAll()
    }


    // MARK: Layer actions (menu/ribbon)

    @objc func addLayerAction(_ sender: Any?) {
        _ = canvasDocument.addLayer()
        refreshAll()
    }

    @objc func mergeLayerAction(_ sender: Any?) {
        canvasDocument.mergeLayerDown(at: canvasDocument.activeLayerIndex)
        refreshAll()
    }

    @objc func deleteLayerAction(_ sender: Any?) {
        canvasDocument.removeLayer(at: canvasDocument.activeLayerIndex)
        refreshAll()
    }

    // MARK: Dialogs

    private func showColorPicker() {
        let panel = NSColorPanel.shared
        panel.color = settings.primaryColor.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        settings.primaryColor = PixelColor.from(sender.color)
        palette.primary = settings.primaryColor
        ribbon?.refreshColors()
    }

    private func showResizeDialog() {
        let dialog = ResizeDialog(current: canvasDocument.canvasSize)
        dialog.onApply = { [weak self] size, mode in
            guard let self else { return }
            switch mode {
            case .canvas:
                self.canvasDocument.resizeCanvas(to: Int(size.width), newHeight: Int(size.height))
            case .image:
                self.canvasDocument.resizeImage(to: Int(size.width), newHeight: Int(size.height))
            }
            self.canvas.centerCanvas(zoomToFit: true)
            self.refreshAll()
        }
        dialog.present(for: window)
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard canvasDocument.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(canvasDocument.documentName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            saveDocument(nil)
            return !canvasDocument.dirty
        }
        return response == .alertSecondButtonReturn
    }

    private func presentError(_ error: Error, message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Swaps the editing document (used when a file is opened from Finder).
    func replaceDocument(_ newDocument: Document) {
        canvasDocument.delegate = nil
        canvasDocument = newDocument
        canvasDocument.delegate = self
        rebuildCanvas()
        refreshAll()
        window?.title = newDocument.documentName
        window?.makeKeyAndOrderFront(nil)
    }

    private func rebuildCanvas() {
        let newCanvas = CanvasView(document: canvasDocument, settings: settings, tools: tools)
        newCanvas.context.canvasView = newCanvas
        newCanvas.frame = canvas.frame
        newCanvas.onZoomChanged = canvas.onZoomChanged
        newCanvas.onCursorMoved = canvas.onCursorMoved
        newCanvas.onStatusMessage = canvas.onStatusMessage
        if let old = canvas, let superview = old.superview {
            superview.replaceSubview(old, with: newCanvas)
            newCanvas.translatesAutoresizingMaskIntoConstraints = false
            newCanvas.frame = old.frame
        }
        canvas = newCanvas
        inspector.document = canvasDocument
        statusBar.canvasSize = canvasDocument.canvasSize
        syncTool()
        canvas.centerCanvas(zoomToFit: true)
    }

    func refreshAll() {
        inspector.document = canvasDocument
        inspector.refresh()
        statusBar.canvasSize = canvasDocument.canvasSize
        canvas.needsDisplay = true
        canvas.context.canvasSize = canvasDocument.canvasSize
        ribbon?.refresh()
    }

    // MARK: Window delegate

    func windowWillClose(_ notification: Notification) {
        // Autosave a crash-recovery copy (enhancement hook; no prompt on close).
    }
}

// MARK: - Document delegate

extension WorkspaceController: DocumentDelegate {
    func documentDidChange(_ doc: Document, region: CGRect?) {
        canvas.needsDisplay = true
        inspector.refresh()
    }

    func documentLayersDidChange(_ doc: Document) {
        inspector.refresh()
        canvas.needsDisplay = true
    }

    func documentSelectionDidChange(_ doc: Document) {
        canvas.needsDisplay = true
        if let sel = doc.selection, !sel.isEmpty {
            statusBar.selectionSize = sel.bounds.size
        } else {
            statusBar.selectionSize = nil
        }
    }

    func documentHistoryDidChange(_ doc: Document) {
        inspector.refreshHistory()
    }

    func documentDidChangeName(_ doc: Document) {
        window?.title = doc.documentName
    }
}
