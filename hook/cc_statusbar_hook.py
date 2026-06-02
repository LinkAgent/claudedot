#!/usr/bin/env python3
"""Claude Code status-bar hook dispatcher.

Reads a hook payload from stdin (JSON) and updates a per-session state file
under ~/.claude/statusbar/sessions/<session_id>.json. The macOS menu-bar app
watches that directory and renders an aggregate status icon + per-task list.

Design goals:
- Never fail loudly: any error => exit 0, print nothing to stdout.
  (stdout from some hooks, e.g. UserPromptSubmit, is injected as context, so we
   must stay silent.)
- Be fast: a tiny atomic file write, no network, no blocking.

State file schema (one per active session):
{
  "session_id": str,
  "cwd": str,
  "folder": str,            # basename of cwd, for display
  "status": "running" | "waiting" | "error" | "idle",
  "title": str,             # last user prompt (truncated) or folder name
  "last_event": str,        # human-readable last activity
  "last_error": str | null, # most recent error text (sticky, for the dropdown)
  "error_at": float | null, # epoch seconds of last error
  "updated_at": float,      # epoch seconds
  "pending_tool": str|null, # tool awaiting approval (set on PreToolUse)
  "pending_input": str|null,# short summary of that tool's input
  "ended": bool             # set on SessionEnd
}
"""

import json
import os
import sys
import time
import tempfile

STATE_DIR = os.path.expanduser("~/.claude/statusbar/sessions")


def _truncate(text, n=100):
    text = " ".join(str(text).split())
    if len(text) <= n:
        return text
    if n <= 0:
        return ""
    if n == 1:
        return "…"
    return text[: n - 1] + "…"


def _state_path(session_id):
    safe = "".join(c for c in session_id if c.isalnum() or c in "-_") or "unknown"
    return os.path.join(STATE_DIR, safe + ".json")


def _load(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def _atomic_write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


def _pending_summary(payload):
    """Short, human-readable summary of a tool's input for the approval panel.
    e.g. Bash -> the command, WebFetch -> the URL, Edit/Write -> the file."""
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        return None
    for key in ("command", "url", "file_path", "path", "pattern", "query"):
        val = ti.get(key)
        if val:
            return _truncate(val, 80)
    return None


def _detect_tool_error(payload):
    """Best-effort: did this PostToolUse report a failure?

    Returns an error message string, or None.
    """
    resp = payload.get("tool_response")
    # Common shapes: dict with is_error / error / status, or a string.
    if isinstance(resp, dict):
        if resp.get("is_error") is True or resp.get("isError") is True:
            return _truncate(resp.get("error") or resp.get("content") or "tool error")
        status = str(resp.get("status", "")).lower()
        if status in ("error", "failed", "failure"):
            return _truncate(resp.get("error") or resp.get("message") or "tool error")
        if resp.get("error"):
            return _truncate(resp.get("error"))
    return None


def compute_update(payload, prev):
    """Pure function: given a hook payload and the previous state, return the
    new state dict. Separated out so it can be unit-tested without I/O."""
    event = payload.get("hook_event_name", "")
    session_id = payload.get("session_id", "unknown")
    cwd = payload.get("cwd") or prev.get("cwd") or os.getcwd()
    now = payload.get("_now", time.time())

    state = dict(prev)
    state["session_id"] = session_id
    state["cwd"] = cwd
    state["folder"] = os.path.basename(cwd.rstrip("/")) or cwd
    state["updated_at"] = now
    state.setdefault("title", state["folder"])
    state.setdefault("last_error", None)
    state.setdefault("error_at", None)
    state.setdefault("pending_tool", None)
    state.setdefault("pending_input", None)
    state["ended"] = False

    def clear_pending():
        state["pending_tool"] = None
        state["pending_input"] = None

    if event == "SessionStart":
        state["status"] = "idle"
        state["last_event"] = "session started"
        # Fresh session: clear any stale error.
        state["last_error"] = None
        state["error_at"] = None
        clear_pending()

    elif event == "UserPromptSubmit":
        prompt = payload.get("prompt", "")
        state["status"] = "running"
        if prompt.strip():
            state["title"] = _truncate(prompt, 100)
        state["last_event"] = "working on your request"
        # New turn: clear the previous turn's error.
        state["last_error"] = None
        state["error_at"] = None
        clear_pending()

    elif event == "PreToolUse":
        tool = payload.get("tool_name", "tool")
        state["status"] = "running"
        state["last_event"] = "running " + _truncate(tool, 40)
        # Remember what a subsequent approval prompt would be about.
        state["pending_tool"] = tool
        state["pending_input"] = _pending_summary(payload)

    elif event == "PostToolUse":
        tool = payload.get("tool_name", "tool")
        err = _detect_tool_error(payload)
        if err:
            state["status"] = "error"
            state["last_event"] = "error in " + _truncate(tool, 40)
            state["last_error"] = err
            state["error_at"] = now
        else:
            state["status"] = "running"
            state["last_event"] = "finished " + _truncate(tool, 40)
        # The tool resolved (ran or was denied) -> no longer pending.
        clear_pending()

    elif event == "Notification":
        msg = payload.get("message", "needs your attention")
        state["status"] = "waiting"
        state["last_event"] = _truncate(msg, 100)

    elif event in ("Stop", "SubagentStop"):
        state["status"] = "idle"
        state["last_event"] = "done – awaiting input"
        clear_pending()

    elif event == "SessionEnd":
        state["status"] = "idle"
        state["last_event"] = "session ended"
        state["ended"] = True

    else:
        # Unknown event: just refresh timestamp.
        state.setdefault("status", "idle")
        state.setdefault("last_event", event or "update")

    return state


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        payload = {}

    try:
        session_id = payload.get("session_id", "unknown")
        path = _state_path(session_id)
        prev = _load(path)
        state = compute_update(payload, prev)
        if state.get("ended"):
            # Remove ended sessions so they drop out of the menu immediately.
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            except Exception:
                _atomic_write(path, state)
        else:
            _atomic_write(path, state)
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
