#!/bin/bash
# Builds a distributable universal (arm64 + x86_64) PaintCraft.app and packages
# it into a compressed DMG with a drag-to-Applications layout.
#
# Usage:
#   bash scripts/make-dmg.sh                 # ad-hoc signing (default)
#   SIGN_IDENTITY="Apple Development: …" bash scripts/make-dmg.sh
#
# Output: build/PaintCraft-<version>-universal.dmg (+ .sha256)
# The script verifies the mounted DMG: signature, both architectures, and a full
# headless self-test executed from the mounted volume.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

APP_NAME="PaintCraft"
BUILD="build"
SDK=$(xcrun --show-sdk-path)
CACHE="$PWD/$BUILD/cache"
TMP="$PWD/$BUILD/tmp"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc
export CLANG_MODULE_CACHE_PATH="$CACHE" SWIFT_MODULE_CACHE_PATH="$CACHE" TMPDIR="$TMP"
mkdir -p "$CACHE" "$TMP" "$BUILD"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Bundle/Info.plist)
DMG="$BUILD/${APP_NAME}-${VERSION}-universal.dmg"
APP="$BUILD/${APP_NAME}.app"
STAGE="$BUILD/dmg-stage"
MNT="$BUILD/dmg-mnt"

fail() { echo "DMG-FAIL: $*" >&2; exit 1; }

compile_slice() {
  local target="$1" out="$2"
  echo "==> compiling $target"
  swiftc -sdk "$SDK" -target "$target" -module-name PaintCraft \
    -module-cache-path "$CACHE" -O -whole-module-optimization Sources/*.swift \
    -framework AppKit -framework CoreGraphics -framework CoreImage \
    -framework UniformTypeIdentifiers -framework QuartzCore \
    -o "$out" || fail "compile $target"
}

echo "== 1. build slices"
compile_slice arm64-apple-macos13.0 "$BUILD/PaintCraft-arm64"
compile_slice x86_64-apple-macos13.0 "$BUILD/PaintCraft-x86"

echo "== 2. universal binary"
lipo -create -output "$BUILD/PaintCraft-universal" \
  "$BUILD/PaintCraft-arm64" "$BUILD/PaintCraft-x86"
lipo -info "$BUILD/PaintCraft-universal"
lipo -info "$BUILD/PaintCraft-universal" | grep -q "arm64" || fail "missing arm64"
lipo -info "$BUILD/PaintCraft-universal" | grep -q "x86_64" || fail "missing x86_64"

echo "== 3. assemble app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/PaintCraft-universal" "$APP/Contents/MacOS/PaintCraft"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
[ -f "$BUILD/AppIcon.icns" ] && cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "== 4. sign (identity: $SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP" || fail "ad-hoc codesign"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP" || fail "codesign with identity"
fi
codesign --verify --deep --strict "$APP" || fail "codesign verify"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Authority" || true

echo "== 5. smoke-run self-test (local build)"
"$APP/Contents/MacOS/PaintCraft" --selftest > "$BUILD/dmg-selftest.log" 2>&1 \
  || { tail -20 "$BUILD/dmg-selftest.log"; fail "self-test"; }
grep -E "passed, .* failed" "$BUILD/dmg-selftest.log" | tail -1

echo "== 6. stage DMG contents"
rm -rf "$STAGE" "$MNT"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Cara Install.txt" <<'TXT'
PaintCraft — cara install
=========================

1. Buka file DMG ini (klik dua kali).
2. Seret ikon "PaintCraft" ke folder "Applications" di sebelahnya.
3. Keluarkan DMG (tombol eject), lalu buka PaintCraft dari folder Applications.

Catatan Gatekeeper
-------------------
Aplikasi ini ditandatangani secara lokal (ad-hoc) dan TIDAK dinotarisasi oleh
Apple karena memerlukan sertifikat "Developer ID Application" dari Apple
Developer Program. Saat pertama dibuka di komputer lain, macOS bisa menolak
dengan pesan "tidak dapat dibuka karena pengembang tidak dapat diverifikasi".

Cara membukanya (pilih salah satu):
  a. Klik kanan ikon PaintCraft -> Open -> Open (hanya sekali).
  b. System Settings -> Privacy & Security -> "Open Anyway".
  c. Terminal:  xattr -dr com.apple.quarantine /Applications/PaintCraft.app

Syarat sistem
-------------
macOS 13 atau lebih baru. Paket ini universal: berjalan native di Apple
Silicon maupun Intel (Intel via Rosetta bila diperlukan).

Tentang proyek
--------------
PaintCraft adalah implementasi clean-room (kode dan aset dibuat sendiri) yang
terinspirasi pengalaman Microsoft Paint. Tidak ada kode, ikon, string, atau aset
Microsoft yang disalin, dan aplikasi ini tidak berafiliasi dengan Microsoft.
TXT
cp README.md "$STAGE/README.md" 2>/dev/null || true

echo "== 7. create DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null \
  || fail "hdiutil create"
ls -lh "$DMG" | awk '{print "   " $5, $9}'

echo "== 8. verify mounted DMG"
mkdir -p "$MNT"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MNT" >/dev/null || fail "attach"
cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

MAPP="$MNT/$APP_NAME.app"
[ -d "$MAPP" ] || fail "app missing from DMG"
codesign --verify --deep --strict "$MAPP" || fail "mounted signature"
lipo -info "$MAPP/Contents/MacOS/$APP_NAME" | grep -q x86_64 || fail "mounted x86_64 slice"
"$MAPP/Contents/MacOS/$APP_NAME" --selftest > "$BUILD/dmg-mount-selftest.log" 2>&1 \
  || { tail -20 "$BUILD/dmg-mount-selftest.log"; fail "self-test from mounted DMG"; }
grep -E "passed, .* failed" "$BUILD/dmg-mount-selftest.log" | tail -1
[ -L "$MNT/Applications" ] || fail "Applications symlink missing"

cleanup
trap - EXIT

echo "== 9. hashes"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo
echo "DMG OK -> $DMG"
echo "  size:      $(du -h "$DMG" | cut -f1)"
echo "  signature: $SIGN_IDENTITY"
echo "  sha256:    $(cut -d' ' -f1 "$DMG.sha256")"
echo
echo "Gatekeeper note:"
spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/  /' || true
echo "  A Developer ID certificate + notarization is required for download-by-stranger"
echo "  distribution without a right-click-Open. See Docs/DISTRIBUTION.md."
