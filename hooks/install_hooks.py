#!/usr/bin/env python3
"""Merge NotchAgents hooks into Claude Code settings. Idempotent: a settings file is only rewritten
(and backed up first) when something actually changes, and the write is atomic."""
import glob, json, os, shlex, shutil, sys, tempfile, time

# Claude Code runs these through a shell, so quote them (home folders can contain spaces).
# Unquoted forms from earlier installs are still recognised, so they're updated, not duplicated.
_HOOK_PATH = os.path.expanduser("~/.notchagents/notch-hook.sh")
_STATUS_PATH = os.path.expanduser("~/.notchagents/notch-status.sh")
HOOK, STATUS = shlex.quote(_HOOK_PATH), shlex.quote(_STATUS_PATH)
HOOKS = {HOOK, _HOOK_PATH}
STATUSES = {STATUS, _STATUS_PATH}
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "Notification", "PermissionRequest", "Stop", "SubagentStop", "SessionEnd"]
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PermissionRequest"}


def config_dirs():
    """~/.claude, $CLAUDE_CONFIG_DIR, and any other ~/.claude* config that already has settings."""
    dirs = {os.path.expanduser("~/.claude")}
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        dirs.add(os.path.expanduser(os.environ["CLAUDE_CONFIG_DIR"]))
    dirs.update(d for d in glob.glob(os.path.expanduser("~/.claude*"))
                if os.path.isfile(os.path.join(d, "settings.json")))
    return sorted(dirs)


def write(path, data):
    shutil.copy2(path, f"{path}.notchagents-backup-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings.", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def load(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        print(f"  skipped {path}: {e}")
        return None


def install(path):
    data = load(path)
    if data is None:
        return
    before = json.dumps(data, sort_keys=True)
    hooks = data.setdefault("hooks", {})
    for ev in EVENTS:
        groups = hooks.setdefault(ev, [])
        for g in groups:
            for h in g.get("hooks", []):
                if h.get("command") in HOOKS:
                    h["command"] = HOOK
        if any(h.get("command") == HOOK for g in groups for h in g.get("hooks", [])):
            continue
        entry = {"hooks": [{"type": "command", "command": HOOK,
                            "timeout": 120 if ev == "PermissionRequest" else 5}]}
        if ev in TOOL_EVENTS:
            entry["matcher"] = "*"
        groups.append(entry)
    # Status line feeds plan usage, cost and context. Never replace a status line the user already has.
    if "statusLine" not in data or data["statusLine"].get("command") in STATUSES:
        data["statusLine"] = {"type": "command", "command": STATUS}
    else:
        print(f"  {path}: kept your existing status line (usage meters need notch-status.sh; see README)")
    if json.dumps(data, sort_keys=True) == before:
        print(f"  hooks already installed -> {path}")
        return
    write(path, data)
    print(f"  hooks installed -> {path}")


def uninstall(path):
    data = load(path)
    if data is None:
        return
    before = json.dumps(data, sort_keys=True)
    hooks = data.get("hooks", {})
    for ev in list(hooks):
        hooks[ev] = [g for g in hooks[ev]
                     if not any(h.get("command") in HOOKS for h in g.get("hooks", []))]
        if not hooks[ev]:
            del hooks[ev]
    if not hooks:
        data.pop("hooks", None)
    if data.get("statusLine", {}).get("command") in STATUSES:
        del data["statusLine"]
    if json.dumps(data, sort_keys=True) != before:
        write(path, data)
        print(f"  hooks removed -> {path}")


if __name__ == "__main__":
    fn = uninstall if "--uninstall" in sys.argv else install
    for d in config_dirs():
        fn(os.path.join(d, "settings.json"))
