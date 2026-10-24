#!/bin/bash
# Plays a fake Claude CLI session through NotchAgents so every state can be seen:
# activity log -> approval card (answer it, or wait) -> completion alert -> question alert.
HDR="$HOME/.notchagents/token.header"
[ -r "$HDR" ] || { echo "Start NotchAgents first"; exit 1; }
post() { curl -s -m "${2:-2}" -X POST -H @"$HDR" "http://127.0.0.1:47823/hook?src=cli" --data-binary "$1" >/dev/null; }

post '{"hook_event_name":"UserPromptSubmit","cwd":"'"$PWD"'"}'; sleep 1.5
post '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/NotchView.swift"}}'; sleep 1.2
post '{"hook_event_name":"PostToolUse","tool_name":"Read"}'
post '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"IslandAlert"}}'; sleep 1.2
post '{"hook_event_name":"PostToolUse","tool_name":"Grep"}'
post '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"swift build -c release"}}'; sleep 2
post '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
echo "Approval pending — hover the notch, then click Allow/Deny or press ⌘Y/⌘N (20s)…"
post '{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/x/AgentStore.swift","old_string":"static let wing: CGFloat = 74","new_string":"static let wing: CGFloat = 54\nstatic let maxSize = CGSize(width: 620, height: 340)"}}' 20
post '{"hook_event_name":"PostToolUse","tool_name":"Edit"}'; sleep 1
post '{"hook_event_name":"Stop"}'
echo "Completion alert shown. Question alert in 8s…"; sleep 8
post '{"hook_event_name":"UserPromptSubmit"}'
post '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Should the island use SQLite or a JSON file for history?"}]}}'
sleep 6; post '{"hook_event_name":"Stop"}'
echo "Done."
