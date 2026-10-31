import AppKit
import CoreGraphics

// MARK: - Tool kinds

/// Every interactive tool in the app. Raw values are used for keyboard
/// shortcuts and `UserDefaults` persistence.
enum ToolKind: String, CaseIterable, Identifiable {
    case pencil
    case brush
    case eraser
    case airbrush
    case fill
    case eyedropper
    case magnifier
    case selectRect
    case selectFreeform
    case magicWand
    case text
    case line
    case curve
    case rectangle
    case roundedRectangle
    case ellipse
    case triangle
    case polygon
    case diamond
    case arrow
    case star

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .airbrush: return "Airbrush"
        case .fill: return "Fill with color"
        case .eyedropper: return "Color picker"
        case .magnifier: return "Magnifier"
        case .selectRect: return "Rectangular selection"
        case .selectFreeform: return "Free-form selection"
        case .magicWand: return "Magic wand"
        case .text: return "Text"
        case .line: return "Line"
        case .curve: return "Curve"
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded rectangle"
        case .ellipse: return "Ellipse"
        case .triangle: return "Triangle"
        case .polygon: return "Polygon"
        case .diamond: return "Diamond"
        case .arrow: return "Arrow"
        case .star: return "Star"
        }
    }

    var symbolName: String {
        switch self {
        case .pencil: return "pencil"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .airbrush: return "wind"
        case .fill: return "drop.fill"
        case .eyedropper: return "eyedropper"
        case .magnifier: return "magnifyingglass"
        case .selectRect: return "selection.pin.in.out"
        case .selectFreeform: return "lasso"
        case .magicWand: return "wand.and.stars"
        case .text: return "textformat"
        case .line: return "line.diagonal"
        case .curve: return "point.topleft.down.to.point.bottomright.curvepath"
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "rectangle.roundedtop"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .polygon: return "pentagon"
        case .diamond: return "diamond"
        case .arrow: return "arrow.up.right"
        case .star: return "star"
        }
    }

    /// Keyboard shortcut character, Paint-compatible where it exists.
    var shortcutKey: String? {
        switch self {
        case .pencil: return "p"
        case .fill: return "f"
        case .text: return "t"
        case .eraser: return "e"
        case .eyedropper: return "i"
        case .magnifier: return "m"
        case .brush: return "b"
        case .airbrush: return "a"
        case .line: return "l"
        case .curve: return "c"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .selectRect: return "s"
        default: return nil
        }
    }

    /// Reverse lookup for single-letter keyboard shortcuts.
    static func shortcutKind(for character: String) -> ToolKind? {
        allCases.first { $0.shortcutKey == character }
    }

    var isShape: Bool {
        switch self {
        case .line, .curve, .rectangle, .roundedRectangle, .ellipse,
             .triangle, .polygon, .diamond, .arrow, .star:
            return true
        default: return false
        }
    }

    var isSelection: Bool {
        self == .selectRect || self == .selectFreeform || self == .magicWand
    }

    var isPaintTool: Bool {
        switch self {
        case .pencil, .brush, .eraser, .airbrush, .fill, .line, .curve,
             .rectangle, .roundedRectangle, .ellipse, .triangle, .polygon,
             .diamond, .arrow, .star:
            return true
        default: return false
        }
    }
}

// MARK: - Tool settings

struct ShapeStyle: Equatable {
    var outlineEnabled: Bool = true
    var fillEnabled: Bool = false
    var lineWidth: CGFloat = 3
    var lineStyle: LineStyle = .solid
}

enum LineStyle: String, CaseIterable {
    case solid, dash, dot, dashDot, dashDotDot

    var cgPattern: [CGFloat]? {
        switch self {
        case .solid: return nil
        case .dash: return [12, 6]
        case .dot: return [2, 5]
        case .dashDot: return [12, 5, 2, 5]
        case .dashDotDot: return [12, 5, 2, 5, 2, 5]
        }
    }
}

/// Global tool state, owned by the workspace controller and observed by the canvas.
final class ToolSettings {
    var tool: ToolKind = .pencil
    var strokeWidth: CGFloat = 4          // 1...72 Brush/Pencil/Eraser
    var shapeLineWidth: CGFloat = 3
    var primaryColor: PixelColor = .black
    var secondaryColor: PixelColor = .white
    var opacity: Double = 1.0             // 0.05...1
    var brushSoftness: Double = 0.75      // 0 hard ... 1 soft
    var brushSpacing: Double = 0.12
    var airbrushDensity: Double = 0.35
    var airbrushSize: CGFloat = 24
    var fillTolerance: Int = 0            // 0...255
    var fillContiguous: Bool = true
    var shapeStyle = ShapeStyle()
    var fontSize: CGFloat = 24
    var fontName: String = "Helvetica"
    var bold: Bool = false
    var italic: Bool = false
    var textAntiAlias: Bool = true
    var showPixelGrid: Bool = true
    var showRulers: Bool = false
    var showGuides: Bool = true
    var snapToGuides: Bool = true
    var eraserRestore: Bool = true        // erase to transparent (vs. secondary color)

    /// Color used by the current tool (secondary color for eraser with restore off).
    var activeColor: PixelColor { primaryColor }

    /// Convenience: paint in "right-click" mode (background/secondary color).
    var alternateColor: PixelColor { secondaryColor }

    func color(for alternate: Bool) -> PixelColor {
        alternate ? secondaryColor : primaryColor
    }
}

// MARK: - Context handed to tools

