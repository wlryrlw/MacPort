#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CACHE_DIR="$PROJECT_DIR/.swift-cache"
mkdir -p "$CACHE_DIR/module" "$CACHE_DIR/clang" "$CACHE_DIR/package"

SWIFT_MODULECACHE_PATH="$CACHE_DIR/module" \
CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_DIR/module" \
SWIFTPM_PACKAGECACHE="$CACHE_DIR/package" \
swift test

UV_CACHE_DIR="$PROJECT_DIR/.uv-cache" uv run python -m unittest discover -s "$PROJECT_DIR/tools/tests" -v

