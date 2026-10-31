#!/bin/bash
# PaintCraft build + verification harness.
# Usage:
#   scripts/build.sh typecheck   -> fast compile check (serialized)
#   scripts/build.sh build       -> compile + assemble .app (serialized)
#   scripts/build.sh run         -> build, launch, wait
#   scripts/build.sh shot        -> build, launch, capture app window only
#   scripts/build.sh verify      -> build, launch, assert window exists
# Builds are serialized with a lock directory so parallel teammates do not
# clobber the module cache or the output binary.
set -uo pipefail
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache"
export SWIFT_MODULE_CACHE_PATH="$PWD/build/cache"
export TMPDIR="$PWD/build/tmp"
cd "$(dirname "$0")/.." || exit 1
SDK=$(xcrun --show-sdk-path)
CACHE="$PWD/build/cache"
TMP="$PWD/build/tmp"
BIN="$PWD/build/PaintCraft"
APP="$PWD/build/PaintCraft.app"
LOCK="$PWD/build/.buildlock"
mkdir -p "$CACHE" "$TMP" build

acquire_lock() {
  local waited=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    sleep 1; waited=$((waited+1))
    if [ "$waited" -gt 240 ]; then echo "!! build lock timeout" >&2; exit 1; fi
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}

compile() {
  local mode="$1"
  local flags="-Onone -g"
  if [ "$mode" = "typecheck" ]; then
    CLANG_MODULE_CACHE_PATH="$CACHE" SWIFT_MODULE_CACHE_PATH="$CACHE" TMPDIR="$TMP" \
    swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -module-name PaintCraft \
      -module-cache-path "$CACHE" -typecheck Sources/*.swift \
      -framework AppKit -framework CoreGraphics -framework CoreImage \
      -framework UniformTypeIdentifiers -framework QuartzCore 2>&1
  else
    CLANG_MODULE_CACHE_PATH="$CACHE" SWIFT_MODULE_CACHE_PATH="$CACHE" TMPDIR="$TMP" \
    swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -module-name PaintCraft \
      -module-cache-path "$CACHE" $flags Sources/*.swift \
      -framework AppKit -framework CoreGraphics -framework CoreImage \
      -framework UniformTypeIdentifiers -framework QuartzCore \
      -o "$BIN" 2>&1
  fi
}

assemble() {
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/PaintCraft"
  cp Bundle/Info.plist "$APP/Contents/Info.plist"
  [ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  codesign --force --sign - "$APP" 2>/dev/null
}

relaunch() {
  pkill -x PaintCraft 2>/dev/null
  sleep 1
  open "$APP"
  for _ in $(seq 1 20); do
    pgrep -f "PaintCraft.app/Contents/MacOS/PaintCraft" >/dev/null && break
    sleep 0.5
  done
  sleep 2
}

case "${1:-build}" in
  typecheck)
    acquire_lock
    if out=$(compile typecheck); then echo "TYPECHECK OK"; exit 0; else echo "$out" | head -40; exit 1; fi ;;
  build)
    acquire_lock
    if out=$(compile build); then assemble; echo "BUILD OK -> $APP"; exit 0
    else echo "$out" | grep -E "error:" | head -40; exit 1; fi ;;
  run)
    acquire_lock; if ! out=$(compile build); then echo "$out" | grep -E "error:" | head -40; exit 1; fi
    assemble; echo "BUILD OK"; relaunch; echo "RUNNING pid=$(pgrep -f 'PaintCraft.app/Contents/MacOS/PaintCraft' | head -1)" ;;
  shot)
    acquire_lock; if ! out=$(compile build); then echo "$out" | grep -E "error:" | head -40; exit 1; fi
    assemble; relaunch
    WID=$(CLANG_MODULE_CACHE_PATH="$CACHE" SWIFT_MODULE_CACHE_PATH="$CACHE" TMPDIR="$TMP" \
          swift scripts/windowlist.swift PaintCraft 2>/dev/null | awk '$4 > 1000 {print $1; exit}')
    if [ -z "${WID:-}" ]; then echo "!! window not found"; exit 1; fi
    screencapture -x -o -l"$WID" build/shot-window.png
    echo "SHOT OK -> build/shot-window.png (window $WID)" ;;
  demo)
    acquire_lock; if ! out=$(compile build); then echo "$out" | grep -E "error:" | head -40; exit 1; fi
    assemble
    "$APP/Contents/MacOS/PaintCraft" --make-demo build/demo.paintcraft || exit 1
    pkill -x PaintCraft 2>/dev/null; sleep 1
    # Detached launch with the demo document. (LaunchServices `open -a` needs the
    # bundle registered; the Finder path is tested separately via application(_:openFile:).)
    ( nohup "$APP/Contents/MacOS/PaintCraft" --open "$PWD/build/demo.paintcraft" \
        > build/demo-run.log 2>&1 & )
    for _ in $(seq 1 40); do
      pgrep -f "PaintCraft.app/Contents/MacOS/PaintCraft" >/dev/null && break; sleep 0.5
    done
    sleep 4
    WID=$(CLANG_MODULE_CACHE_PATH="$CACHE" SWIFT_MODULE_CACHE_PATH="$CACHE" TMPDIR="$TMP" \
          swift scripts/windowlist.swift PaintCraft 2>/dev/null | awk '$4 > 1000 {print $1; exit}')
    if [ -z "${WID:-}" ]; then echo "!! window not found"; exit 1; fi
    screencapture -x -o -l"$WID" build/shot-demo.png
    echo "DEMO SHOT OK -> build/shot-demo.png (window $WID)" ;;
  verify)
    acquire_lock; if ! out=$(compile build); then echo "$out" | grep -E "error:" | head -40; exit 1; fi
    assemble; relaunch
    CLANG_MODULE_CACHE_PATH="$CACHE" SWIFT_MODULE_CACHE_PATH="$CACHE" TMPDIR="$TMP" \
      swift scripts/windowlist.swift PaintCraft || exit 1
    echo "VERIFY OK" ;;
  *)
    echo "usage: $0 {typecheck|build|run|shot|verify}"; exit 2 ;;
esac
