#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# The checked-in Xcode project is ready to build without XcodeGen. Regenerate
# explicitly with `xcodegen generate` after changing project.yml.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-widget-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
DERIVED_DATA="${QUOTABAR_DERIVED_DATA:-${TMPDIR:-/tmp}/quotabar-widget-derived}"
SIGN_IDENTITY="${QUOTABAR_SIGN_IDENTITY:--}"
BUILD_LOG="$STAGING_DIR/build.log"
if ! xcodebuild -project QuotaBar.xcodeproj -scheme QuotaBar -configuration Release \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO \
    build > "$BUILD_LOG" 2>&1; then
    rg -n -C 3 "error:|BUILD FAILED" "$BUILD_LOG" | head -65
    exit 1
fi
APP="$STAGING_DIR/QuotaBar.app"
ditto --norsrc "$DERIVED_DATA/Build/Products/Release/QuotaBar.app" "$APP"
chmod +x "$APP/Contents/Resources/RepairClaude.command"
# A per-installation bearer credential and an unused loopback port. These are
# embedded only in built bundles and never printed or committed.
python3 - "$APP" <<'PYCONFIG'
import plistlib, secrets, socket, sys
from pathlib import Path
app = Path(sys.argv[1])
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
token = secrets.token_hex(32)
for path in [app/'Contents/Info.plist', app/'Contents/PlugIns/QuotaBarWidgets.appex/Contents/Info.plist']:
    data = plistlib.loads(path.read_bytes())
    data['QuotaBarLocalPort'] = port
    data['QuotaBarLocalToken'] = token
    path.write_bytes(plistlib.dumps(data))
PYCONFIG
sign_bundle() {
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - --entitlements "$1" "$2"
    else
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements "$1" "$2"
    fi
}
sign_bundle "Resources/Signing/QuotaBarWidgets.entitlements" "$APP/Contents/PlugIns/QuotaBarWidgets.appex"
sign_bundle "Resources/Signing/QuotaBar.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$PROJECT_DIR/dist"
# Preserve the separately built menu-only app; the widget build is explicit.
APP_OUTPUT="${QUOTABAR_APP_OUTPUT:-$PROJECT_DIR/dist/QuotaBar-Widgets.app}"
if [[ "$APP_OUTPUT" != *.app ]]; then echo 'APP_OUTPUT must end in .app' >&2; exit 1; fi
mkdir -p "$(dirname "$APP_OUTPUT")"
PREVIOUS_APP="$STAGING_DIR/previous-QuotaBar.app"
if [[ -e "$APP_OUTPUT" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_OUTPUT/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != "dev.quotabar.mac" ]]; then echo 'Refusing to replace a different application.' >&2; exit 1; fi
    mv "$APP_OUTPUT" "$PREVIOUS_APP"
fi
if ! ditto --norsrc "$APP" "$APP_OUTPUT"; then
    rm -rf "$APP_OUTPUT"
    if [[ -d "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$APP_OUTPUT"; fi
    exit 1
fi
codesign --verify --deep --strict "$APP_OUTPUT"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/QuotaBar")"
if [[ "$ARCHITECTURES" == *" "* ]]; then ARCHITECTURES=universal; fi
ARCHIVE="$PROJECT_DIR/dist/QuotaBar-Widgets-macOS-$ARCHITECTURES.zip"
ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
echo "Built: $APP_OUTPUT"
echo "Archive: $ARCHIVE"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Local ad-hoc build: native WidgetKit with read-only loopback transport, no App Group."
fi
