#!/bin/bash
# Builds the panel probe without an Xcode project: PanelProbe.app (sandboxed,
# user-selected read-write, ad-hoc signed) and the panel-driver CLI.
# Usage: panel-probe/build.sh <output dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?output dir}"
mkdir -p "$OUT"
APP="$OUT/PanelProbe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
TARGET="$(uname -m)-apple-macos14.0"
xcrun swiftc -parse-as-library -O -target "$TARGET" \
  -o "$APP/Contents/MacOS/PanelProbe" "$HERE/PanelProbe.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PanelProbe</string>
  <key>CFBundleIdentifier</key><string>dev.probe.a11y.panel</string>
  <key>CFBundleName</key><string>PanelProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements "$HERE/PanelProbe.entitlements" "$APP"
xcrun swiftc -O -target "$TARGET" -o "$OUT/panel-driver" "$HERE/driver.swift"
codesign -d --entitlements - "$APP" 2>&1
echo "BUILT $APP $OUT/panel-driver"
