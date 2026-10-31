# PaintCraft — reverse-engineering notes

- **Artifact:** `build/PaintCraft.app` · `local.paintcraft.app` · macOS 15.8.1 arm64
- **Method:** clean-room reimplementation from publicly documented behaviour.
  **No Microsoft binary, installer, asset or string was inspected, extracted or
  copied.** There is no Microsoft Paint build for macOS to analyse, and this
  project deliberately does not decompile Microsoft software.
- **Sources of behavioural truth:** Microsoft's public Paint product page
  (Image Creator, Background Removal, Layers, Text tool) and widely documented
  Paint interaction conventions (tool names, two-colour left/right model, 28-colour
  palette, single-letter shortcuts, status-bar fields, BMP quirks).
- **Deliverable:** a working app plus this note, so a colleague can re-derive
  every decision.

## 1. What "reverse engineering" means here

The skill's purpose is to answer a question about a target by evidence. The
question here was not "how is Paint implemented" (that code is not available and
not inspectable lawfully), but:

> What observable behaviour must be reproduced for a Paint user to feel at home
> on macOS, and which parts must be adapted to Mac conventions?

The "target" is therefore a **behavioural specification**, not a binary. That is
the interoperability route: reproduce the interface contract, write new code.

## 2. Behaviour inventory and evidence

| Behaviour | Evidence | Implementation |
|---|---|---|
| Modern Paint bundles Image Creator, Background Removal, Layers, Text tool | Microsoft Paint product page (public marketing copy) | enhancement slots in §2.5 of SPEC |
| Classic tool set: pencil, fill, text, eraser, picker, magnifier, brush, airbrush, shapes, selections | Long-standing public Paint documentation/UI convention | `ToolKind`, `Tools*.swift` |
| Two-colour model: left click = colour 1, right click = colour 2 | Documented Paint convention | `ToolSettings.primaryColor/secondaryColor`, swatch view |
| 28-colour palette in two rows of 14 | Documented classic palette | `ColorPalette.classic` |
| Single-letter shortcuts P/F/T/E/I/M/B/A/L/C/R/O/S | Documented Paint shortcut list | `ToolKind.shortcutKey`, `CanvasView.keyDown` |
| Status bar shows cursor position, selection size, canvas size, zoom | Documented Paint layout | `StatusBarView` |
| BMP is bottom-up, 24-bit, rows padded to 4 bytes | Public BMP format documentation | `BMPCodec` (encoder/decoder) |
| Separate "Resize image" vs "Resize canvas" dialogs | Public Paint UI | `Document.resizeImage` vs `resizeCanvas` |
| Undo limited in Paint; history not visible | Public behaviour | enhancement: named history + depth 40 |

### Platform facts verified on this machine (not assumptions)

- `swiftc 6.2.3`, SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`
  (macOS 26.2 SDK), target `arm64-apple-macos13.0` — verified by building the app.
- SF Symbols availability was probed programmatically: `spray` and `paintbucket`
  do not resolve; substituted `wind` and `drop.fill` (see `SelfTest`/`Tool.swift`).
- Core Graphics draws images y-up; drawing into a top-left raster without
  compensation mirrors the image. Verified by a standalone experiment
  (`build/orient2` harness, later folded into `SelfTest.testOrientation`).
- `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` did not list the app window on
  this host while `.optionAll` did; the verification harness therefore uses
  `.optionAll` and filters by size.

## 3. Deliberate deviations from Paint (and why)

| Paint | PaintCraft | Reason |
|---|---|---|
| Ribbon with Windows styling | Ribbon-style AppKit controls | Native macOS feel; no Windows assets |
| Title bar with Windows menu | macOS menu bar + native shortcuts | Platform convention |
| Undo stack ~50 blind steps | Named history panel | Enhancement, also aids debugging |
| No layers | Layer stack with blend modes | Requested enhancement; modern Paint now ships layers |
| No adjustments | Non-destructive Core Image chain | Enhancement |
| No smart guides | Edge/centre snap guides | Enhancement |
| AI Image Creator (Microsoft service) | Configurable provider slot, no bundled key | Must not depend on Microsoft service or ship credentials |
| Save formats | `.paintcraft` + standard images + BMP | Compatibility is the point |

## 4. Confidence and gaps

**Verified by automated tests (57 assertions, `--selftest`):** pixel model,
orientation, crop/resize/rotate/flip, pencil + undo/redo, flood fill, shape
outline, selections, selection copy/delete/paste/move/nudge, native save/load,
PNG export, BMP round-trip, grayscale, background removal, selection-scoped bake
and smart guides.

**Verified by observation:** window layout, ribbon contents, palette rendering,
inspector presence, status bar, zoom label, traffic lights — via per-window
screenshots (`build/shot-window.png`).

**Hypothesised / still open:**
- Exact Paint defaults (brush widths, airbrush density) were approximated from
  public descriptions, not measured against Paint.
- Boolean selection algebra is bounds-based in v1 (mask-exact operations would be
  the next step); this is a known gap, not a guess.
- AI Image Creator is a slot, not a verified provider integration: it has not
  been exercised against a live endpoint because no key is available here.

## 5. Reproduction

```bash
cd PaintCraft
bash scripts/build.sh typecheck          # TYPECHECK OK
bash scripts/build.sh build              # build/PaintCraft.app
./build/PaintCraft.app/Contents/MacOS/PaintCraft --selftest   # 40 passed, 0 failed
bash scripts/build.sh shot               # build/shot-window.png
```

## 6. Legal / ethical position

This project does not circumvent DRM, licensing, activation or paywalls; it does
not redistribute Microsoft code or assets; it does not present itself as
Microsoft Paint. It reproduces an interaction pattern — which is the lawful
interoperability route — under a different name and implementation.
