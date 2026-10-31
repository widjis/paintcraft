import AppKit

/// Classic Paint 28-color palette plus recent/custom colors (enhancement).
final class ColorPalette {
    /// The canonical two-row Paint palette, row-major top-left to bottom-right.
    static let classic: [PixelColor] = [
        // Row 1 (top): neutrals
        PixelColor(r: 0, g: 0, b: 0),         // black
        PixelColor(r: 128, g: 128, b: 128),   // gray
        PixelColor(r: 128, g: 0, b: 0),       // dark red
        PixelColor(r: 128, g: 128, b: 0),     // olive
        PixelColor(r: 0, g: 128, b: 0),       // dark green
        PixelColor(r: 0, g: 128, b: 128),     // teal
        PixelColor(r: 0, g: 0, b: 128),       // navy
        PixelColor(r: 128, g: 0, b: 128),     // purple
        PixelColor(r: 128, g: 64, b: 0),      // brown
        PixelColor(r: 0, g: 64, b: 64),       // dark cyan
        PixelColor(r: 0, g: 128, b: 255),     // blue
        PixelColor(r: 0, g: 64, b: 128),      // mid blue
        PixelColor(r: 64, g: 0, b: 128),      // violet
        PixelColor(r: 128, g: 0, b: 255),     // purple 2
        // Row 2 (bottom): saturated
        PixelColor(r: 255, g: 255, b: 255),   // white
        PixelColor(r: 192, g: 192, b: 192),   // light gray
        PixelColor(r: 255, g: 0, b: 0),       // red
        PixelColor(r: 255, g: 255, b: 0),     // yellow
        PixelColor(r: 0, g: 255, b: 0),       // lime
        PixelColor(r: 0, g: 255, b: 255),     // cyan
        PixelColor(r: 0, g: 0, b: 255),       // blue bright
        PixelColor(r: 255, g: 0, b: 255),     // magenta
        PixelColor(r: 255, g: 128, b: 0),     // orange
        PixelColor(r: 0, g: 255, b: 128),     // mint
        PixelColor(r: 128, g: 255, b: 255),   // light cyan
        PixelColor(r: 128, g: 0, b: 255),     // purple bright
        PixelColor(r: 255, g: 0, b: 128),     // pink
        PixelColor(r: 255, g: 128, b: 128)    // salmon
    ]

    static let rows = 2

    var recentColors: [PixelColor] = []
    var primary: PixelColor = .black {
        didSet { registerRecent(primary) }
    }
    var secondary: PixelColor = .white

    /// Colors sampled by the eyedropper, shown in a dedicated strip.
    var history: [PixelColor] = []

    private func registerRecent(_ c: PixelColor) {
        recentColors.removeAll { $0 == c }
        recentColors.insert(c, at: 0)
        if recentColors.count > 10 { recentColors.removeLast(recentColors.count - 10) }
    }

    func swap() {
        let t = primary
        primary = secondary
        secondary = t
    }
}

// MARK: - Color swatch view

/// A palette grid of clickable swatches. Left click = primary, right click =
/// secondary, matching Paint's two-color model.
final class ColorSwatchView: NSView {
    var palette: ColorPalette
    var onPrimaryChanged: ((PixelColor) -> Void)?
    var onSecondaryChanged: ((PixelColor) -> Void)?
    var onOpenPicker: (() -> Void)?

    private let swatchSize: CGFloat = 18
    private let gap: CGFloat = 2
    private var trackingAreas_: [NSTrackingArea] = []

    init(palette: ColorPalette) {
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let cols = 14
        return NSSize(width: CGFloat(cols) * (swatchSize + gap) + gap,
                      height: CGFloat(ColorPalette.rows) * (swatchSize + gap) + gap + 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let cols = 14
        let startY = bounds.height - swatchSize - gap
        for (index, color) in ColorPalette.classic.enumerated() {
            let row = index / cols
            let col = index % cols
            let rect = CGRect(x: gap + CGFloat(col) * (swatchSize + gap),
                              y: startY - CGFloat(row) * (swatchSize + gap),
                              width: swatchSize, height: swatchSize)
            drawSwatch(color, in: rect)
        }

        // Recent colors strip at bottom.
        var x = gap
        let y: CGFloat = 2
        for c in palette.recentColors.prefix(10) {
            drawSwatch(c, in: CGRect(x: x, y: y, width: swatchSize, height: 12))
            x += swatchSize + gap
        }
        _ = cols
    }

    private func drawSwatch(_ color: PixelColor, in rect: CGRect) {
        color.nsColor.setFill()
        rect.fill()
        let selected = (color == palette.primary) || (color == palette.secondary)
        NSColor.controlAccentColor.setStroke()
        (selected ? (rect == rect ? 2.0 : 1.0) : 1.0).rounded()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = selected ? 2.0 : 1.0
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let color = color(at: convert(event.locationInWindow, from: nil)) else { return }
        if event.modifierFlags.contains(.control) {
            palette.secondary = color
            onSecondaryChanged?(color)
        } else {
            palette.primary = color
            onPrimaryChanged?(color)
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let color = color(at: convert(event.locationInWindow, from: nil)) else { return }
        palette.secondary = color
        onSecondaryChanged?(color)
        needsDisplay = true
    }

    private func color(at point: CGPoint) -> PixelColor? {
        let cols = 14
        let startY = bounds.height - swatchSize - gap
        for (index, color) in ColorPalette.classic.enumerated() {
            let row = index / cols
            let col = index % cols
            let rect = CGRect(x: gap + CGFloat(col) * (swatchSize + gap),
                              y: startY - CGFloat(row) * (swatchSize + gap),
                              width: swatchSize, height: swatchSize)
            if rect.contains(point) { return color }
        }
        return nil
    }
}
