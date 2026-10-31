#!/bin/bash
# Full end-to-end verification for PaintCraft:
#   typecheck -> build -> headless selftest -> demo document -> launch with the
#   demo -> assert an on-screen window -> capture it -> assert rendered pixels.
# Exit code 0 only when every stage passes. Prints a short report.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
APP="$PWD/build/PaintCraft.app"
BIN="$APP/Contents/MacOS/PaintCraft"
SDK=$(xcrun --show-sdk-path)
CACHE="$PWD/build/cache"
TMP="$PWD/build/tmp"
mkdir -p "$CACHE" "$TMP"
export CLANG_MODULE_CACHE_PATH="$CACHE" SWIFT_MODULE_CACHE_PATH="$CACHE" TMPDIR="$TMP"

fail() { echo "VERIFY-FAIL: $*"; exit 1; }

echo "== 1. typecheck"
bash scripts/build.sh typecheck >build/verify-typecheck.log 2>&1 || {
  grep -E "error:" build/verify-typecheck.log | head -20; fail "typecheck"; }
echo "   OK"

echo "== 2. build"
bash scripts/build.sh build >build/verify-build.log 2>&1 || {
  grep -E "error:" build/verify-build.log | head -20; fail "build"; }
echo "   OK"

echo "== 3. headless selftest"
"$BIN" --selftest >build/verify-selftest.log 2>&1 || {
  tail -30 build/verify-selftest.log; fail "selftest"; }
SUMMARY=$(grep -E "passed, .* failed" build/verify-selftest.log | tail -1)
echo "   $SUMMARY"

echo "== 4. demo document through the real pipeline"
"$BIN" --make-demo build/demo.paintcraft >build/verify-demo.log 2>&1 || fail "demo generation"
echo "   $(tail -1 build/verify-demo.log)"

echo "== 5. launch app with the demo"
pkill -x PaintCraft 2>/dev/null; sleep 1
( nohup "$BIN" --open "$PWD/build/demo.paintcraft" >build/verify-run.log 2>&1 & )
for _ in $(seq 1 40); do pgrep -x PaintCraft >/dev/null && break; sleep 0.5; done
pgrep -x PaintCraft >/dev/null || fail "app did not stay running"

echo "== 6. window presence"
WINDOW=$(swift scripts/windowlist.swift PaintCraft 2>/dev/null | awk '$4 > 800 && $5 > 600 {print; exit}')
[ -n "$WINDOW" ] || fail "no PaintCraft window found"
WID=$(echo "$WINDOW" | awk '{print $1}')
echo "   window $WINDOW"

echo "== 7. capture"
sleep 2
screencapture -x -o -l"$WID" build/shot-verified.png || fail "screencapture"
[ -s build/shot-verified.png ] || fail "empty screenshot"

echo "== 8. rendered-pixel assertions"
python3 scripts/check_image.py build/shot-verified.png || fail "image content"

echo
echo "VERIFY-ALL OK"
echo "  selftest:  $SUMMARY"
echo "  window:    $WINDOW"
echo "  screenshot: build/shot-verified.png"
