# PaintCraft — Specification

A native macOS paint application in the spirit of Microsoft Paint: the classic
tool set and two-colour workflow, rebuilt clean-room with Swift + AppKit, plus
enhancements Paint does not have (layers, non-destructive adjustments, smart
guides, background removal, an AI image slot).

- **Bundle id:** `local.paintcraft.app`
- **Minimum OS:** macOS 13 (built and verified on macOS 15.8.1, arm64)
- **Language/toolchain:** Swift 6.2.3, Command Line Tools only (no Xcode project, no SwiftPM, no third-party dependencies)
- **Artifact:** `build/PaintCraft.app` (ad-hoc signed)

## 1. Product goals

1. **Paint familiarity.** A user who knows Paint can use PaintCraft without a
   manual: same tool set, same 28-colour palette, same two-colour (left/right
   click) model, same single-letter shortcuts, same status-bar information.
2. **Pixel-exact editing.** Integer pixel operations for pencil, fill, shapes and
   selections; zoom up to 800 % with a pixel grid so individual pixels are
   editable.
3. **Enhance, do not replace.** Layers, undo history, non-destructive
   adjustments, smart guides and background removal are additive; classic
   workflows keep working.

## 2. Feature inventory

### 2.1 Tools (Paint parity)

| Tool | Behaviour | Shortcut |
|---|---|---|
| Pencil | 1 px hard stroke, width adjustable | P |
| Brush | Soft round brush, pressure/softness aware | B |
| Eraser | Hard square/circle, erases to transparent or secondary colour | E |
| Airbrush | Builds density while held | A |
| Fill with colour | Scanline flood fill with tolerance, contiguous or global | F |
| Colour picker | Samples layer (composited when translucent) | I |
| Magnifier | Click zooms in (presets 12.5 %–800 %) | M |
| Text | Inline editor, font/size/bold/italic, rasterised on commit | T |
| Line | Straight line with width/pattern | L |
| Curve | Drag to bend a line | C |
| Rectangle / Rounded rect | Outline and/or fill, line style | R |
| Ellipse / Triangle / Polygon / Diamond | Same shape engine | O |
| Arrow / Star | Same shape engine | — |
| Rectangular selection | Marquee, size shown in status bar | S |
| Free-form selection | Lasso polygon mask | — |
| Magic wand | Contiguous colour selection with tolerance | — |

### 2.2 Canvas and zoom

- Document sizes from 1×1 up to large canvases; paper shown on a grey desk with
  a drop shadow.
- Zoom presets 12.5 %, 25 %, 50 %, 100 %, 200 %, 400 %, 800 %; pinch to zoom,
  ⌘-scroll to zoom, two-finger scroll to pan, space-drag or middle-drag to pan.
- Fit-to-window until the user explicitly zooms.
- Pixel grid automatically at ≥ 400 %; optional rulers.
- Transparency shown as a checkerboard.

### 2.3 Colours (Paint parity + extension)

- The canonical 28-swatch, two-row Paint palette.
- Primary/secondary colours: left click sets primary, right click sets secondary.
- Custom colour picker (NSColorPanel), editable hex, recent colours.

### 2.4 Image operations

- Crop to selection.
- Resize **image** (scale artwork) vs. **canvas** (change canvas box, anchor
  content) — kept as separate operations, matching Paint's two dialogs.
- Rotate 90° CW/CCW, 180°, flip horizontal/vertical, invert colours.
- Undo/redo for pixel edits; geometry operations reset history because old
  region snapshots would be out of bounds.

### 2.5 Enhancements beyond Paint

1. **Layers** — add, duplicate, delete, reorder, rename; per-layer visibility,
   opacity, blend mode (normal, multiply, screen, overlay, darken, lighten,
   difference, add); merge down; layer thumbnails; `.paintcraft` keeps layers.
2. **Undo history panel** — named steps, unlimited within the configured depth.
3. **Non-destructive adjustments** — brightness/contrast, hue/saturation,
   exposure, grayscale, sepia, vignette, sharpen, Gaussian blur, applied as a
   live filter chain on a layer and stored in the document (Core Image).
4. **Background removal** — flood fill from image edges with tolerance and
   feather, undoable, respects selection.
5. **Image Creator slot** — optional AI image generation through a configurable
   OpenAI-compatible endpoint; no key is bundled; offline it fails gracefully.
6. **Smart guides** — canvas edges/centre alignment hints while dragging.
7. **macOS integration** — dark/light appearance, native menus and shortcuts,
   pinch/gesture support, document autosave-in-place hook.

## 3. Architecture

Single Swift module compiled by `swiftc` (no package manager). AppKit for UI and
Core Graphics for all raster work; Core Image only for adjustments.

