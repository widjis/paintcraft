import AppKit

/// Zoom presets and helpers shared by the canvas and the View ribbon.
struct ZoomLevel: Equatable {
    var scale: CGFloat

    static let minimum: CGFloat = 0.125   // 12.5 %
    static let maximum: CGFloat = 8.0     // 800 %

    static let presets: [(title: String, scale: CGFloat)] = [
        ("12.5%", 0.125), ("25%", 0.25), ("50%", 0.5), ("100%", 1.0),
        ("200%", 2.0), ("400%", 4.0), ("800%", 8.0)
    ]

    var percentText: String {
        let pct = scale * 100
        if pct < 100 { return String(format: "%.1f%%", pct) }
        return String(format: "%.0f%%", pct)
    }

    static func clamp(_ s: CGFloat) -> CGFloat {
        min(maximum, max(minimum, s))
    }

    static func nextPreset(after scale: CGFloat) -> CGFloat {
        let all = presets.map { $0.scale }
        return all.first(where: { $0 > scale + 0.0001 }) ?? maximum
    }

    static func previousPreset(before scale: CGFloat) -> CGFloat {
        let all = presets.map { $0.scale }
        return all.last(where: { $0 < scale - 0.0001 }) ?? minimum
    }
}

/// The drawing surface. Hosts all viewport state (zoom, pan), composites the
/// document, draws rulers/grid/overlays, and routes mouse input to the active tool.
final class CanvasView: NSView {
    weak var document: Document? {
        didSet { needsDisplay = true }
    }

    var settings: ToolSettings
    var context: ToolContext
    var currentTool: Tool?
    var tools: ToolRegistry
    let guidesOverlay = GuidesOverlay()

    /// Zoom scale: 1.0 = one image pixel per point.
    var zoomScale: CGFloat = 1.0 {
        didSet {
            zoomScale = ZoomLevel.clamp(zoomScale)
            invalidateZoomCaches()
            needsDisplay = true
            onZoomChanged?(zoomScale)
        }
    }

    /// Canvas origin within the view (points), top-left image corner.
    var canvasOrigin: CGPoint = .zero

    var onZoomChanged: ((CGFloat) -> Void)?
    var onToolShortcut: ((ToolKind) -> Void)?
    private var userAdjustedZoom = false
    var onCursorMoved: ((CGPoint?) -> Void)?
    var onStatusMessage: ((String) -> Void)?

    private var backingScale: CGFloat = 2.0
    private var panStart: NSPoint?
    private var panOriginStart: CGPoint?
    private var spaceDown = false
    private var trackingTimer: Timer?

    /// Cached checkerboard + canvas shadow, regenerated on zoom/size changes.
    private var backgroundLayer: CALayer?

    init(document: Document, settings: ToolSettings, tools: ToolRegistry) {
        self.document = document
        self.settings = settings
        self.tools = tools
        self.context = ToolContext(document: document, settings: settings)
        super.init(frame: .zero)
        wantsLayer = true
        configureContext()
        if let tool = tools.instance(for: settings.tool) {
            self.currentTool = tool
            tool.activate(in: context)
        }
        self.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configureContext() {
        context.canvasSize = document?.canvasSize ?? .zero
        context.requestRedraw = { [weak self] rect in
            guard let self else { return }
            if let r = rect {
                self.setNeedsDisplay(self.viewRect(forImageRect: r).insetBy(dx: -2, dy: -2))
            } else {
                self.needsDisplay = true
            }
        }
        context.setZoom = { [weak self] z in
            guard let self else { return }
            self.setZoom(z, anchor: CGPoint(x: self.bounds.midX, y: self.bounds.midY))
        }
        context.setPrimaryColor = { [weak self] c in self?.settings.primaryColor = c }
        context.statusMessage = { [weak self] m in self?.onStatusMessage?(m) }
        context.beginTextEditing = { [weak self] rect in
            self?.onStatusMessage?("Text tool: type on canvas (v1.1)")
        }
    }

    // MARK: Layout & zoom

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        backingScale = window?.backingScaleFactor ?? 2.0
        centerCanvas(zoomToFit: true)
    }

    private var didInitialFit = false

