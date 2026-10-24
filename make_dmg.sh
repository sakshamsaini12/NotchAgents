#!/bin/bash
# Builds dist/NotchAgents-<version>.dmg: the app and an Applications shortcut on a drawn background,
# laid out so you drag one onto the other.
# The window layout is written by dmgbuild (pinned, hash-checked, in a throwaway venv) rather than by
# scripting Finder: Finder's layout records the build machine's disk ids, dmgbuild's records only the
# disk image itself.
# The app is ad-hoc signed (not notarized), so first launch needs Privacy & Security → Open Anyway; see README.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --app-only
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/NotchAgents.app/Contents/Info.plist)

VENV=build/dmgbuild-venv
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check --require-hashes --no-deps -r tools/dmg-requirements.txt
fi

# Background art, drawn by the app itself at 1× and 2×, packed into one Retina-aware TIFF.
ART=build/dmg-art
rm -rf "$ART" && mkdir -p "$ART"
build/NotchAgents.app/Contents/MacOS/NotchAgents --render-dmg-background "$ART"
tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1

mkdir -p dist
DMG="dist/NotchAgents-$VERSION.dmg"
rm -f "$DMG"
# hdiutil's deprecation notices are noise; anything else is shown if the build fails.
out=$("$VENV/bin/dmgbuild" -s tools/dmg_settings.py -D app=build/NotchAgents.app -D background="$ART/background.tiff" \
  NotchAgents "$DMG" 2>&1) || { echo "$out" >&2; exit 1; }
SUM=$(shasum -a 256 "$DMG" | awk '{print $1}')
# install.sh only installs a download whose checksum matches the one it carries.
sed -i '' -e "s/^VERSION=.*/VERSION=$VERSION/" -e "s/^SHA256=.*/SHA256=$SUM/" install.sh
echo "$SUM  $DMG"
