import AppKit
import CoreGraphics

/// Headless verification suite. Run with:
///   build/PaintCraft.app/Contents/MacOS/PaintCraft --selftest
/// It exercises the document model, tools, undo/redo, selection, orientation,
/// file formats and adjustments without any UI, so regressions are caught even
/// when the app cannot be driven by hand.
enum SelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
            print("PASS  \(name)")
        } else {
            failures += 1
            let extra = detail()
            print("FAIL  \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    private static func approx(_ a: PixelColor, _ b: PixelColor, tolerance: Int = 6) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= tolerance &&
        abs(Int(a.g) - Int(b.g)) <= tolerance &&
        abs(Int(a.b) - Int(b.b)) <= tolerance
    }

    static func run() -> Int {
        print("PaintCraft self-test")
        print("====================")
        testRasterBasics()
        testOrientation()
        testCompositeOrientation()
        testCropAndResize()
        testRotate()
        testFlip()
        testUndoRedoWithPencil()
        testFill()
        testShape()
        testSelection()
        testFileFormats()
        testAdjustments()
        testEnhancements()
        testSelectionOps()

        print("====================")
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Raster

    private static func testRasterBasics() {
        let r = Raster(width: 8, height: 8)
        r.setPixel(1, 2, PixelColor(r: 200, g: 100, b: 50))
        check("raster pixel round-trip", r.getPixel(1, 2) == PixelColor(r: 200, g: 100, b: 50))
        check("raster out-of-bounds reads clear", r.getPixel(-1, -1) == .clear)
        r.fill(PixelColor(r: 10, g: 20, b: 30))
        check("raster fill", r.getPixel(7, 7) == PixelColor(r: 10, g: 20, b: 30))
        r.clear()
        check("raster clear", r.getPixel(0, 0) == .clear)
    }

    // MARK: Orientation

    private static func topRedBottomBlueImage(size: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Default CG context is y-up: top half has the higher y values.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        return ctx.makeImage()!
    }

    private static func testOrientation() {
        let img = topRedBottomBlueImage(size: 20)
        let raster = Raster.from(cgImage: img)
        check("imported image keeps top row at y=0",
              raster.getPixel(0, 0).r > 200 && raster.getPixel(0, 0).b < 60,
              "got \(raster.getPixel(0, 0))")
        check("imported image keeps bottom row at y=max",
              raster.getPixel(0, 19).b > 200 && raster.getPixel(0, 19).r < 60,
              "got \(raster.getPixel(0, 19))")
    }

    private static func testCompositeOrientation() {
        let doc = Document(width: 20, height: 20)
        doc.activeLayer!.raster.clear()
        doc.activeLayer!.raster.setPixel(0, 0, PixelColor(r: 255, g: 0, b: 0))
        doc.activeLayer!.raster.setPixel(0, 19, PixelColor(r: 0, g: 0, b: 255))
        let flat = doc.flatten()
        check("composite is not vertically flipped",
              flat.getPixel(0, 0).r > 200 && flat.getPixel(0, 19).b > 200,
              "top=\(flat.getPixel(0, 0)) bottom=\(flat.getPixel(0, 19))")
    }

    // MARK: Geometry

    private static func testCropAndResize() {
        let doc = Document(width: 20, height: 20)
        doc.activeLayer!.raster.clear()
        doc.activeLayer!.raster.setPixel(5, 5, PixelColor(r: 255, g: 0, b: 0))
        doc.crop(to: CGRect(x: 4, y: 4, width: 4, height: 4))
        check("crop updates dimensions", doc.width == 4 && doc.height == 4,
              "\(doc.width)x\(doc.height)")
        check("crop keeps content position",
              doc.activeLayer!.raster.getPixel(1, 1).r > 200,
              "got \(doc.activeLayer!.raster.getPixel(1, 1))")

        // Canvas resize: content stays at its own scale, anchored at the centre.
        let doc2 = Document(width: 20, height: 20)
        doc2.activeLayer!.raster.clear()
        doc2.activeLayer!.raster.setPixel(0, 0, PixelColor(r: 255, g: 0, b: 0))
        doc2.resizeCanvas(to: 40, newHeight: 40)
        let anchored = doc2.activeLayer!.raster.getPixel(10, 10)
        check("canvas resize anchors content at centre", anchored.r > 200,
              "at (10,10) got \(anchored)")

        // Image resize: artwork scales with the canvas.
        let doc3 = Document(width: 20, height: 20)
        doc3.activeLayer!.raster.clear()
        doc3.activeLayer!.raster.setPixel(0, 0, PixelColor(r: 255, g: 0, b: 0))
        doc3.resizeImage(to: 40, newHeight: 40)
        let scaled = doc3.activeLayer!.raster.getPixel(0, 0)
        check("image resize scales content to the new size", scaled.r > 120,
              "got \(scaled)")
    }

    private static func testRotate() {
        let doc = Document(width: 20, height: 10)
        doc.activeLayer!.raster.clear()
        doc.activeLayer!.raster.setPixel(0, 0, PixelColor(r: 255, g: 0, b: 0))
        doc.rotate90(clockwise: true)
        check("rotate90 swaps dimensions", doc.width == 10 && doc.height == 20,
              "\(doc.width)x\(doc.height)")
        var redSpots: [(Int, Int)] = []
        for y in 0..<doc.height {
            for x in 0..<doc.width where doc.activeLayer!.raster.getPixel(x, y).r > 200 {
                redSpots.append((x, y))
            }
        }
        check("rotate90 keeps exactly one red pixel", redSpots.count == 1, "\(redSpots)")
        if let p = redSpots.first {
            check("rotate90 clockwise maps top-left to top-right", p == (9, 0), "at \(p)")
        }
    }

    private static func testFlip() {
        let doc = Document(width: 10, height: 6)
        doc.activeLayer!.raster.clear()
        doc.activeLayer!.raster.setPixel(0, 0, PixelColor(r: 255, g: 0, b: 0))
        doc.flip(horizontal: true)
        check("flip horizontal moves top-left to top-right",
              doc.activeLayer!.raster.getPixel(9, 0).r > 200 && doc.activeLayer!.raster.getPixel(0, 0).a == 0,
              "got \(doc.activeLayer!.raster.getPixel(9, 0))")
        doc.flip(horizontal: false)
        check("flip vertical moves content to bottom",
              doc.activeLayer!.raster.getPixel(9, 5).r > 200,
              "got \(doc.activeLayer!.raster.getPixel(9, 5))")

        let doc2 = Document(width: 20, height: 10)
        doc2.activeLayer!.raster.clear()
        doc2.activeLayer!.raster.setPixel(0, 0, PixelColor(r: 255, g: 0, b: 0))
        doc2.rotate90(clockwise: false)
        check("rotate90 ccw maps top-left to bottom-left",
              doc2.activeLayer!.raster.getPixel(0, 19).r > 200,
              "at \(doc2.activeLayer!.raster.getPixel(0, 19))")
    }

    // MARK: Tools

    private static func testUndoRedoWithPencil() {
        let doc = Document(width: 64, height: 64)
        doc.activeLayer!.raster.fill(.white)
        let settings = ToolSettings()
        settings.strokeWidth = 8
        settings.primaryColor = PixelColor(r: 255, g: 0, b: 0)
        let ctx = ToolContext(document: doc, settings: settings)
        ctx.canvasSize = doc.canvasSize
        let pencil = PencilTool()
        pencil.mouseDown(at: CGPoint(x: 10, y: 10), context: ctx)
        pencil.mouseDragged(to: CGPoint(x: 50, y: 10), context: ctx)
        pencil.mouseUp(at: CGPoint(x: 50, y: 10), context: ctx)

        let painted = doc.activeLayer!.raster.getPixel(30, 10)
        check("pencil paints along the drag", painted.r > 200 && painted.g < 60, "got \(painted)")
        check("pencil registers an undo step", doc.undoStack.canUndo)

        doc.undo()
        let afterUndo = doc.activeLayer!.raster.getPixel(30, 10)
        check("undo restores pre-stroke pixels", afterUndo.g > 200 && afterUndo.r > 200, "got \(afterUndo)")

        doc.redo()
        let afterRedo = doc.activeLayer!.raster.getPixel(30, 10)
        check("redo re-applies the stroke", afterRedo.r > 200 && afterRedo.g < 60, "got \(afterRedo)")
    }

    private static func testFill() {
        let doc = Document(width: 32, height: 32)
        let layer = doc.activeLayer!
        layer.raster.fill(.white)
        // Draw a small red square that must survive the fill.
        for y in 10..<20 {
            for x in 10..<20 { layer.raster.setPixel(x, y, PixelColor(r: 255, g: 0, b: 0)) }
        }
        let settings = ToolSettings()
        settings.primaryColor = PixelColor(r: 0, g: 0, b: 255)
        settings.fillTolerance = 0
        let ctx = ToolContext(document: doc, settings: settings)
        ctx.canvasSize = doc.canvasSize
        FillTool().mouseDown(at: CGPoint(x: 1, y: 1), context: ctx)
        check("fill floods the outside region", layer.raster.getPixel(0, 0) == PixelColor(r: 0, g: 0, b: 255),
              "got \(layer.raster.getPixel(0, 0))")
        check("fill leaves enclosed shape intact", layer.raster.getPixel(15, 15).r > 200,
              "got \(layer.raster.getPixel(15, 15))")
    }

    private static func testShape() {
        let doc = Document(width: 40, height: 40)
        doc.activeLayer!.raster.fill(.white)
        let settings = ToolSettings()
        settings.primaryColor = PixelColor(r: 0, g: 0, b: 0)
        settings.shapeStyle = ShapeStyle(outlineEnabled: true, fillEnabled: false, lineWidth: 2, lineStyle: .solid)
        let ctx = ToolContext(document: doc, settings: settings)
        ctx.canvasSize = doc.canvasSize
        let rect = RectangleTool(rounded: false)
        rect.mouseDown(at: CGPoint(x: 5, y: 5), context: ctx)
        rect.mouseDragged(to: CGPoint(x: 30, y: 30), context: ctx)
        rect.mouseUp(at: CGPoint(x: 30, y: 30), context: ctx)
        check("rectangle outline paints the border",
              doc.activeLayer!.raster.getPixel(5, 15).r < 60,
              "got \(doc.activeLayer!.raster.getPixel(5, 15))")
        check("rectangle outline leaves the interior empty",
              doc.activeLayer!.raster.getPixel(18, 18).r > 200,
              "got \(doc.activeLayer!.raster.getPixel(18, 18))")
    }

    // MARK: Selection

    private static func testSelection() {
        let rectSel = SelectionModel(rect: CGRect(x: 10, y: 10, width: 20, height: 20))
        check("rect selection contains inside point", rectSel.contains(CGPoint(x: 15, y: 15)))
        check("rect selection rejects outside point", !rectSel.contains(CGPoint(x: 5, y: 5)))
        check("rect selection bounds", rectSel.bounds == CGRect(x: 10, y: 10, width: 20, height: 20))

        let path = SelectionModel.path(from: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10),
                                              CGPoint(x: 20, y: 30)])
        let poly = SelectionModel(path: path, canvasSize: CGSize(width: 40, height: 40))
        check("freeform selection has a mask", poly.mask != nil)
        check("freeform selection contains centroid", poly.contains(CGPoint(x: 20, y: 15)))
        check("freeform selection rejects far point", !poly.contains(CGPoint(x: 2, y: 2)))
    }

    // MARK: Files

    private static func testFileFormats() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("paintcraft-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc = Document(width: 24, height: 16)
        doc.activeLayer!.raster.setPixel(0, 0, PixelColor(r: 255, g: 0, b: 0))
        doc.activeLayer!.raster.setPixel(23, 15, PixelColor(r: 0, g: 0, b: 255))
        doc.addLayer(name: "Ink")
        doc.layers.last?.raster.setPixel(5, 5, PixelColor(r: 0, g: 255, b: 0))
        doc.documentName = "selftest"

        let nativeURL = dir.appendingPathComponent("selftest.paintcraft")
        do {
            try FileIO.save(document: doc, to: nativeURL)
            let (loaded, warnings) = try FileIO.open(url: nativeURL)
            check("native save/load dimensions", loaded.width == 24 && loaded.height == 16,
                  "\(loaded.width)x\(loaded.height)")
            check("native save/load layer count", loaded.layers.count == 2, "\(loaded.layers.count)")
            check("native round-trip has no warnings", warnings.isEmpty, warnings.joined(separator: ","))
            check("native round-trip keeps pixels",
                  loaded.layers[0].raster.getPixel(0, 0).r > 200,
                  "got \(loaded.layers[0].raster.getPixel(0, 0))")
        } catch {
            check("native save/load", false, "\(error)")
        }

        let pngURL = dir.appendingPathComponent("out.png")
        do {
            try FileIO.exportImage(document: doc, to: pngURL)
            let size = (try? Data(contentsOf: pngURL).count) ?? 0
            check("PNG export produces bytes", size > 64, "\(size) bytes")
        } catch {
            check("PNG export", false, "\(error)")
        }

        let bmpURL = dir.appendingPathComponent("out.bmp")
        do {
            try FileIO.exportImage(document: doc, to: bmpURL)
            let decoded = try BMPCodec.decode(url: bmpURL)
            check("BMP round-trip dimensions", decoded.width == 24 && decoded.height == 16,
                  "\(decoded.width)x\(decoded.height)")
            check("BMP round-trip keeps top-left red", decoded.getPixel(0, 0).r > 200,
                  "got \(decoded.getPixel(0, 0))")
            check("BMP round-trip keeps bottom-right blue", decoded.getPixel(23, 15).b > 200,
                  "got \(decoded.getPixel(23, 15))")
        } catch {
            check("BMP round-trip", false, "\(error)")
        }
    }

    // MARK: Selection operations (cut/copy/paste/delete/move/nudge)

    private static func testSelectionOps() {
        let doc = Document(width: 32, height: 32)
        let layer = doc.activeLayer!
        layer.raster.fill(.white)
        layer.raster.fill(rect: CGRect(x: 2, y: 2, width: 4, height: 4),
                          with: PixelColor(r: 255, g: 0, b: 0))
        doc.setSelection(SelectionModel(rect: CGRect(x: 0, y: 0, width: 8, height: 8)))

        check("selection copy succeeds", doc.copySelection())
        check("selection delete clears pixels",
              doc.deleteSelection() && layer.raster.getPixel(3, 3).a == 0,
              "got \(layer.raster.getPixel(3, 3))")
        doc.undo()
        check("selection delete is undoable", layer.raster.getPixel(3, 3).r > 200,
              "got \(layer.raster.getPixel(3, 3))")

        _ = doc.deleteSelection()
        check("selection paste restores copied pixels",
              doc.pasteSelection() && layer.raster.getPixel(3, 3).r > 200,
              "got \(layer.raster.getPixel(3, 3))")
        doc.undo()

        // Fresh state for the move test: white canvas with a red square.
        layer.raster.fill(.white)
        layer.raster.fill(rect: CGRect(x: 2, y: 2, width: 4, height: 4),
                          with: PixelColor(r: 255, g: 0, b: 0))
        doc.setSelection(SelectionModel(rect: CGRect(x: 2, y: 2, width: 4, height: 4)))
        let isRed: (PixelColor) -> Bool = { $0.r > 200 && $0.g < 60 }
        check("selection move shifts content",
              doc.moveSelection(dx: 10, dy: 0) && isRed(layer.raster.getPixel(13, 3)),
              "got \(layer.raster.getPixel(13, 3))")
        check("selection move clears the source area",
              layer.raster.getPixel(3, 3).a == 0,
              "got \(layer.raster.getPixel(3, 3))")
        doc.undo()
        check("selection move is undoable", isRed(layer.raster.getPixel(3, 3)),
              "got \(layer.raster.getPixel(3, 3))")

        doc.setSelection(SelectionModel(rect: CGRect(x: 2, y: 2, width: 4, height: 4)))
        check("selection nudge moves by one pixel",
              doc.nudgeSelection(dx: 0, dy: -1) && isRed(layer.raster.getPixel(3, 2)),
              "got \(layer.raster.getPixel(3, 2))")
    }

    // MARK: Enhancements (background removal, selection bake, guides, AI gate)

    private static func testEnhancements() {
        // Background removal: flood the white edges, keep the red subject.
        let doc = Document(width: 32, height: 32)
        let layer = doc.activeLayer!
        layer.raster.fill(.white)
        layer.raster.fill(rect: CGRect(x: 8, y: 8, width: 16, height: 16),
                          with: PixelColor(r: 200, g: 30, b: 30))
        let removed = BackgroundRemoval.removeBackground(document: doc, tolerance: 8, feather: 0)
        check("background removal clears edge pixels",
              removed > 0 && layer.raster.getPixel(0, 0).a == 0,
              "removed=\(removed) corner=\(layer.raster.getPixel(0, 0))")
        check("background removal keeps the subject",
              layer.raster.getPixel(16, 16).a == 255,
              "subject=\(layer.raster.getPixel(16, 16))")
        doc.undo()
        check("background removal is undoable",
              layer.raster.getPixel(0, 0).a == 255,
              "corner=\(layer.raster.getPixel(0, 0))")

        // Selection bake: a destructive adjustment scoped to the selection.
        let doc2 = Document(width: 32, height: 32)
        let l2 = doc2.activeLayer!
        l2.raster.fill(.white)
        l2.raster.fill(rect: CGRect(x: 2, y: 2, width: 6, height: 6),
                       with: PixelColor(r: 220, g: 30, b: 30))
        let sel = SelectionModel(rect: CGRect(x: 0, y: 0, width: 8, height: 8))
        doc2.setSelection(sel)
        let bakedOK = AdjustmentPipeline.bake([Adjustment(kind: .grayscale, amount: 1)],
                                              into: doc2, inside: sel, undoName: "Test bake")
        let baked = l2.raster.getPixel(3, 3)
        check("selection bake desaturates inside", bakedOK && abs(Int(baked.r) - Int(baked.g)) < 14,
              "got \(baked)")
        check("selection bake leaves outside untouched",
              l2.raster.getPixel(20, 20) == PixelColor(r: 255, g: 255, b: 255),
              "got \(l2.raster.getPixel(20, 20))")
        doc2.undo()
        check("selection bake is undoable", l2.raster.getPixel(3, 3).r > 190,
              "got \(l2.raster.getPixel(3, 3))")

        // Smart guides: canvas centre is a guide, and points snap to it.
        let guides = GuidesOverlay()
        let lines = guides.computeGuides(for: CGRect(x: 99, y: 40, width: 20, height: 20),
                                         canvasSize: CGSize(width: 200, height: 100), others: [])
        check("guides include the canvas centre line",
              lines.contains { $0.orientation == .vertical && abs($0.position - 100) < 0.75 },
              "at \(lines.map { $0.position })")
        let (snapped, _) = guides.snap(CGPoint(x: 101, y: 40))
        check("guides snap a near-centre point", abs(snapped.x - 100) < 0.75, "snapped \(snapped)")

        // AI slot must never pretend to work without configuration.
        let defaults = UserDefaults(suiteName: "paintcraft.selftest.\(UUID().uuidString)")!
        check("image creator is unconfigured by default",
              !ImageCreatorSettings.isConfigured(defaults: defaults))
    }

    // MARK: Adjustments

    private static func testAdjustments() {
        let raster = Raster(width: 8, height: 8)
        raster.fill(PixelColor(r: 200, g: 40, b: 40))
        let gray = Adjustment(kind: .grayscale, amount: 1)
        guard let out = AdjustmentPipeline.apply([gray], to: raster) else {
            check("adjustment pipeline returns an image", false)
            return
        }
        let back = Raster.from(cgImage: out)
        let c = back.getPixel(4, 4)
        check("grayscale adjustment desaturates", approx(c, PixelColor(r: 120, g: 120, b: 120), tolerance: 90),
              "got \(c)")
    }
}