    override func layout() {
        super.layout()
        guard bounds.width > 120, bounds.height > 120 else { return }
        if !userAdjustedZoom {
            // Keep the whole canvas fitted until the user chooses a zoom.
            centerCanvas(zoomToFit: true)
            didInitialFit = true
        } else {
            clampPan()
        }
        needsDisplay = true
    }

    private func invalidateZoomCaches() {
        backgroundLayer?.removeFromSuperlayer()
        backgroundLayer = nil
    }

    func centerCanvas(zoomToFit: Bool) {
        guard let doc = document else { return }
        if zoomToFit, bounds.width > 20, bounds.height > 20 {
            let sx = (bounds.width - 80) / CGFloat(doc.width)
            let sy = (bounds.height - 80) / CGFloat(doc.height)
            let fit = min(sx, sy)
            zoomScale = ZoomLevel.clamp(min(1.0, fit))
            zoomScale = max(fit > 1 ? min(fit, 1.0) : fit, ZoomLevel.minimum)
        }
        let scaledW = CGFloat(doc.width) * zoomScale
        let scaledH = CGFloat(doc.height) * zoomScale
        canvasOrigin = CGPoint(x: (bounds.width - scaledW) / 2,
                               y: (bounds.height - scaledH) / 2)
        needsDisplay = true
        onZoomChanged?(zoomScale)
    }

    func setZoom(_ scale: CGFloat, anchor: CGPoint) {
        let newScale = ZoomLevel.clamp(scale)
        guard abs(newScale - zoomScale) > 0.00001 else { return }
        userAdjustedZoom = true
        // Keep the image point under the anchor stationary.
        let imagePoint = imagePoint(at: anchor)
        zoomScale = newScale
        // Solve origin so imagePoint maps back to anchor.
        canvasOrigin = CGPoint(x: anchor.x - imagePoint.x * zoomScale,
                               y: anchor.y - imagePoint.y * zoomScale)
        clampPan()
        needsDisplay = true
    }

