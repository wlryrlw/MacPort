#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CACHE_DIR="$PROJECT_DIR/.swift-cache"

mkdir -p "$CACHE_DIR/module" "$CACHE_DIR/clang" "$CACHE_DIR/package"

SWIFT_MODULECACHE_PATH="$CACHE_DIR/module" \
CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_DIR/module" \
SWIFTPM_PACKAGECACHE="$CACHE_DIR/package" \
swift build --configuration release

APP_DIR="$PROJECT_DIR/dist/MacPort.app"
CONTENTS_DIR="$APP_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_DIR="$CONTENTS_DIR/MacOS"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release"

mkdir -p "$BIN_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/MacPort" "$BIN_DIR/MacPort"
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -d "$BUILD_DIR/MacPort_MacPort.bundle" ]; then
    cp -R "$BUILD_DIR/MacPort_MacPort.bundle" "$RESOURCES_DIR/MacPort_MacPort.bundle"
fi

chmod 755 "$BIN_DIR/MacPort"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

printf '%s\n' "$APP_DIR"
