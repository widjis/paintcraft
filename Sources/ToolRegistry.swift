import AppKit
import CoreGraphics

/// Owns one instance of every tool so tools can retain in-progress state
/// (e.g. stroke points) across events.
final class ToolRegistry {
    private var instances: [ToolKind: Tool] = [:]

    init() {
        let all: [Tool] = [
            PencilTool(), BrushTool(), EraserTool(), AirbrushTool(),
            FillTool(), EyedropperTool(), MagnifierTool(),
            RectSelectTool(), FreeformSelectTool(), MagicWandTool(),
            TextTool(), LineTool(), CurveTool(),
            RectangleTool(rounded: false), RectangleTool(rounded: true),
            EllipseTool(), TriangleTool(), PolygonTool(), DiamondTool(),
            ArrowTool(), StarTool()
        ]
        for tool in all { instances[tool.kind] = tool }
    }

    func instance(for kind: ToolKind) -> Tool? { instances[kind] }
}