```
Sources/
  main.swift             app entry, menu bar, --selftest dispatch, action forwarding
  WorkspaceController.swift  window layout, actions, document lifecycle
  CanvasView.swift       viewport: zoom/pan, compositing, overlays, input routing
  Tool.swift             ToolKind, ToolSettings, ToolContext, Tool protocol,
                         Adjustment/AdjustmentKind
  ToolRegistry.swift     one instance per tool
  ToolsPaint.swift       pencil/brush/eraser/airbrush/fill/picker/magnifier + FloodFill
  ToolsShapes.swift      shape geometry, preview, curve
  ToolsSelection.swift   marquee/lasso/magic wand, text tool + composer
  ColorPalette.swift     28-colour palette, swatch grid view
  ToolRibbon.swift       ribbon tabs and tool strip
  InspectorPanel.swift   layers / history / colours inspector, status bar, resize dialog
  Document.swift         layers, undo stack, geometry ops, compositing
  CoreRaster.swift       RGBA8 premultiplied raster, image IO conversions,
                         deterministic rotate/flip, CGImageDrawing upright helper
  SelectionModel.swift   rect + mask selections, marching-ants boundary path
  FileIO.swift           `.paintcraft` single-file format, PNG/JPEG/TIFF export,
                         BMP encode/decode (24/32-bit, bottom-up)
  Adjustments.swift      Core Image pipeline + adjustments panel
  SelfTest.swift         headless verification suite (--selftest)
```

**Coordinate model.** Image space is top-left origin, y down, 1 unit = 1 pixel.
Each `Raster` wraps a Core Graphics bitmap whose context is transformed to match
that convention. Because Core Graphics draws images y-up, every `CGImage` draw
goes through `CGImageDrawing.drawUpright`, which compensates for the flip. This
is asserted by the self-test (import orientation and composite orientation).

**Undo model.** Before a mutation the document snapshots the affected layer
region; after the mutation the post-edit region is captured too. Undo restores
the "before" raster, redo restores the "after" raster. Geometry operations (crop,
resize, rotate, flip) clear history rather than trying to remap regions.

**Compositing.** Layers are drawn in order into one document-sized raster with
their blend mode and opacity, cached until the next change.

## 4. File formats

### 4.1 `.paintcraft` (native, single flat file)

```
offset 0   "PCRA"                    4 bytes magic
offset 4   UInt32 LE                 format version (1)
offset 8   UInt32 LE                 metadata length N
offset 12  JSON metadata             N bytes
           layer PNG blobs           concatenated, lengths in metadata
```

Metadata: canvas size, active layer index, and per layer: name, visibility,
opacity, blend mode, lock flag, adjustment chain, PNG byte length.

### 4.2 Import/export

- Import: PNG, JPEG, TIFF, GIF, BMP (via ImageIO), plus native documents.
- Export: PNG, JPEG, TIFF, GIF, and **BMP** through a purpose-built codec — 24-bit,
  bottom-up, 4-byte row padding, matching files Paint itself writes.

## 5. Verification

Three layers, all reproducible:

1. **Headless engine suite** — `build/PaintCraft.app/Contents/MacOS/PaintCraft --selftest`
   (57 assertions): raster round-trips, image/composite orientation, crop,
   canvas-vs-image resize, rotate/flip, pencil stroke + undo + redo, flood fill,
   shape outline, rect/free-form selection, native `.paintcraft` save/load, PNG
   export, BMP round-trip, grayscale adjustment, background removal (+ undo),
   selection-scoped adjustment bake (+ undo), selection copy/delete/paste/move/nudge
   (+ undo), smart-guide computation/snapping, and an assertion that the AI image
   provider is unconfigured by default.
2. **UI/process verification** — `bash scripts/build.sh verify` builds, launches
   the app and asserts a real on-screen window via `CGWindowListCopyWindowInfo`.
3. **Visual end-to-end** — `bash scripts/verify-all.sh` chains typecheck → build →
   selftest → demo generation → launch with the demo document → window assertion →
   per-window screenshot (`build/shot-verified.png`) → pixel assertions
   (`scripts/check_image.py`: minimum distinct-colour count plus sunset/dark tone
   coverage, so a blank window cannot pass).

`bash scripts/build.sh shot` / `demo` capture `build/shot-window.png` and
`build/shot-demo.png` respectively for visual review.

## 6. Known limitations

- Text editing is single-run text: no rich text spans, no on-canvas resize
  handles; commit on ⌘↩ or click-away. The inline editor is positioned once and
  does not follow later zoom/pan while editing.
- Copy/cut read the active layer only, not the flattened composite. Pasting into
  a locked layer creates a new layer, and undoing that paste leaves the empty
  layer behind (raster-only undo model).
- Undoing an edit made through a free-form/masked selection restores the
  selection as its bounding rectangle (the undo record stores a CGRect).
- Selection masks are binary: antialiased source edges can leave a ~1 px halo;
  the magic wand is 4-connected.
- Floating drag-move is offered by the rectangular selection tool only; dragging
  inside a lasso starts a new lasso. Moves affect the active layer only.
- A brush or airbrush stroke holds two canvas-sized scratch rasters during the
  gesture (memory ≈ 2× the bitmap); fine for typical sizes, notable for huge documents.
- The airbrush uses a deterministic spray seed and is tuned by feel, not measured
  against Paint; there is no tablet pressure support.
- Curve commits when the bend drag is released (Paint finishes with a click).
- Free-form selections use a pixel mask; boolean operations on masks (union /
  subtract) are approximated through bounds in v1.
- Smart guides and background removal are per-active-layer; they do not yet
  analyse all layers together.
- The AI Image Creator requires the user to supply an endpoint and key; no
  provider is bundled, and it is intentionally not used by the self-test.
- Layers are flattened for BMP/JPEG export (expected); `.paintcraft` preserves them.
