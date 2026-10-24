#!/bin/bash
# Builds build/Super Spotlight.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools lack the SwiftUI macro plugin that the macOS 27 SDK needs; the 26.x SDK works.
if [ -z "${SDKROOT:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do [ -d "$sdk" ] && SDKROOT="$sdk"; done
  export SDKROOT
fi

swift build -c release --product SuperSpotlight --arch arm64 --arch x86_64
BIN="$(swift build -c release --product SuperSpotlight --arch arm64 --arch x86_64 --show-bin-path)/SuperSpotlight"

APP="build/Super Spotlight.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SuperSpotlight"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Super Spotlight</string>
  <key>CFBundleDisplayName</key><string>Super Spotlight</string>
  <key>CFBundleIdentifier</key><string>local.superspotlight</string>
  <key>CFBundleExecutable</key><string>SuperSpotlight</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
