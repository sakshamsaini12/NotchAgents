#!/bin/bash
# Installs NotchAgents from its GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/sakshamsaini12/NotchAgents/main/install.sh | bash
#
# What it does, and nothing else:
#   1. Downloads the release DMG from GitHub.
#   2. Checks its SHA-256 against the one written below, and stops if they differ.
#   3. Checks the app's code signature is intact.
#   4. Copies NotchAgents.app into /Applications (or ~/Applications) and opens it.
# Needs no password and changes no system settings. Files downloaded with curl aren't marked as
# quarantined, so macOS doesn't show the "not opened" warning; the checksum is what vouches for the file.
set -euo pipefail

VERSION=1.0.1
SHA256=d1658b27201989a76684d72f3532e860c47b0e1a0608e917a2ad5ed3c982db08
URL="https://github.com/sakshamsaini12/NotchAgents/releases/download/v$VERSION/NotchAgents-$VERSION.dmg"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf 'NotchAgents install failed: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "NotchAgents runs on macOS only."
[ "$(uname -m)" = arm64 ] || fail "NotchAgents needs an Apple silicon Mac."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || fail "NotchAgents needs macOS 15 (Sequoia) or later."

tmp=$(mktemp -d)
mnt="$tmp/mnt"
cleanup() { hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

say "Downloading NotchAgents ${VERSION}…"
curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "$tmp/NotchAgents.dmg" "$URL" || fail "download failed."

say "Checking the download…"
got=$(shasum -a 256 "$tmp/NotchAgents.dmg" | awk '{print $1}')
[ "$got" = "$SHA256" ] || fail "checksum mismatch (expected $SHA256, got $got). Nothing was installed."

mkdir -p "$mnt"
hdiutil attach "$tmp/NotchAgents.dmg" -mountpoint "$mnt" -nobrowse -readonly -quiet || fail "couldn't open the disk image."
codesign --verify --deep --strict "$mnt/NotchAgents.app" 2>/dev/null || fail "the app's signature doesn't verify. Nothing was installed."

dest=/Applications
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
if pgrep -xq NotchAgents; then
  say "Quitting the running NotchAgents…"
  osascript -e 'tell application "NotchAgents" to quit' >/dev/null 2>&1 || pkill -x NotchAgents || true
  sleep 1
fi
rm -rf "$dest/NotchAgents.app"
ditto "$mnt/NotchAgents.app" "$dest/NotchAgents.app"

say "Installed to $dest/NotchAgents.app"
open "$dest/NotchAgents.app"
echo "Next: click the orb in the menu bar → Install Claude Code hooks, then start a new Claude Code session."
