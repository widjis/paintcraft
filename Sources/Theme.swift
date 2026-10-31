import AppKit

// MARK: - Design tokens
//
// Central place for the Paint-like visual language: adaptive (light/dark)
// colours, type ramp, spacing metrics, palette geometry and a handful of small
// reusable views (ribbon buttons, colour palette grid, primary/secondary
// swatch pair). Everything here is drawn with AppKit/NSBezierPath so the app
// stays dependency-free and appearance-aware.

enum Theme {

    // MARK: Metrics

    enum Metrics {
        /// Height the workspace controller gives the ribbon.
        static let ribbonHeight: CGFloat = 96
        /// Height of one ribbon group (content + uppercase header).
        static let ribbonGroupHeight: CGFloat = 84
        static let ribbonGroupPadding: CGFloat = 9
        static let groupHeaderHeight: CGFloat = 12
        static let cornerRadius: CGFloat = 5

        /// Main tool buttons (icon above a small label).
        static let toolButtonWidth: CGFloat = 44
        static let toolButtonHeight: CGFloat = 30

        static let shapeButton: CGFloat = 24
        static let iconButton: CGFloat = 25

        static let swatch: CGFloat = 13
        static let swatchGap: CGFloat = 1
        static let paletteColumns = 14
        static let paletteRows = 2

        static let layerThumbnail: CGFloat = 32
        static let layerRowHeight: CGFloat = 42

        static let inspectorMinWidth: CGFloat = 260
        static let inspectorInset: CGFloat = 10
    }