/// Everything a tool needs to read state and request redraws. The workspace
/// controller owns this; tools never touch UI directly.
final class ToolContext {
    weak var document: Document?
    weak var canvasView: CanvasView?
    var settings: ToolSettings
    var canvasSize: CGSize = .zero

    /// Called by tools after mutating pixels to request a repaint.
    var requestRedraw: ((CGRect?) -> Void)?
    /// Called when a tool changes canvas-level state (zoom, palette, selection).
    var setZoom: ((CGFloat) -> Void)?
    var setPrimaryColor: ((PixelColor) -> Void)?
    var statusMessage: ((String) -> Void)?
    var beginTextEditing: ((CGRect) -> Void)?

    init(document: Document?, settings: ToolSettings) {
        self.document = document
        self.settings = settings
        self.canvasSize = document?.canvasSize ?? .zero
    }

    func snapshot() -> Raster? {
        guard let layer = document?.activeLayer, !layer.isLocked else { return nil }
        return layer.raster
    }

    /// Region in image space currently selected (whole canvas if none).
    func editableRegion() -> CGRect {
        if let sel = document?.selection, !sel.isEmpty { return sel.bounds }
        return CGRect(origin: .zero, size: canvasSize)
    }

    func setSelection(_ sel: SelectionModel?) {
        document?.setSelection(sel)
    }

    func undoSnapshot(named: String, rects: [CGRect]) -> Document.PendingUndo? {
        document?.beginUndo(named: named, rects: rects)
    }

    func commit(_ pending: Document.PendingUndo?, selectionBefore: CGRect? = nil, selectionAfter: CGRect? = nil) {
        guard let pending = pending, let doc = document else { return }
        doc.commitUndo(pending, selectionBefore: selectionBefore, selectionAfter: selectionAfter)
    }
}

// MARK: - Tool protocol

protocol Tool: AnyObject {
    var kind: ToolKind { get }
    var cursorName: NSCursorName { get }

    func activate(in ctx: ToolContext)
    func deactivate(in ctx: ToolContext)

    func mouseDown(at p: CGPoint, context: ToolContext)
    func mouseDragged(to p: CGPoint, context: ToolContext)
    func mouseUp(at p: CGPoint, context: ToolContext)
    func mouseMoved(to p: CGPoint, context: ToolContext)

    /// Draw tool feedback (rubber-band shape, selection marquee) in *view* space.
    /// Tools receive a context transformed so image pixels == points.
    func drawOverlay(in ctx: ToolContext, viewContext: CGContext, canvasView: CanvasView)

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool
    func doubleClick(at p: CGPoint, context: ToolContext)

    /// Escape / cancel any in-progress gesture without committing.
    func cancel(in ctx: ToolContext)
}

extension Tool {
    var cursorName: NSCursorName { .crosshair }
    func activate(in ctx: ToolContext) {}
    func deactivate(in ctx: ToolContext) {}
    func mouseMoved(to p: CGPoint, context: ToolContext) {}
    func drawOverlay(in ctx: ToolContext, viewContext: CGContext, canvasView: CanvasView) {}
    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool { false }
    func doubleClick(at p: CGPoint, context: ToolContext) {}
    func cancel(in ctx: ToolContext) {}
}

enum NSCursorName {
    case crosshair, pencil, brush, eraser, airbrush, eyedropper, magnifier,
         openHand, closedHand, arrow, text, crosshairMove

    func make() -> NSCursor {
        switch self {
        case .crosshair: return .crosshair
        case .pencil: return .pointingHand
        case .brush: return .pointingHand
        case .eraser: return .crosshair
        case .airbrush: return .crosshair
        case .eyedropper: return .crosshair
        case .magnifier: return .crosshair
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .arrow: return .arrow
        case .text: return .iBeam
        case .crosshairMove: return .crosshair
        }
    }
}

// MARK: - Adjustment types (enhancement, defined in Adjustments.swift)

struct Adjustment: Equatable, Identifiable {
    var id = UUID()
    var kind: AdjustmentKind = .brightnessContrast
    var amount: Double = 0
    var amount2: Double = 0
    var enabled: Bool = true
}

enum AdjustmentKind: String, CaseIterable, Identifiable {
    case brightnessContrast
    case hueSaturation
    case exposure
    case grayscale
    case sepia
    case vignette
    case sharpen
    case gaussianBlur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightnessContrast: return "Brightness & Contrast"
        case .hueSaturation: return "Hue & Saturation"
        case .exposure: return "Exposure"
        case .grayscale: return "Grayscale"
        case .sepia: return "Sepia"
        case .vignette: return "Vignette"
        case .sharpen: return "Sharpen"
        case .gaussianBlur: return "Gaussian Blur"
        }
    }

    var defaultAmounts: (Double, Double) {
        switch self {
        case .brightnessContrast: return (0, 0)
        case .hueSaturation: return (0, 0)
        case .exposure: return (0, 0)
        case .grayscale: return (1, 0)
        case .sepia: return (1, 0)
        case .vignette: return (0.5, 0)
        case .sharpen: return (0.5, 0)
        case .gaussianBlur: return (2, 0)
        }
    }

    var amountRange: ClosedRange<Double> {
        switch self {
        case .brightnessContrast, .hueSaturation, .exposure: return -1...1
        case .grayscale, .sepia: return 0...1
        case .vignette: return 0...1
        case .sharpen: return 0...1
        case .gaussianBlur: return 0...20
        }
    }
}
