# PaintCraft

A native macOS paint app in the spirit of Microsoft Paint — same tools, same
two-colour workflow, same shortcuts — rebuilt clean-room with Swift and AppKit,
plus layers, non-destructive adjustments, smart guides, background removal and an
optional AI image slot.

Not affiliated with, endorsed by, or containing assets from Microsoft.

## Build and run

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
bash scripts/build.sh typecheck   # fast compile check
bash scripts/build.sh build       # -> build/PaintCraft.app
bash scripts/build.sh run         # build + launch
bash scripts/build.sh shot        # build + launch + capture build/shot-window.png
bash scripts/build.sh verify      # build + launch + assert a window exists
bash scripts/verify-all.sh        # full chain incl. demo launch + pixel checks
```

The built app is ad-hoc signed; it runs locally without a Developer account.

## Distribution (DMG)

```bash
bash scripts/make-dmg.sh
# -> build/PaintCraft-1.0-universal.dmg  (+ .sha256)
```

The DMG is universal (Apple Silicon + Intel), contains `PaintCraft.app`, an
`Applications` shortcut, an install note, and the README. The script verifies its
own output: signature, both architectures, and the full self-test executed from
the mounted image. See [Docs/DISTRIBUTION.md](Docs/DISTRIBUTION.md) for code
signing and notarization: ad-hoc signing triggers Gatekeeper on other Macs, and
a Developer ID certificate plus notarization is required for warning-free
downloads. `SIGN_IDENTITY="Developer ID Application: …" bash scripts/make-dmg.sh`
uses a real identity when one is available.

## Verify the engine headlessly

```bash
./build/PaintCraft.app/Contents/MacOS/PaintCraft --selftest
```

This exercises the raster model, image orientation, geometry operations,
pencil/undo/redo, flood fill, shapes, selections (including copy/delete/paste/
move/nudge), the native document format, PNG export, BMP round-trip, the
adjustment pipeline, background removal and smart guides. Exit code 0 = pass.

## Using it

- **Left click** in the palette sets the primary colour, **right click** the
  secondary colour.
- **Pencil** P · **Brush** B · **Eraser** E · **Airbrush** A · **Fill** F ·
  **Picker** I · **Magnifier** M · **Text** T · **Line** L · **Curve** C ·
  **Rectangle** R · **Ellipse** O · **Select** S.
- Zoom with the scroll gesture (⌘-scroll or pinch); pan with two fingers or by
  holding space and dragging. Fit-to-window until you zoom manually.
- Layers, history and colours live in the right inspector. Colour adjustments
  open from the inspector's Colors tab.
- Save native documents as `.paintcraft` (keeps layers); export PNG/JPEG/TIFF/GIF
  or a Paint-compatible 24-bit BMP via File → Export Image.

## Documentation

- [Docs/SPEC.md](Docs/SPEC.md) — feature specification and architecture.
- [Docs/RE-FINDINGS.md](Docs/RE-FINDINGS.md) — how the behaviour was derived,
  evidence, deviations, confidence and gaps.

## Layout

```
Sources/     Swift sources (single module, compiled by swiftc)
Bundle/      Info.plist and bundle resources
Tools/       build-time helpers (app icon generator)
scripts/     build + verification harness (serialized builds, window capture)
Docs/        specification and reverse-engineering notes
Tests/       scratch area for exploratory harnesses
build/       build output (app bundle, module cache, screenshots)
```
