#!/usr/bin/env python3
"""Unit tests for the status-bar hook logic. Run: python3 tests/test_hook.py"""

import os
import sys
import json
import tempfile
import subprocess

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "hook"))
import cc_statusbar_hook as h  # noqa: E402

FAILURES = []


def check(name, cond):
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}")
        FAILURES.append(name)


def ev(name, **kw):
    p = {"hook_event_name": name, "session_id": "s1", "cwd": "/Users/x/myproj", "_now": 1000.0}
    p.update(kw)
    return p


def test_transitions():
    print("transitions:")
    st = h.compute_update(ev("SessionStart"), {})
    check("SessionStart -> idle", st["status"] == "idle")
    check("folder parsed", st["folder"] == "myproj")

    st = h.compute_update(ev("UserPromptSubmit", prompt="Fix the login bug please"), st)
    check("UserPromptSubmit -> running", st["status"] == "running")
    check("title captured from prompt", st["title"] == "Fix the login bug please")

    st = h.compute_update(ev("PreToolUse", tool_name="Bash"), st)
    check("PreToolUse -> running", st["status"] == "running")
    check("last_event mentions tool", "Bash" in st["last_event"])

    st = h.compute_update(ev("PostToolUse", tool_name="Bash", tool_response={"is_error": True, "error": "boom"}), st)
    check("PostToolUse error -> error", st["status"] == "error")
    check("error recorded", st["last_error"] == "boom")
    check("error_at set", st["error_at"] == 1000.0)

    st = h.compute_update(ev("PostToolUse", tool_name="Read", tool_response={"is_error": False}), st)
    check("PostToolUse ok -> running", st["status"] == "running")
    check("sticky error text retained for dropdown", st["last_error"] == "boom")

    st = h.compute_update(ev("Notification", message="Claude needs permission to run rm"), st)
    check("Notification -> waiting", st["status"] == "waiting")
    check("notification message shown", "permission" in st["last_event"])

    st = h.compute_update(ev("Stop"), st)
    check("Stop -> idle", st["status"] == "idle")

    st2 = h.compute_update(ev("UserPromptSubmit", prompt="next task"), st)
    check("new turn clears error", st2["last_error"] is None)


def test_pending_capture():
    print("pending approval capture:")
    st = h.compute_update(ev("SessionStart"), {})
    check("no pending initially", st["pending_tool"] is None)

    st = h.compute_update(ev("PreToolUse", tool_name="Bash",
                              tool_input={"command": "npm run build -- --dry-run"}), st)
    check("PreToolUse sets pending tool", st["pending_tool"] == "Bash")
    check("PreToolUse summarizes command", st["pending_input"] == "npm run build -- --dry-run")

    # While Claude waits for approval, the pending action persists.
    st = h.compute_update(ev("Notification", message="needs permission"), st)
    check("pending survives Notification", st["pending_input"].startswith("npm run"))

    # WebFetch summarizes the URL instead of a command.
    st2 = h.compute_update(ev("PreToolUse", tool_name="WebFetch",
                              tool_input={"url": "api.example.com/v1/status"}), st)
    check("WebFetch summarizes url", st2["pending_input"] == "api.example.com/v1/status")

    # Running the tool clears the pending action.
    st2 = h.compute_update(ev("PostToolUse", tool_name="WebFetch", tool_response={"is_error": False}), st2)
    check("PostToolUse clears pending", st2["pending_tool"] is None and st2["pending_input"] is None)


def test_error_shapes():
    print("error detection shapes:")
    check("is_error true", h._detect_tool_error({"tool_response": {"is_error": True}}) is not None)
    check("status failed", h._detect_tool_error({"tool_response": {"status": "failed"}}) is not None)
    check("error key", h._detect_tool_error({"tool_response": {"error": "nope"}}) == "nope")
    check("clean response", h._detect_tool_error({"tool_response": {"is_error": False}}) is None)
    check("string response", h._detect_tool_error({"tool_response": "all good"}) is None)
    check("missing response", h._detect_tool_error({}) is None)


def test_truncate():
    print("truncation:")
    check("short kept", h._truncate("hi", 10) == "hi")
    check("long cut", len(h._truncate("x" * 200, 50)) == 50)
    check("whitespace collapsed", h._truncate("a\n  b\t c") == "a b c")


def test_end_to_end_subprocess():
    """Run the actual hook script as Claude Code would, via stdin, and verify
    it writes a state file and emits nothing to stdout."""
    print("end-to-end (subprocess):")
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, HOME=tmp)
        hook_path = os.path.join(os.path.dirname(__file__), "..", "hook", "cc_statusbar_hook.py")
        payload = json.dumps({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "abc-123",
            "cwd": "/Users/x/demo",
            "prompt": "hello world",
        })
        r = subprocess.run([sys.executable, hook_path], input=payload, env=env,
                           capture_output=True, text=True, timeout=10)
        check("exit 0", r.returncode == 0)
        check("no stdout (would pollute context)", r.stdout == "")
        state_file = os.path.join(tmp, ".claude", "statusbar", "sessions", "abc-123.json")
        check("state file written", os.path.exists(state_file))
        if os.path.exists(state_file):
            with open(state_file) as f:
                data = json.load(f)
            check("status running", data["status"] == "running")
            check("title from prompt", data["title"] == "hello world")

        # SessionEnd should delete the file.
        end_payload = json.dumps({
            "hook_event_name": "SessionEnd",
            "session_id": "abc-123",
            "cwd": "/Users/x/demo",
        })
        subprocess.run([sys.executable, hook_path], input=end_payload, env=env,
                       capture_output=True, text=True, timeout=10)
        check("SessionEnd removes state file", not os.path.exists(state_file))


def test_garbage_input():
    """Malformed stdin must never crash the hook (would break Claude Code)."""
    print("robustness:")
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, HOME=tmp)
        hook_path = os.path.join(os.path.dirname(__file__), "..", "hook", "cc_statusbar_hook.py")
        for bad in ["", "not json", "{partial", "null", "[]"]:
            r = subprocess.run([sys.executable, hook_path], input=bad, env=env,
                               capture_output=True, text=True, timeout=10)
            check(f"garbage {bad!r} -> exit 0", r.returncode == 0)


if __name__ == "__main__":
    test_transitions()
    test_pending_capture()
    test_error_shapes()
    test_truncate()
    test_end_to_end_subprocess()
    test_garbage_input()
    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} checks")
        sys.exit(1)
    print("ALL PASSED")
