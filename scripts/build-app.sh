#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/quotabar-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/quotabar-swift-cache"
swift build -c release --disable-sandbox --build-system native --manifest-cache local
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --build-system native --manifest-cache local)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/QuotaBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QuotaBar" "$APP/Contents/MacOS/QuotaBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/RepairClaude.command "$APP/Contents/Resources/RepairClaude.command"
chmod +x "$APP/Contents/Resources/RepairClaude.command"
chmod +x "$APP/Contents/MacOS/QuotaBar"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Stage outside synced folders so File Provider metadata cannot affect signing.
mkdir -p "$PROJECT_DIR/dist"
ditto --norsrc "$APP" "$PROJECT_DIR/dist/QuotaBar.app"
ARCHIVE="$PROJECT_DIR/dist/QuotaBar-macOS-$(uname -m).zip"
ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
echo "Built: $PROJECT_DIR/dist/QuotaBar.app"
echo "Archive: $ARCHIVE"
