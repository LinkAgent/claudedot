#!/bin/bash
# Build the menu-bar app into a self-contained .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="claudedot"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> Cleaning previous build"
rm -rf "$APP_BUNDLE"
rm -rf "$BUILD_DIR/ClaudeStatusBar.app"
mkdir -p "$MACOS" "$RES"

echo "==> Compiling Swift ($(swift --version | head -1))"
swiftc -O \
    -framework AppKit \
    -o "$MACOS/$APP_NAME" \
    "$ROOT/app/Sources/Model.swift" \
    "$ROOT/app/Sources/DynamicIsland.swift" \
    "$ROOT/app/Sources/main.swift"

echo "==> Generating app icon"
ICONSET="$BUILD_DIR/ClaudeDot.iconset"
ICON_SRC="$RES/ClaudeDot.png"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
node "$ROOT/scripts/render_icons.js" "$RES"
sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$ICON_SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$RES/ClaudeDot.icns"

echo "==> Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>claudedot</string>
    <key>CFBundleDisplayName</key>     <string>claudedot</string>
    <key>CFBundleIdentifier</key>      <string>com.claudecode.statusbar</string>
    <key>CFBundleIconFile</key>        <string>ClaudeDot</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP_BUNDLE" 2>/dev/null || echo "    (codesign skipped)"

echo "==> Built: $APP_BUNDLE"
