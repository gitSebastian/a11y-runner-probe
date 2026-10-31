#!/bin/bash
# Builds fixture/Fixture.app without an Xcode project: actool for the asset
# catalog (so Image("icon-settings") resolves from Assets.car), swiftc for the
# code, a minimal Info.plist. Usage: fixture/build.sh <output dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?output dir}"
APP="$OUT/Fixture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun actool "$HERE/Assets.xcassets" --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --output-partial-info-plist "$OUT/assets-partial.plist" >/dev/null
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macos14.0" \
  -o "$APP/Contents/MacOS/Fixture" "$HERE/Fixture.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Fixture</string>
  <key>CFBundleIdentifier</key><string>dev.probe.a11y.fixture</string>
  <key>CFBundleName</key><string>Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
ls "$APP/Contents/Resources"
echo "BUILT $APP"
