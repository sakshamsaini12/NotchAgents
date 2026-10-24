#!/bin/bash
# Claude Code status line -> NotchAgents. Claude Code hands this script its session JSON (including
# the plan's 5-hour / weekly usage) on stdin; we forward it to the local app and print nothing.
# Local only (127.0.0.1), token-authenticated, never blocks: the post runs in the background.
# The token is passed from a file (-H @file), never on the command line, where `ps` would show it.
hdr="$HOME/.notchagents/token.header"
[ -r "$hdr" ] || exit 0
payload=$(cat)
# Which Claude this is (see notch-hook.sh): plan limits belong to that login, not the other one's.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  claude-desktop) src=app ;;
  sdk-*) src=sdk ;;
  "") src="" ;;
  *) src=cli ;;
esac
( printf '%s' "$payload" | curl -s -m 1 -X POST -H 'Content-Type: application/json' -H @"$hdr" \
    "http://127.0.0.1:47823/hook?type=status&src=$src" --data-binary @- >/dev/null 2>&1 & )
exit 0