    // MARK: Colours (adaptive)

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
    }

    static let accent = NSColor.controlAccentColor

    /// Ribbon surface — Win11 "mica" ribbon is a touch lighter than the window.
    static var ribbonBackground: NSColor { dynamic(rgb(246, 246, 246), rgb(43, 43, 43)) }
    static var ribbonBorder: NSColor { dynamic(rgb(220, 220, 220), rgb(58, 58, 58)) }
    static var groupSeparator: NSColor { dynamic(rgb(226, 226, 226), rgb(62, 62, 62)) }

    static var inspectorBackground: NSColor { dynamic(rgb(249, 249, 249), rgb(39, 39, 39)) }
    static var inspectorBorder: NSColor { dynamic(rgb(222, 222, 222), rgb(58, 58, 58)) }

    static var cardBackground: NSColor { dynamic(rgb(240, 240, 240), rgb(52, 52, 52)) }
    static var cardBorder: NSColor { dynamic(rgb(224, 224, 224), rgb(64, 64, 64)) }

    static var hoverFill: NSColor { dynamic(NSColor(white: 0, alpha: 0.055), NSColor(white: 1, alpha: 0.085)) }
    static var pressedFill: NSColor { dynamic(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.13)) }

    static var selectionFill: NSColor {
        dynamic(NSColor.controlAccentColor.withAlphaComponent(0.15),
                NSColor.controlAccentColor.withAlphaComponent(0.26))
    }
    static var selectionBorder: NSColor {
        dynamic(NSColor.controlAccentColor.withAlphaComponent(0.55),
                NSColor.controlAccentColor.withAlphaComponent(0.70))
    }
    static var rowSelectedFill: NSColor {
        dynamic(NSColor.controlAccentColor.withAlphaComponent(0.13),
                NSColor.controlAccentColor.withAlphaComponent(0.24))
    }

    static var fieldBackground: NSColor { dynamic(rgb(255, 255, 255), rgb(30, 30, 30)) }
    static var checkerLight: NSColor { dynamic(rgb(255, 255, 255), rgb(150, 150, 150)) }
    static var checkerDark: NSColor { dynamic(rgb(225, 225, 225), rgb(115, 115, 115)) }

    static var headerText: NSColor { .tertiaryLabelColor }
    static var secondaryText: NSColor { .secondaryLabelColor }

    // MARK: Type ramp

    static var groupHeaderFont: NSFont { NSFont.systemFont(ofSize: 9, weight: .semibold) }
    static var toolLabelFont: NSFont { NSFont.systemFont(ofSize: 9, weight: .regular) }
    static var buttonLabelFont: NSFont { NSFont.systemFont(ofSize: 10, weight: .regular) }
    static var bodyFont: NSFont { NSFont.systemFont(ofSize: 11, weight: .regular) }
    static var sectionTitleFont: NSFont { NSFont.systemFont(ofSize: 10, weight: .semibold) }
    static var inspectorTitleFont: NSFont { NSFont.systemFont(ofSize: 12, weight: .semibold) }
    static var historyFont: NSFont { NSFont.systemFont(ofSize: 10.5, weight: .regular) }
    static var monoFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular) }

    // MARK: Drawing helpers

    static func roundedPath(_ rect: NSRect, radius: CGFloat = Metrics.cornerRadius) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    static func label(_ text: String, font: NSFont = Theme.bodyFont,
                      color: NSColor = NSColor.labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A symbol image sized for the given point size.
    static func symbol(_ name: String, pointSize: CGFloat = 14,
                       weight: NSFont.Weight = .regular) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return base.withSymbolConfiguration(config) ?? base
    }

    /// Draws the classic checkerboard used behind transparent thumbnails.
    static func drawCheckerboard(in rect: NSRect, cell: CGFloat = 4) {
        checkerLight.setFill()
        rect.fill()
        checkerDark.setFill()
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : cell)
            while x < rect.maxX {
                NSRect(x: x, y: y, width: min(cell, rect.maxX - x),
                       height: min(cell, rect.maxY - y)).fill()
                x += cell * 2
            }
            y += cell
            row += 1
        }
    }

    /// Vector thumbnails for the Shapes gallery (template images, tinted by the
    /// owning button). Drawing them ourselves keeps the shapes crisp and avoids
    /// any copied iconography.
    static func shapeThumbnail(_ kind: ToolKind, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let w = rect.width
            switch kind {
            case .line:
                path.move(to: NSPoint(x: w * 0.18, y: w * 0.82))
                path.line(to: NSPoint(x: w * 0.82, y: w * 0.18))
            case .curve:
                path.move(to: NSPoint(x: w * 0.16, y: w * 0.80))
                path.curve(to: NSPoint(x: w * 0.84, y: w * 0.24),
                           controlPoint1: NSPoint(x: w * 0.34, y: w * 0.18),
                           controlPoint2: NSPoint(x: w * 0.66, y: w * 0.86))
            case .rectangle:
                path.appendRect(NSRect(x: w * 0.16, y: w * 0.24,
                                       width: w * 0.68, height: w * 0.52))
            case .roundedRectangle:
                let r = NSRect(x: w * 0.16, y: w * 0.24, width: w * 0.68, height: w * 0.52)
                path.append(NSBezierPath(roundedRect: r, xRadius: w * 0.17, yRadius: w * 0.17))
            case .ellipse:
                path.appendOval(in: NSRect(x: w * 0.16, y: w * 0.24,
                                           width: w * 0.68, height: w * 0.52))
            case .triangle:
                path.move(to: NSPoint(x: w * 0.50, y: w * 0.20))
                path.line(to: NSPoint(x: w * 0.86, y: w * 0.80))
                path.line(to: NSPoint(x: w * 0.14, y: w * 0.80))
                path.close()
            case .polygon:
                appendRegularPolygon(to: path, center: NSPoint(x: w * 0.5, y: w * 0.52),
                                     radius: w * 0.34, sides: 5)
            case .diamond:
                path.move(to: NSPoint(x: w * 0.50, y: w * 0.16))
                path.line(to: NSPoint(x: w * 0.84, y: w * 0.52))
                path.line(to: NSPoint(x: w * 0.50, y: w * 0.86))
                path.line(to: NSPoint(x: w * 0.16, y: w * 0.52))
                path.close()
            case .arrow:
                path.move(to: NSPoint(x: w * 0.18, y: w * 0.80))
                path.line(to: NSPoint(x: w * 0.80, y: w * 0.22))
                path.move(to: NSPoint(x: w * 0.46, y: w * 0.22))
                path.line(to: NSPoint(x: w * 0.80, y: w * 0.22))
                path.line(to: NSPoint(x: w * 0.80, y: w * 0.56))
            case .star:
                appendStar(to: path, center: NSPoint(x: w * 0.5, y: w * 0.53),
                           outer: w * 0.38, inner: w * 0.17)
            default:
                path.appendOval(in: NSRect(x: w * 0.2, y: w * 0.2,
                                           width: w * 0.6, height: w * 0.6))
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func appendRegularPolygon(to path: NSBezierPath, center: NSPoint,
                                             radius: CGFloat, sides: Int) {
        for i in 0..<sides {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * 2 * CGFloat.pi / CGFloat(sides)
            let p = NSPoint(x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
    }

    private static func appendStar(to path: NSBezierPath, center: NSPoint,
                                   outer: CGFloat, inner: CGFloat) {
        for i in 0..<10 {
            let radius = i % 2 == 0 ? outer : inner
            let angle = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
            let p = NSPoint(x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
    }
}

// MARK: - Flipped container

/// Top-left origin container, used for scroll-view document views so content
/// starts at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted whenever the current primary/secondary colour changes outside of
    /// the ribbon so all colour UI can repaint itself.
    static let paintCraftColorsDidChange = Notification.Name("PaintCraftColorsDidChange")
}

// MARK: - Ribbon button

/// A borderless, Paint-like ribbon button: flat by default, a soft rounded
/// highlight on hover and an accent-tinted rounded rectangle when selected.
/// Labeled buttons show a symbol above a small caption (Home tools, Crop,
/// Resize…), icon-only buttons are used for compact groups.
final class PaintRibbonButton: NSButton {

    enum ButtonStyle {
        case labeled
        case iconOnly
    }

    private(set) var buttonStyle: ButtonStyle = .iconOnly
    private var hovering = false
    private var hoverTracking: NSTrackingArea?
    /// When true the button draws the accent selection chrome for `.on`.
    var showsSelectionChrome = true

    convenience init(symbol: String, title: String, style: ButtonStyle,
                     target: AnyObject?, action: Selector?, toggles: Bool = false) {
        self.init(frame: .zero)
        configure(symbol: symbol, title: title, style: style,
                  target: target, action: action, toggles: toggles)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(symbol: String, title: String, style: ButtonStyle,
                   target: AnyObject?, action: Selector?, toggles: Bool = false) {
        buttonStyle = style
        self.target = target
        self.action = action
        if toggles { setButtonType(.pushOnPushOff) }
        image = Theme.symbol(symbol, pointSize: style == .labeled ? 15 : 13)
        imagePosition = style == .labeled ? .imageAbove : .imageOnly
        imageHugsTitle = true
        self.title = style == .labeled ? title : ""
        self.font = style == .labeled ? Theme.toolLabelFont : Theme.buttonLabelFont
        toolTip = style == .labeled ? nil : title
        translatesAutoresizingMaskIntoConstraints = false
        updateTitleAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    func setAccentSelected(_ selected: Bool) {
        state = selected ? .on : .off
        updateTitleAppearance()
        needsDisplay = true
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    private func updateTitleAppearance() {
        let selected = state == .on
        let tint: NSColor = selected ? .labelColor : .secondaryLabelColor
        if buttonStyle == .labeled {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: Theme.toolLabelFont,
                .foregroundColor: tint,
                .paragraphStyle: paragraph
            ])
        }
        contentTintColor = selected ? .labelColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = Theme.roundedPath(rect)
        if state == .on && showsSelectionChrome {
            Theme.selectionFill.setFill()
            path.fill()
            Theme.selectionBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isHighlighted {
            Theme.pressedFill.setFill()
            path.fill()
        } else if hovering {
            Theme.hoverFill.setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - Primary / secondary swatch pair

/// Paint's overlapping foreground/background colour swatches. The secondary
/// colour peeks out from behind the primary one; a tiny swap affordance sits in
/// the corner.
final class PaintSwatchPairView: NSView {
    var primaryProvider: () -> PixelColor = { .black }
    var secondaryProvider: () -> PixelColor = { .white }
    var onPrimaryClick: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    var onSwap: (() -> Void)?

    private let primaryRect = NSRect(x: 0, y: 0, width: 24, height: 24)
    private let secondaryRect = NSRect(x: 9, y: 9, width: 18, height: 18)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        drawSwatch(primaryProvider(), in: primaryRect, emphasized: true)
        drawSwatch(secondaryProvider(), in: secondaryRect, emphasized: false)
    }

    private func drawSwatch(_ color: PixelColor, in rect: NSRect, emphasized: Bool) {
        color.nsColor.setFill()
        rect.fill()
        if color.a < 255 {
            Theme.drawCheckerboard(in: rect)
            color.nsColor.setFill()
            rect.fill()
        }
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25))
        path.lineWidth = 1
        path.stroke()
        if emphasized {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let inner = NSBezierPath(rect: rect.insetBy(dx: 1.75, dy: 1.75))
            inner.lineWidth = 1
            inner.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Hit-test primary first because it is drawn on top.
        if primaryRect.contains(p) {
            onPrimaryClick?()
        } else if secondaryRect.contains(p) {
            onSecondaryClick?()
        }
    }
}

// MARK: - Palette grid

/// The classic two-row, 14-column colour palette, drawn to fit any swatch size.
/// Left click selects the primary colour, right click the secondary one. An
/// optional recent-colours strip can be shown below the grid.
final class PaintPaletteGridView: NSView {
    var primaryProvider: () -> PixelColor = { .black }
    var secondaryProvider: () -> PixelColor = { .white }
    var recentProvider: (() -> [PixelColor]) = { [] }
    var onPrimary: ((PixelColor) -> Void)?
    var onSecondary: ((PixelColor) -> Void)?
    var swatchSize: CGFloat = Theme.Metrics.swatch
    var gap: CGFloat = Theme.Metrics.swatchGap
    var showsRecent = false

    private var hoveredIndex: Int?
    private var hoverTracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    private var columns: Int { Theme.Metrics.paletteColumns }
    private var rows: Int { Theme.Metrics.paletteRows }

    private var gridHeight: CGFloat {
        CGFloat(rows) * (swatchSize + gap) + gap
    }

    private var recentHeight: CGFloat {
        showsRecent ? swatchSize + gap + 2 : 0
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(columns) * (swatchSize + gap) + gap,
               height: gridHeight + recentHeight)
    }

    private func swatchRect(index: Int) -> NSRect {
        let row = index / columns
        let col = index % columns
        return NSRect(x: gap + CGFloat(col) * (swatchSize + gap),
                      y: gap + CGFloat(row) * (swatchSize + gap),
                      width: swatchSize, height: swatchSize)
    }

    private func recentRect(_ i: Int) -> NSRect {
        NSRect(x: gap + CGFloat(i) * (swatchSize + gap),
               y: gridHeight + 2, width: swatchSize, height: swatchSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let classic = ColorPalette.classic
        let primary = primaryProvider()
        let secondary = secondaryProvider()
        for (index, color) in classic.enumerated() {
            let rect = swatchRect(index: index)
            color.nsColor.setFill()
            rect.fill()
            if color.a < 255 {
                Theme.drawCheckerboard(in: rect)
                color.nsColor.setFill()
                rect.fill()
            }
            if hoveredIndex == index && color != primary && color != secondary {
                NSColor.labelColor.withAlphaComponent(0.6).setStroke()
                let p = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
                p.lineWidth = 1
                p.stroke()
            } else if color == primary {
                drawSelectionRing(rect, color: NSColor.controlAccentColor, width: 2)
            } else if color == secondary {
                drawSelectionRing(rect, color: NSColor.labelColor.withAlphaComponent(0.65), width: 1)
            } else {
                NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
                let p = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                p.lineWidth = 1
                p.stroke()
            }
        }
        if showsRecent {
            let recents = recentProvider()
            for (i, color) in recents.prefix(columns).enumerated() {
                let rect = recentRect(i)
                color.nsColor.setFill()
                rect.fill()
                if hoveredIndex == -1 - i {
                    NSColor.labelColor.withAlphaComponent(0.6).setStroke()
                    let p = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
                    p.lineWidth = 1
                    p.stroke()
                } else {
                    NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
                    let p = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                    p.lineWidth = 1
                    p.stroke()
                }
            }
        }
    }

    private func drawSelectionRing(_ rect: NSRect, color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        path.stroke()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: width + 0.75, dy: width + 0.75))
        inner.lineWidth = 1
        inner.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let index = swatchIndex(at: convert(event.locationInWindow, from: nil))
        if index != hoveredIndex {
            hoveredIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    /// Returns classic-palette index, recent-strip index (-1 - i), or nil.
    private func swatchIndex(at point: NSPoint) -> Int? {
        for index in ColorPalette.classic.indices where swatchRect(index: index).contains(point) {
            return index
        }
        if showsRecent {
            for i in 0..<recentProvider().prefix(columns).count where recentRect(i).contains(point) {
                return -1 - i
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let hit = hitColor(at: convert(event.locationInWindow, from: nil)) else { return }
        if event.modifierFlags.contains(.control) {
            onSecondary?(hit)
        } else {
            onPrimary?(hit)
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let hit = hitColor(at: convert(event.locationInWindow, from: nil)) else { return }
        onSecondary?(hit)
        needsDisplay = true
    }

    private func hitColor(at point: NSPoint) -> PixelColor? {
        for index in ColorPalette.classic.indices where swatchRect(index: index).contains(point) {
            return ColorPalette.classic[index]
        }
        if showsRecent {
            let recents = recentProvider()
            for i in 0..<min(columns, recents.count) where recentRect(i).contains(point) {
                return recents[i]
            }
        }
        return nil
    }

    func refresh() {
        needsDisplay = true
    }
}
