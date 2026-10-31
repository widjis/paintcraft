import AppKit

// MARK: - App entry (no storyboard, programmatic AppKit)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: WorkspaceController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        // Command-line document opening (used by the verification harness):
        //   PaintCraft --open path/to/file.paintcraft
        var initial: Document? = nil
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            if let opened = try? FileIO.open(url: url) {
                initial = opened.0
            }
        }
        let ws = WorkspaceController(document: initial)
        workspace = ws
        ws.showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Documents opened from Finder / `open -a`.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openDocument(at: URL(fileURLWithPath: filename))
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        _ = openDocument(at: first)
    }

    @discardableResult
    private func openDocument(at url: URL) -> Bool {
        guard let opened = try? FileIO.open(url: url) else { return false }
        if let ws = workspace {
            ws.replaceDocument(opened.0)
        } else {
            let ws = WorkspaceController(document: opened.0)
            workspace = ws
            ws.showWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { workspace?.showWindow() }
        return true
    }

    // MARK: Action forwarding
    // Menu items use the responder chain. These forwarders guarantee every
    // PaintCraft command resolves even when the window controller is not the
    // first responder.
    @objc func undo(_ sender: Any?) { workspace?.undo(sender) }
    @objc func redo(_ sender: Any?) { workspace?.redo(sender) }
    @objc func newDocument(_ sender: Any?) { workspace?.newDocument(sender) }
    @objc func openDocument(_ sender: Any?) { workspace?.openDocument(sender) }
    @objc func saveDocument(_ sender: Any?) { workspace?.saveDocument(sender) }
    @objc func saveDocumentAs(_ sender: Any?) { workspace?.saveDocumentAs(sender) }
    @objc func exportImage(_ sender: Any?) { workspace?.exportImage(sender) }
    @objc func selectAll(_ sender: Any?) { workspace?.selectAll(sender) }
    @objc func deselect(_ sender: Any?) { workspace?.deselect(sender) }
    @objc func zoomIn(_ sender: Any?) { workspace?.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { workspace?.zoomOut(sender) }
    @objc func zoomActual(_ sender: Any?) { workspace?.zoomActual(sender) }
    @objc func zoomFit(_ sender: Any?) { workspace?.zoomFit(sender) }
    @objc func toggleInspector(_ sender: Any?) { workspace?.toggleInspector(sender) }
    @objc func rotateCanvas(_ sender: Any?) { workspace?.rotateCanvas(sender) }
    @objc func flipCanvasHorizontal(_ sender: Any?) { workspace?.flipCanvasHorizontal(sender) }
    @objc func flipCanvasVertical(_ sender: Any?) { workspace?.flipCanvasVertical(sender) }
    @objc func invertColors(_ sender: Any?) { workspace?.invertColors(sender) }
    @objc func resizeImage(_ sender: Any?) { workspace?.resizeImage(sender) }
    @objc func cropToSelection(_ sender: Any?) { workspace?.cropToSelection(sender) }
    @objc func addLayerAction(_ sender: Any?) { workspace?.addLayerAction(sender) }
    @objc func mergeLayerAction(_ sender: Any?) { workspace?.mergeLayerAction(sender) }
    @objc func duplicateLayerAction(_ sender: Any?) { workspace?.duplicateLayerAction(sender) }
    @objc func deleteLayerAction(_ sender: Any?) { workspace?.deleteLayerAction(sender) }
    @objc func adjustmentsAction(_ sender: Any?) { workspace?.adjustmentsAction(sender) }
    @objc func removeBackgroundAction(_ sender: Any?) { workspace?.removeBackgroundAction(sender) }
    @objc func createImageAction(_ sender: Any?) { workspace?.createImageAction(sender) }
    @objc(copy:) func copyAction(_ sender: Any?) { workspace?.copyAction(sender) }
    @objc(cut:) func cutAction(_ sender: Any?) { workspace?.cutAction(sender) }
    @objc(paste:) func pasteAction(_ sender: Any?) { workspace?.pasteAction(sender) }
    @objc func deleteSelection(_ sender: Any?) { workspace?.deleteSelection(sender) }

    // MARK: Main menu (responder-chain driven; Paint-compatible shortcuts)

    private func buildMainMenu() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About PaintCraft",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: nil, keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PaintCraft", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PaintCraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        addItem(fileMenu, "New", #selector(WorkspaceController.newDocument(_:)), "n")
        addItem(fileMenu, "Open…", #selector(WorkspaceController.openDocument(_:)), "o")
        fileMenu.addItem(.separator())
        addItem(fileMenu, "Save", #selector(WorkspaceController.saveDocument(_:)), "s")
        addItem(fileMenu, "Save As…", #selector(WorkspaceController.saveDocumentAs(_:)), "S")
        addItem(fileMenu, "Export Image…", #selector(WorkspaceController.exportImage(_:)), "e")
        fileMenu.addItem(.separator())
        addItem(fileMenu, "Close", #selector(NSWindow.performClose(_:)), "w")

        // Edit menu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        addItem(editMenu, "Undo", Selector(("undo:")), "z")
        let redo = addItem(editMenu, "Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        addItem(editMenu, "Cut", #selector(NSText.cut(_:)), "x")
        addItem(editMenu, "Copy", #selector(NSText.copy(_:)), "c")
        addItem(editMenu, "Paste", #selector(NSText.paste(_:)), "v")
        editMenu.addItem(.separator())
        addItem(editMenu, "Select All", #selector(WorkspaceController.selectAll(_:)), "a")
        addItem(editMenu, "Deselect", #selector(WorkspaceController.deselect(_:)), "d")
        addItem(editMenu, "Delete Selection", #selector(WorkspaceController.deleteSelection(_:)), "")

        // Image menu
        let imageItem = NSMenuItem()
        main.addItem(imageItem)
        let imageMenu = NSMenu(title: "Image")
        imageItem.submenu = imageMenu
        addItem(imageMenu, "Resize…", #selector(WorkspaceController.resizeImage(_:)), "")
        addItem(imageMenu, "Crop to Selection", #selector(WorkspaceController.cropToSelection(_:)), "")
        imageMenu.addItem(.separator())
        addItem(imageMenu, "Rotate 90° Clockwise", #selector(WorkspaceController.rotateCanvas(_:)), "")
        addItem(imageMenu, "Flip Horizontal", #selector(WorkspaceController.flipCanvasHorizontal(_:)), "")
        addItem(imageMenu, "Flip Vertical", #selector(WorkspaceController.flipCanvasVertical(_:)), "")
        addItem(imageMenu, "Invert Colors", #selector(WorkspaceController.invertColors(_:)), "")
        imageMenu.addItem(.separator())
        addItem(imageMenu, "Remove Background…", #selector(WorkspaceController.removeBackgroundAction(_:)), "")
        addItem(imageMenu, "Image Creator…", #selector(WorkspaceController.createImageAction(_:)), "")
        imageMenu.addItem(.separator())
        addItem(imageMenu, "Adjustments…", #selector(WorkspaceController.adjustmentsAction(_:)), "")

        // Layers menu
        let layersItem = NSMenuItem()
        main.addItem(layersItem)
        let layersMenu = NSMenu(title: "Layers")
        layersItem.submenu = layersMenu
        addItem(layersMenu, "Add Layer", #selector(WorkspaceController.addLayerAction(_:)), "")
        addItem(layersMenu, "Duplicate Layer", #selector(WorkspaceController.duplicateLayerAction(_:)), "")
        addItem(layersMenu, "Delete Layer", #selector(WorkspaceController.deleteLayerAction(_:)), "")
        addItem(layersMenu, "Merge Down", #selector(WorkspaceController.mergeLayerAction(_:)), "")

        // Tools menu
        let toolsItem = NSMenuItem()
        main.addItem(toolsItem)
        let toolsMenu = NSMenu(title: "Tools")
        toolsItem.submenu = toolsMenu
        for kind in ToolKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(WorkspaceController.selectToolFromMenu(_:)), keyEquivalent: "")
            item.tag = ToolKind.allCases.firstIndex(of: kind) ?? 0
            item.target = nil
            toolsMenu.addItem(item)
        }

        // View menu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        addItem(viewMenu, "Zoom In", #selector(WorkspaceController.zoomIn(_:)), "+")
        addItem(viewMenu, "Zoom Out", #selector(WorkspaceController.zoomOut(_:)), "-")
        addItem(viewMenu, "Actual Size", #selector(WorkspaceController.zoomActual(_:)), "1")
        addItem(viewMenu, "Fit to Window", #selector(WorkspaceController.zoomFit(_:)), "0")
        viewMenu.addItem(.separator())
        addItem(viewMenu, "Toggle Layers Panel", #selector(WorkspaceController.toggleInspector(_:)), "l")

        // Window menu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        menu.addItem(item)
        return item
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--selftest") {
    // Headless verification path: no windows, no event loop.
    exit(Int32(SelfTest.run()))
}

if CommandLine.arguments.contains("--make-demo") {
    // Generates the demo document through the real painting pipeline, then exits.
    let args = CommandLine.arguments
    let path: String
    if let i = args.firstIndex(of: "--make-demo"), i + 1 < args.count, !args[i + 1].hasPrefix("--") {
        path = args[i + 1]
    } else {
        path = "build/demo.paintcraft"
    }
    let doc = DemoScene.make()
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileIO.save(document: doc, to: url)
        print("DEMO OK -> \(url.path) (\(doc.layers.count) layers, \(doc.width)x\(doc.height))")
        exit(0)
    } catch {
        print("DEMO FAILED: \(error)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
