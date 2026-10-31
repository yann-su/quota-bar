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
APP_OUTPUT="${QUOTABAR_APP_OUTPUT:-$PROJECT_DIR/dist/QuotaBar.app}"
if [[ "$APP_OUTPUT" != *.app ]]; then echo 'APP_OUTPUT must end in .app' >&2; exit 1; fi
mkdir -p "$(dirname "$APP_OUTPUT")"
PREVIOUS_APP="$STAGING_DIR/previous-QuotaBar.app"
if [[ -e "$APP_OUTPUT" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_OUTPUT/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != "dev.quotabar.mac" ]]; then echo 'Refusing to replace a different application.' >&2; exit 1; fi
    mv "$APP_OUTPUT" "$PREVIOUS_APP"
fi
# Copy into a fresh bundle so a previous WidgetKit PlugIns directory is not
# retained by ditto's merge behavior. Restore the previous app on copy failure.
if ! ditto --norsrc "$APP" "$APP_OUTPUT"; then
    rm -rf "$APP_OUTPUT"
    if [[ -d "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$APP_OUTPUT"; fi
    exit 1
fi
codesign --verify --deep --strict "$APP_OUTPUT"
ARCHIVE="$PROJECT_DIR/dist/QuotaBar-macOS-$(uname -m).zip"
ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
echo "Built: $APP_OUTPUT"
echo "Archive: $ARCHIVE"
