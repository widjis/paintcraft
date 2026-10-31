# PaintCraft — native macOS app build (CommandLineTools only, no Xcode project)
# Usage:
#   make            -> release build (optimized)
#   make fast       -> debug-ish fast build for iteration
#   make run        -> build + launch
#   make shot       -> build + launch + screenshot
#   make clean      -> remove build artifacts

APP_NAME     := PaintCraft
BUNDLE_ID    := local.paintcraft.app
BUILD_DIR    := build
APP_BUNDLE   := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS     := $(APP_BUNDLE)/Contents
MACOS_DIR    := $(CONTENTS)/MacOS
RES_DIR      := $(CONTENTS)/Resources
SOURCES      := $(wildcard Sources/*.swift)
SDK          := $(shell xcrun --show-sdk-path)
CACHE        := $(CURDIR)/$(BUILD_DIR)/cache
TMP          := $(CURDIR)/$(BUILD_DIR)/tmp
SWIFTC       := swiftc
COMMON_FLAGS := -sdk $(SDK) -target arm64-apple-macos13.0 -module-name PaintCraft \
                -module-cache-path "$(CACHE)" -Xcc -fmodules-cache-path="$(CACHE)"
FRAMEWORKS   := -framework AppKit -framework CoreGraphics -framework CoreImage \
                -framework UniformTypeIdentifiers -framework QuartzCore
RELEASE_FLAGS := $(COMMON_FLAGS) -O -whole-module-optimization
DEBUG_FLAGS   := $(COMMON_FLAGS) -Onone -g

.PHONY: all fast bundle run shot clean check icon

all: bundle

$(BUILD_DIR)/$(APP_NAME): $(SOURCES)
	@mkdir -p "$(CACHE)" "$(TMP)"
	@echo "==> compiling $(words $(SOURCES)) swift files (release)"
	@CLANG_MODULE_CACHE_PATH="$(CACHE)" SWIFT_MODULE_CACHE_PATH="$(CACHE)" TMPDIR="$(TMP)" \
	 $(SWIFTC) $(RELEASE_FLAGS) $(SOURCES) -o "$@" $(FRAMEWORKS)
	@echo "==> built $@"

fast: $(SOURCES)
	@mkdir -p "$(CACHE)" "$(TMP)"
	@echo "==> compiling $(words $(SOURCES)) swift files (fast)"
	@CLANG_MODULE_CACHE_PATH="$(CACHE)" SWIFT_MODULE_CACHE_PATH="$(CACHE)" TMPDIR="$(TMP)" \
	 $(SWIFTC) $(DEBUG_FLAGS) $(SOURCES) -o "$(BUILD_DIR)/$(APP_NAME)"
	@mkdir -p "$(MACOS_DIR)"
	@cp -f "$(BUILD_DIR)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	@codesign --force --sign - "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "==> fast build ready"

bundle: $(BUILD_DIR)/$(APP_NAME) icon
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@cp -f "$(BUILD_DIR)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	@cp -f Bundle/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f "$(BUILD_DIR)/AppIcon.icns" ]; then cp -f "$(BUILD_DIR)/AppIcon.icns" "$(RES_DIR)/AppIcon.icns"; fi
	@cp -f Bundle/Assets/*.png "$(RES_DIR)/" 2>/dev/null || true
	@codesign --force --sign - "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "==> app bundle: $(APP_BUNDLE)"

icon:
	@if [ ! -f "$(BUILD_DIR)/AppIcon.icns" ]; then mkdir -p "$(BUILD_DIR)"; \
	  CLANG_MODULE_CACHE_PATH="$(CACHE)" TMPDIR="$(TMP)" $(SWIFTC) $(DEBUG_FLAGS) Tools/makeicon.swift -o "$(BUILD_DIR)/makeicon" $(FRAMEWORKS) 2>/dev/null && \
	  "$(BUILD_DIR)/makeicon" "$(BUILD_DIR)/AppIcon.icns" && echo "==> icon generated" || echo "!! icon generation skipped"; fi

run: bundle
	@open "$(APP_BUNDLE)"

shot: bundle
	@mkdir -p "$(BUILD_DIR)"
	@open "$(APP_BUNDLE)"; sleep 4
	@screencapture -x "$(BUILD_DIR)/screenshot-initial.png"
	@echo "==> $(BUILD_DIR)/screenshot-initial.png"

check: bundle
	@echo "==> codesign verify"; codesign -dv "$(APP_BUNDLE)" 2>&1 | head -6
	@echo "==> bundle contents"; ls -la "$(MACOS_DIR)"
	@echo "==> smoke launch"; open "$(APP_BUNDLE)"; sleep 3; pgrep -fl "$(APP_NAME)" | head -2

clean:
	rm -rf "$(BUILD_DIR)" "$(APP_BUNDLE)"
	@echo "==> cleaned"
