#!/bin/bash
# Builds build/SuperSpotlight-<version>.dmg (drag-to-Applications layout) from a fresh app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
APP="build/Super Spotlight.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/SuperSpotlight-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Super Spotlight" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG"
