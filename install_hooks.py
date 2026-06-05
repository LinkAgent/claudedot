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
# Legacy installs (pre-tagging) wrote entries without _tag. We also identify
# our hooks by command-path substring so re-running install dedupes them.
HOOK_BASENAME = "cc_statusbar_hook.py"

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


def _is_ours(hook):
    """An entry is ours if it carries our tag OR its command runs our hook
    script (legacy installs lacked the tag). Path-matching catches duplicates
    from pre-tagging installs that would otherwise survive every reinstall."""
    if hook.get("_tag") == TAG:
        return True
    cmd = hook.get("command") or ""
    return HOOK_BASENAME in cmd


def strip_ours(groups):
    """Remove our previously-installed entries from an event's group list.
    Groups left with no hooks are dropped entirely."""
    cleaned = []
    for group in groups:
        original = group.get("hooks", [])
        hooks = [h for h in original if not _is_ours(h)]
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


def diagnose():
    """Report on the current hook installation: which events are wired up,
    how many entries each event has, and whether duplicates exist. Exit
    non-zero when something looks off so CI / install scripts can catch it."""
    data = load()
    hooks = data.get("hooks", {})
    problems = 0
    print(f"settings: {SETTINGS}")
    for event in EVENTS:
        groups = hooks.get(event, [])
        ours_count = 0
        tagged = 0
        legacy = 0
        for group in groups:
            for hook in group.get("hooks", []):
                if hook.get("_tag") == TAG:
                    ours_count += 1
                    tagged += 1
                elif HOOK_BASENAME in (hook.get("command") or ""):
                    ours_count += 1
                    legacy += 1
        flag = ""
        if ours_count == 0:
            flag = " MISSING"
            problems += 1
        elif ours_count > 1:
            flag = f" DUPLICATE ({tagged} tagged, {legacy} legacy)"
            problems += 1
        print(f"  {event:<18s} {ours_count} ours{flag}")
    if problems:
        print(f"{problems} problem(s) — run install_hooks.py <command> to repair.")
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--uninstall":
        uninstall()
    elif len(sys.argv) >= 2 and sys.argv[1] == "--diagnose":
        diagnose()
    elif len(sys.argv) >= 2:
        install(sys.argv[1])
    else:
        print("usage: install_hooks.py <command> | --uninstall | --diagnose", file=sys.stderr)
        sys.exit(2)
