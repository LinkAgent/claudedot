#!/usr/bin/env python3
"""Merge the status-bar hooks into ~/.claude/settings.json idempotently.

Usage: python3 install_hooks.py <hook_command>
       python3 install_hooks.py --uninstall

We tag our entries so they can be recognised and removed cleanly without
disturbing any hooks the user has configured themselves.
"""

import json
import os
import sys

SETTINGS = os.path.expanduser("~/.claude/settings.json")
TAG = "cc-statusbar"  # marker stored on each entry we add

# Events we hook, and whether they take a tool matcher.
EVENTS = {
    "SessionStart": False,
    "UserPromptSubmit": False,
    "PreToolUse": True,
    "PostToolUse": True,
    "Notification": False,
    "Stop": False,
    "SubagentStop": False,
    "SessionEnd": False,
}


def load():
    try:
        with open(SETTINGS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except Exception as e:
        print(f"error: could not parse {SETTINGS}: {e}", file=sys.stderr)
        sys.exit(1)


def save(data):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    # Back up once before our first modification this run.
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            backup = f.read()
        with open(SETTINGS + ".statusbar-bak", "w") as f:
            f.write(backup)
    with open(SETTINGS, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def strip_ours(groups):
    """Remove our previously-installed entries from an event's group list.
    Groups left with no hooks are dropped entirely."""
    cleaned = []
    for group in groups:
        original = group.get("hooks", [])
        hooks = [h for h in original if h.get("_tag") != TAG]
        if not hooks:
            continue  # group became empty (or only ever held our hook) -> drop
        if len(hooks) != len(original):
            group = dict(group)
            group["hooks"] = hooks
        cleaned.append(group)
    return cleaned


def install(command):
    data = load()
    hooks = data.setdefault("hooks", {})
    for event, has_matcher in EVENTS.items():
        groups = hooks.get(event, [])
        groups = strip_ours(groups)  # remove stale copies first (idempotent)
        entry = {"type": "command", "command": command, "_tag": TAG}
        if has_matcher:
            groups.append({"matcher": "*", "hooks": [entry]})
        else:
            groups.append({"hooks": [entry]})
        hooks[event] = groups
    save(data)
    print(f"Installed status-bar hooks for {len(EVENTS)} events into {SETTINGS}")


def uninstall():
    existed = os.path.exists(SETTINGS)
    data = load()
    hooks = data.get("hooks", {})
    changed = False
    for event in list(hooks.keys()):
        before = json.dumps(hooks[event])
        hooks[event] = strip_ours(hooks[event])
        if not hooks[event]:
            del hooks[event]
        if json.dumps(hooks.get(event, [])) != before:
            changed = True
    if not hooks:
        data.pop("hooks", None)
    if changed:
        save(data)
        print("Removed status-bar hooks")
    elif existed:
        print("No status-bar hooks found")
    else:
        print("No status-bar hooks found (no settings.json)")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--uninstall":
        uninstall()
    elif len(sys.argv) >= 2:
        install(sys.argv[1])
    else:
        print("usage: install_hooks.py <command> | --uninstall", file=sys.stderr)
        sys.exit(2)
