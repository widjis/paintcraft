#!/usr/bin/env python3
"""Assert that a captured screenshot looks like the rendered demo scene.

Converts the PNG to BMP with sips (no third-party deps), then checks:
  - dimensions are plausible for a window capture
  - enough distinct colours to be a real artwork, not a blank window
  - presence of warm (sunset/sun) and dark (mountains/night) pixels
Usage: scripts/check_image.py path.png
"""
import struct
import subprocess
import sys
import tempfile
import os

def fail(msg):
    print(f"IMAGE CHECK FAIL: {msg}")
    sys.exit(1)

def main(path):
    if not os.path.exists(path):
        fail(f"missing {path}")
    with tempfile.TemporaryDirectory() as td:
        bmp = os.path.join(td, "shot.bmp")
        r = subprocess.run(["sips", "-s", "format", "bmp", path, "--out", bmp],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fail(f"sips failed: {r.stderr.strip()[:200]}")
        data = open(bmp, "rb").read()
    if data[:2] != b"BM":
        fail("not a BMP after conversion")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    bpp = struct.unpack_from("<H", data, 28)[0]
    if width < 800 or abs(height) < 600:
        fail(f"unexpected window size {width}x{height}")
    if bpp not in (24, 32):
        fail(f"unexpected BMP depth {bpp}")
    h = abs(height)
    row = ((width * bpp // 8) + 3) // 4 * 4
    step = max(1, min(width, h) // 220)
    colours = set()
    warm = dark = 0
    total = 0
    for y in range(0, h, step):
        base = pixel_offset + y * row
        for x in range(0, width, step):
            i = base + x * (bpp // 8)
            if i + 2 >= len(data):
                continue
            b, g, r = data[i], data[i + 1], data[i + 2]
            colours.add((r >> 3, g >> 3, b >> 3))
            total += 1
            if r > 150 and g > 60 and b < 140:
                warm += 1
            if r < 80 and g < 80 and b > 40:
                dark += 1
    if len(colours) < 400:
        fail(f"too few colours ({len(colours)}); window may be blank")
    if warm < total * 0.02:
        fail(f"no sunset tones found (warm={warm}/{total})")
    if dark < total * 0.02:
        fail(f"no dark tones found (dark={dark}/{total})")
    print(f"IMAGE CHECK OK: {width}x{h}, {len(colours)} distinct colours, "
          f"warm={warm/total:.1%}, dark={dark/total:.1%}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_image.py path.png")
        sys.exit(2)
    main(sys.argv[1])
