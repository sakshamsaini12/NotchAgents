#!/bin/bash
# Builds NotchAgents.app, installs the local-only Claude Code hook, and launches.
#   ./build.sh            build + install hook + run
#   ./build.sh --app-only   build build/NotchAgents.app only (used by make_dmg.sh)
#   ./build.sh --uninstall-hooks
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--uninstall-hooks" ]; then
  python3 hooks/install_hooks.py --uninstall; exit 0
fi

swift build -c release
APP=build/NotchAgents.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchAgents "$APP/Contents/MacOS/"
# Drop debug symbols: they embed the build machine's absolute paths (and are dead weight).
strip -S -x "$APP/Contents/MacOS/NotchAgents"

# App icon: the binary draws its own orb, then iconutil packs every size.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
.build/release/NotchAgents --render-icon build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Hook scripts ride along so DMG installs can register them from the menu bar.
install -m 755 hooks/notch-hook.sh hooks/notch-status.sh "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NotchAgents</string>
  <key>CFBundleIdentifier</key><string>local.notchagents</string>
  <key>CFBundleExecutable</key><string>NotchAgents</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CADisableMinimumFrameDurationOnPhone</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
[ "${1:-}" = "--app-only" ] && { echo "Built $APP"; exit 0; }

mkdir -p ~/.notchagents && chmod 700 ~/.notchagents
install -m 700 hooks/notch-hook.sh ~/.notchagents/notch-hook.sh
install -m 700 hooks/notch-status.sh ~/.notchagents/notch-status.sh
python3 hooks/install_hooks.py

pkill -x NotchAgents 2>/dev/null || true
# Wait for the old copy to exit: a new one that still sees it running quits (one island at a time).
for _ in $(seq 50); do pgrep -x NotchAgents >/dev/null || break; sleep 0.1; done
# Install to /Applications (falls back to ~/Applications if not writable).
DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
rm -rf "$DEST/NotchAgents.app"
ditto "$APP" "$DEST/NotchAgents.app"
touch "$DEST/NotchAgents.app"
# Launch without this shell's agent variables (CLAUDE_CONFIG_DIR etc.): `open` passes the caller's
# environment on, and apps NotchAgents opens would inherit it. The app also drops them itself.
(
  for v in $(env | grep -oE '^(CLAUDE|ANTHROPIC_)[A-Za-z0-9_]*' || true); do unset "$v"; done
  open "$DEST/NotchAgents.app"
)
echo "NotchAgents installed to $DEST and running. Hover the notch."
