#!/bin/bash
# Builds dist/NotchAgents-<version>.dmg: the app and an Applications shortcut on a drawn background,
# laid out so you drag one onto the other. Finder sets the layout, so the first run may ask to let
# Terminal control Finder.
# The app is ad-hoc signed (not notarized), so first launch needs Privacy & Security → Open Anyway; see README.
set -euo pipefail
cd "$(dirname "$0")"

# Finder finds disks by name, so another mounted "NotchAgents" volume would get the layout instead.
if [ -d /Volumes/NotchAgents ]; then echo "Eject the mounted NotchAgents disk image first."; exit 1; fi

./build.sh --app-only
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/NotchAgents.app/Contents/Info.plist)
WORK=$(mktemp -d)
MNT="$WORK/mnt"
trap 'hdiutil detach "$MNT" -force >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# Background art, drawn by the app itself at 1× and 2×, packed into one Retina-aware TIFF.
mkdir -p "$WORK/stage/.background"
build/NotchAgents.app/Contents/MacOS/NotchAgents --render-dmg-background "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/stage/.background/background.tiff" >/dev/null
ditto build/NotchAgents.app "$WORK/stage/NotchAgents.app"
ln -s /Applications "$WORK/stage/Applications"

# Writable image first, so Finder can store the window layout in it.
hdiutil create -volname NotchAgents -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
mkdir -p "$MNT"
hdiutil attach "$WORK/rw.dmg" -mountpoint "$MNT" -noautoopen >/dev/null
osascript <<OSA
tell application "Finder"
  set d to (POSIX file "$MNT" as alias)
  open d
  delay 2
  set w to container window of d
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set bounds of w to {200, 120, 860, 568}
  set o to icon view options of w
  set arrangement of o to not arranged
  set icon size of o to 128
  set text size of o to 13
  set background picture of o to (POSIX file "$MNT/.background/background.tiff" as alias)
  set position of item "NotchAgents.app" of d to {170, 250}
  set position of item "Applications" of d to {490, 250}
  update d without registering applications
  delay 1
  close w
end tell
OSA
chflags hidden "$MNT/.background"
sync
hdiutil detach "$MNT" >/dev/null

mkdir -p dist
DMG="dist/NotchAgents-$VERSION.dmg"
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
shasum -a 256 "$DMG"
