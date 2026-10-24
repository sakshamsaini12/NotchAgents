#!/bin/bash
# Builds dist/NotchAgents-<version>.dmg: the app plus an Applications shortcut to drag it onto.
# The app is ad-hoc signed (not notarized), so first launch needs right-click → Open; see README.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --app-only
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/NotchAgents.app/Contents/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/NotchAgents.app "$STAGE/NotchAgents.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="dist/NotchAgents-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname NotchAgents -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
shasum -a 256 "$DMG"
