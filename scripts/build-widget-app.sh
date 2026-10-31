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
APP_GROUP="${QUOTABAR_APP_GROUP:-group.dev.quotabar.shared}"
if [[ "$SIGN_IDENTITY" != "-" && -z "${QUOTABAR_APP_GROUP:-}" ]]; then
    echo 'Set QUOTABAR_APP_GROUP to your actual TEAM_ID.dev.quotabar.shared for macOS signing.' >&2
    exit 1
fi
BUILD_LOG="$STAGING_DIR/build.log"
if ! xcodebuild -project QuotaBar.xcodeproj -scheme QuotaBar -configuration Release \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO \
    "QUOTABAR_APP_GROUP=$APP_GROUP" build > "$BUILD_LOG" 2>&1; then
    tail -80 "$BUILD_LOG"
    exit 1
fi
APP="$STAGING_DIR/QuotaBar.app"
ditto --norsrc "$DERIVED_DATA/Build/Products/Release/QuotaBar.app" "$APP"
chmod +x "$APP/Contents/Resources/RepairClaude.command"
for TARGET in QuotaBar QuotaBarWidgets; do
    cp "Resources/Signing/$TARGET.entitlements" "$STAGING_DIR/$TARGET.entitlements"
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $APP_GROUP" "$STAGING_DIR/$TARGET.entitlements"
done
sign_bundle() {
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - --entitlements "$1" "$2"
    else
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements "$1" "$2"
    fi
}
sign_bundle "$STAGING_DIR/QuotaBarWidgets.entitlements" "$APP/Contents/PlugIns/QuotaBarWidgets.appex"
sign_bundle "$STAGING_DIR/QuotaBar.entitlements" "$APP"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    TEAM_ID="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [[ -z "$TEAM_ID" || "$TEAM_ID" == "not set" || "$APP_GROUP" != "$TEAM_ID".* ]]; then
        echo 'The macOS App Group must start with the actual signing Team ID.' >&2
        exit 1
    fi
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$PROJECT_DIR/dist"
# Preserve the separately built menu-only app; the widget build is explicit.
APP_OUTPUT="${QUOTABAR_APP_OUTPUT:-$PROJECT_DIR/dist/QuotaBar-Widgets.app}"
mkdir -p "$(dirname "$APP_OUTPUT")"
ditto --norsrc "$APP" "$APP_OUTPUT"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/QuotaBar")"
if [[ "$ARCHITECTURES" == *" "* ]]; then ARCHITECTURES=universal; fi
ARCHIVE="$PROJECT_DIR/dist/QuotaBar-Widgets-macOS-$ARCHITECTURES.zip"
ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
echo "Built: $APP_OUTPUT"
echo "Archive: $ARCHIVE"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Local ad-hoc build: compile and layout preview only; macOS may deny widget App Group access."
fi
