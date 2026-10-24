#!/bin/bash
# Forwards Claude Code hook events to NotchAgents (127.0.0.1:47823).
# Never blocks Claude if the app isn't running: curl fails fast, we exit 0 silently.
payload=$(cat)

src=cli
cpid=""
p=$PPID
for _ in 1 2 3 4 5 6 7 8 9 10; do
  c=$(ps -o comm= -p "$p" 2>/dev/null) || break
  case "$c" in
    *Claude.app*|*"Application Support/Claude"*) src=app ;;
  esac
  if [ -z "$cpid" ]; then
    case "$c" in
      */claude|claude|*/claude-code/*|*/.local/share/claude/versions/*) cpid=$p ;;
      # npm installs run as `node …/bin/claude` or `node …/@anthropic-ai/claude-code/cli.js`
      node|*/node|bun|*/bun)
        case "$(ps -o args= -p "$p" 2>/dev/null)" in
          *@anthropic-ai/claude-code*|*/bin/claude|*"/bin/claude "*) cpid=$p ;;
        esac ;;
    esac
  fi
  [ "$src" = app ] && [ -n "$cpid" ] && break
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  if [ -z "$p" ] || [ "$p" -le 1 ]; then break; fi
done

ev=$(printf '%s' "$payload" | grep -o '"hook_event_name" *: *"[A-Za-z]*"' | head -1 | sed 's/.*"\([A-Za-z]*\)"$/\1/')
t=2
[ "$ev" = "PermissionRequest" ] && t=110

# The token comes from a file (-H @file), never the command line, where `ps` would show it.
hdr="$HOME/.notchagents/token.header"
[ -r "$hdr" ] || exit 0

printf '%s' "$payload" | curl -s -m "$t" -X POST \
  -H 'Content-Type: application/json' -H @"$hdr" \
  "http://127.0.0.1:47823/hook?src=$src&pid=$cpid" --data-binary @- 2>/dev/null
exit 0
