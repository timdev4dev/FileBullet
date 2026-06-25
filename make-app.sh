#!/bin/bash
# Builds a release binary and wraps it into a double-clickable FileBullet.app
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building release…"
swift build -c release

APP="FileBullet.app"
BIN=".build/release/FileBullet"
ICON="icon/FileBullet.icns"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FileBullet"
[ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/FileBullet.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>FileBullet</string>
    <key>CFBundleDisplayName</key>     <string>FileBullet</string>
    <key>CFBundleExecutable</key>      <string>FileBullet</string>
    <key>CFBundleIdentifier</key>      <string>local.sftpclient</string>
    <key>CFBundleIconFile</key>        <string>FileBullet</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS lets it run locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Done: $(pwd)/$APP"
echo "    Open it with:  open \"$APP\"    (or drag it into /Applications)"
