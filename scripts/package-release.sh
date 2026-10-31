#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
PACKAGE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-release.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
APP_OUTPUT="${QUOTABAR_APP_OUTPUT:-$PACKAGE_STAGE/QuotaBar.app}"
QUOTABAR_APP_OUTPUT="$APP_OUTPUT" bash scripts/build-widget-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_OUTPUT/Contents/Info.plist")"
ARCHITECTURES="$(lipo -archs "$APP_OUTPUT/Contents/MacOS/QuotaBar")"
if [[ "$ARCHITECTURES" == *" "* ]]; then ARCHITECTURES=universal; fi
ARCHIVE="$PROJECT_DIR/dist/QuotaBar-macOS-$ARCHITECTURES.zip"
cp "$PROJECT_DIR/dist/QuotaBar-Widgets-macOS-$ARCHITECTURES.zip" "$ARCHIVE"
mkdir -p "$PACKAGE_STAGE/image"
ditto --norsrc "$APP_OUTPUT" "$PACKAGE_STAGE/image/QuotaBar.app"
codesign --verify --deep --strict "$PACKAGE_STAGE/image/QuotaBar.app"
ln -s /Applications "$PACKAGE_STAGE/image/Applications"
cp Resources/AppIcon.icns "$PACKAGE_STAGE/image/.VolumeIcon.icns"
cat > "$PACKAGE_STAGE/image/安装说明.txt" <<'NOTES'
QuotaBar · macOS 原生用量看板

支持 macOS 14 或更高版本，Intel 与 Apple Silicon 通用。

1. 将 QuotaBar.app 拖入 Applications（应用程序）。
2. 打开 QuotaBar，菜单栏会出现用量图标。
3. 右键桌面 → 编辑小组件 → 搜索 QuotaBar，选择统计范围和尺寸。
4. 保持菜单栏应用运行，以便原生小组件持续获取本机统计。

此版本采用本地临时签名，未进行 Apple 公证。首次从网络下载后，macOS 可能要求在「系统设置 → 隐私与安全性 → 仍要打开」确认来源。

Token 来自本机日志；USD 金额为 API 参考折合，不代表订阅账单。
源码与更新：https://github.com/yann-su/quota-bar
NOTES
if xcrun --find SetFile >/dev/null 2>&1; then xcrun SetFile -a C "$PACKAGE_STAGE/image"; fi
DMG="$PROJECT_DIR/dist/QuotaBar-macOS-$ARCHITECTURES.dmg"
hdiutil create -quiet -ov -volname "QuotaBar $VERSION" -srcfolder "$PACKAGE_STAGE/image" -format UDZO "$DMG"
(
    cd "$PROJECT_DIR/dist"
    shasum -a 256 "$(basename "$ARCHIVE")" "$(basename "$DMG")" > SHA256SUMS.txt
)
echo "Release $VERSION: $ARCHIVE"
echo "Release $VERSION: $DMG"
echo "Checksums: $PROJECT_DIR/dist/SHA256SUMS.txt"