    func zoomIn() {
        userAdjustedZoom = true
        setZoom(ZoomLevel.nextPreset(after: zoomScale), anchor: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomOut() {
        userAdjustedZoom = true
        setZoom(ZoomLevel.previousPreset(before: zoomScale), anchor: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        setZoom(zoomScale * (1.0 + event.magnification), anchor: anchor)
    }

    override func scrollWheel(with event: NSEvent) {
        // Two-finger scroll pans; pinch handles zoom.
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if event.modifierFlags.contains(.command) {
            let anchor = convert(event.locationInWindow, from: nil)
            setZoom(zoomScale * (1.0 + dy * 0.005), anchor: anchor)
            return
        }
        canvasOrigin.x += dx
        canvasOrigin.y += dy
        clampPan()
        needsDisplay = true
    }

    private func clampPan() {
        guard let doc = document else { return }
        let scaledW = CGFloat(doc.width) * zoomScale
        let scaledH = CGFloat(doc.height) * zoomScale
        let minVisible: CGFloat = 60
        // Allow free panning but keep at least a sliver of the canvas reachable.
        canvasOrigin.x = min(bounds.width - minVisible, max(minVisible - scaledW, canvasOrigin.x))
        canvasOrigin.y = min(bounds.height - minVisible, max(minVisible - scaledH, canvasOrigin.y))
    }

    // MARK: Coordinate conversion

    func imagePoint(at viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - canvasOrigin.x) / zoomScale,
                y: (viewPoint.y - canvasOrigin.y) / zoomScale)
    }

    func viewRect(forImageRect r: CGRect) -> CGRect {
        CGRect(x: canvasOrigin.x + r.minX * zoomScale,
               y: canvasOrigin.y + r.minY * zoomScale,
               width: r.width * zoomScale,
               height: r.height * zoomScale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Workspace background (classic light-gray "desk").
        let desk = isDarkMode ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.90, alpha: 1)
        ctx.setFillColor(desk.cgColor)
        ctx.fill(dirtyRect)

        guard let doc = document else { return }
        let canvasRect = viewRect(forImageRect: CGRect(x: 0, y: 0, width: doc.width, height: doc.height))

        // Drop shadow around the "paper".
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(canvasRect)
        ctx.restoreGState()

        drawTransparencyCheckerboard(in: ctx, rect: canvasRect)

        if let composite = doc.compositeImage() {
            drawComposite(composite, in: ctx, canvasRect: canvasRect)
        }

        // Pixel grid at high zoom (enhancement, toggleable).
        if settings.showPixelGrid && zoomScale >= 4.0 {
            drawPixelGrid(in: ctx, canvasRect: canvasRect)
        }

        // Rulers (enhancement).
        if settings.showRulers {
            drawRulers(in: ctx, canvasRect: canvasRect)
        }

        // Canvas border.
        ctx.setStrokeColor((isDarkMode ? NSColor(calibratedWhite: 0.45, alpha: 1) : NSColor(calibratedWhite: 0.55, alpha: 1)).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(canvasRect.insetBy(dx: -0.5, dy: -0.5))

        // Selection marching ants.
        if let sel = doc.selection, !sel.isEmpty {
            drawSelection(sel, in: ctx)
        }

        // Smart alignment guides (enhancement).
        guidesOverlay.sync(to: self)
        guidesOverlay.isVisible = settings.showGuides
        guidesOverlay.draw(in: ctx, canvasView: self, imageRect: canvasRect)

        // Active tool feedback.
        if let tool = currentTool {
            ctx.saveGState()
            // Convert image space -> view space so tools can draw in pixels.
            ctx.translateBy(x: canvasOrigin.x, y: canvasOrigin.y)
            ctx.scaleBy(x: zoomScale, y: zoomScale)
            tool.drawOverlay(in: context, viewContext: ctx, canvasView: self)
            ctx.restoreGState()
        }
    }

    private func drawTransparencyCheckerboard(in ctx: CGContext, rect: CGRect) {
        let cell: CGFloat = 8
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(NSColor(calibratedWhite: 0.92, alpha: 1).cgColor)
        ctx.fill(rect)
        ctx.setFillColor(NSColor(calibratedWhite: 0.80, alpha: 1).cgColor)
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : cell)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell * 2
            }
            y += cell
            row += 1
        }
        ctx.restoreGState()
    }

    private func drawComposite(_ image: CGImage, in ctx: CGContext, canvasRect: CGRect) {
        // Flip: CGImage draws bottom-up in flipped views; use a saved state with
        // a transform so the image lands upright.
        ctx.saveGState()
        ctx.interpolationQuality = zoomScale >= 1.0 ? .none : .high
        ctx.translateBy(x: canvasRect.minX, y: canvasRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: canvasRect.width, height: canvasRect.height))
        ctx.restoreGState()
    }

    private func drawPixelGrid(in ctx: CGContext, canvasRect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: canvasRect)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(1.0 / backingScale)
        guard let doc = document else { return }
        var x = canvasRect.minX
        let step = zoomScale
        while x <= canvasRect.maxX + 0.5 {
            ctx.move(to: CGPoint(x: x, y: canvasRect.minY))
            ctx.addLine(to: CGPoint(x: x, y: canvasRect.maxY))
            x += step
        }
        var y = canvasRect.minY
        while y <= canvasRect.maxY + 0.5 {
            ctx.move(to: CGPoint(x: canvasRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: canvasRect.maxX, y: y))
            y += step
        }
        ctx.strokePath()
        ctx.restoreGState()
        _ = doc
    }

    private func drawRulers(in ctx: CGContext, canvasRect: CGRect) {
        let rulerSize: CGFloat = 18
        let topRect = CGRect(x: 0, y: 0, width: bounds.width, height: rulerSize)
        let leftRect = CGRect(x: 0, y: 0, width: rulerSize, height: bounds.height)
        let bg = isDarkMode ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(topRect)
        ctx.fill(leftRect)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [CGPoint(x: 0, y: rulerSize), CGPoint(x: bounds.width, y: rulerSize)])
        ctx.strokeLineSegments(between: [CGPoint(x: rulerSize, y: 0), CGPoint(x: rulerSize, y: bounds.height)])

        // Ticks every 10 image px (scaled), labels every 50.
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
        let stepPx: CGFloat = 10
        var ip = 0.0
        let maxImgX = Double(bounds.width) / Double(zoomScale) + Double(canvasOrigin.x) / Double(zoomScale)
        while ip < maxImgX {
            let vx = canvasOrigin.x + CGFloat(ip) * zoomScale
            if vx > 0 && vx < bounds.width {
                let tall = Int(ip) % 50 == 0
                ctx.move(to: CGPoint(x: vx, y: rulerSize))
                ctx.addLine(to: CGPoint(x: vx, y: rulerSize - (tall ? 8 : 4)))
                if tall {
                    let s = String(format: "%.0f", ip)
                    (s as NSString).draw(at: CGPoint(x: vx + 2, y: 1), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor
                    ])
                }
            }
            ip += Double(stepPx)
        }
        ctx.strokePath()
    }

    private func drawSelection(_ sel: SelectionModel, in ctx: CGContext) {
        let viewPath = CGMutablePath()
        viewPath.addRect(viewRect(forImageRect: sel.bounds))
        ctx.saveGState()
        ctx.addPath(viewPath)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 5])
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineDash(phase: 5, lengths: [5, 5])
        ctx.strokePath()
        ctx.restoreGState()
    }

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: Events

    private func imagePointFromEvent(_ event: NSEvent) -> CGPoint {
        let vp = convert(event.locationInWindow, from: nil)
        return imagePoint(at: vp)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceDown {
            panStart = convert(event.locationInWindow, from: nil)
            panOriginStart = canvasOrigin
            NSCursor.closedHand.push()
            return
        }
        let p = imagePointFromEvent(event)
        onCursorMoved?(p)
        if let doc = document {
            guidesOverlay.sync(to: self)
            guidesOverlay.beginInteraction(in: doc)
        }
        currentTool?.mouseDown(at: p, context: context)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = panStart, let origin = panOriginStart {
            let now = convert(event.locationInWindow, from: nil)
            canvasOrigin = CGPoint(x: origin.x + (now.x - start.x), y: origin.y + (now.y - start.y))
            clampPan()
            needsDisplay = true
            return
        }
        let p = imagePointFromEvent(event)
        onCursorMoved?(p)
        currentTool?.mouseDragged(to: p, context: context)
        if let doc = document {
            guidesOverlay.sync(to: self)
            guidesOverlay.computeGuides(for: CGRect(x: p.x, y: p.y, width: 1, height: 1), document: doc)
        }
        needsDisplay = true
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-button drag pans, so tools keep Option for their own modifiers.
        panStart = convert(event.locationInWindow, from: nil)
        panOriginStart = canvasOrigin
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let start = panStart, let origin = panOriginStart else { return }
        let now = convert(event.locationInWindow, from: nil)
        canvasOrigin = CGPoint(x: origin.x + (now.x - start.x), y: origin.y + (now.y - start.y))
        clampPan()
        needsDisplay = true
    }

    override func otherMouseUp(with event: NSEvent) {
        if panStart != nil {
            panStart = nil
            panOriginStart = nil
            NSCursor.pop()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if panStart != nil {
            panStart = nil
            panOriginStart = nil
            NSCursor.pop()
            return
        }
        let p = imagePointFromEvent(event)
        currentTool?.mouseUp(at: p, context: context)
        guidesOverlay.endInteraction()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = imagePointFromEvent(event)
        onCursorMoved?(p)
        currentTool?.mouseMoved(to: p, context: context)
        if let doc = document {
            guidesOverlay.sync(to: self)
            guidesOverlay.computeGuides(for: CGRect(x: p.x, y: p.y, width: 1, height: 1), document: doc)
            needsDisplay = true
        }
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        onCursorMoved?(nil)
        guidesOverlay.clear()
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        if let tool = currentTool, tool.keyDown(event, context: context) { return }
        if event.keyCode == 53 { // Escape
            currentTool?.cancel(in: context)
            needsDisplay = true
            return
        }
        // Paint-compatible single-letter tool shortcuts.
        if !event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           let kind = ToolKind.shortcutKind(for: chars) {
            onToolShortcut?(kind)
            return
        }
        // Space to pan
        if event.keyCode == 49 && !event.isARepeat {
            spaceDown = true
            NSCursor.openHand.push()
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            NSCursor.pop()
            return
        }
        super.keyUp(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentTool?.cursorName.make() ?? .crosshair)
    }

    private func updateCursor() {
        guard let tool = currentTool else { return }
        tool.cursorName.make().set()
    }
}
