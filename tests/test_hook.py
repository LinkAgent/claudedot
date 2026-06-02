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


# --- Functional / edge-case coverage added below ---

def test_truncate_edges():
    """Boundary behavior of _truncate."""
    print("truncate edges:")
    check("exactly n kept", h._truncate("abcde", 5) == "abcde")
    check("n+1 truncated to n", len(h._truncate("abcdef", 5)) == 5)
    check("n+1 ends with ellipsis", h._truncate("abcdef", 5).endswith("…"))
    check("empty stays empty", h._truncate("", 5) == "")
    # n=0 is a degenerate input; the function should at minimum not exceed n.
    # NOTE: currently produces 'x…' for any non-empty text — guarded contract bug.
    check("n=0 produces length<=0", len(h._truncate("hi", 0)) <= 0)


def test_pending_summary_edges():
    """_pending_summary edge cases."""
    print("pending summary:")
    check("none if no tool_input", h._pending_summary({}) is None)
    check("none if tool_input not dict", h._pending_summary({"tool_input": "raw"}) is None)
    check("none if tool_input empty", h._pending_summary({"tool_input": {}}) is None)
    check("empty command skipped", h._pending_summary({"tool_input": {"command": ""}}) is None)
    # Priority: command beats url when both present (lowercase key match list)
    summary = h._pending_summary({"tool_input": {"command": "echo hi", "url": "http://x"}})
    check("command preferred over url", summary == "echo hi")
    # file_path used when no command/url
    check("file_path used", h._pending_summary({"tool_input": {"file_path": "/etc/hosts"}}) == "/etc/hosts")


def test_error_detection_edges():
    """Less common shapes of tool_response."""
    print("error detection edges:")
    # is_error true without a message yields a generic placeholder
    err = h._detect_tool_error({"tool_response": {"is_error": True}})
    check("is_error true -> generic msg", err == "tool error")
    # isError (camelCase) variant
    check("isError camelCase recognised",
          h._detect_tool_error({"tool_response": {"isError": True, "content": "boom"}}) == "boom")
    # List-shaped tool_response is currently NOT inspected -> returns None.
    # Documenting expected behaviour: any list shape should still produce no false positives.
    check("list response no crash",
          h._detect_tool_error({"tool_response": [{"is_error": True}]}) is None)


def test_state_path_sanitization():
    """_state_path strips path-traversal characters from session_id."""
    print("state path:")
    p = h._state_path("../../etc/passwd")
    check("no parent dirs", "/.." not in p and "etc/passwd" not in p)
    check("empty id falls back", h._state_path("").endswith("unknown.json"))
    check("safe id preserved", h._state_path("abc-123_x").endswith("abc-123_x.json"))


def test_compute_update_edges():
    """Edge transitions that must keep state consistent."""
    print("compute_update edges:")

    # SessionStart with no cwd in payload: should fall back to prev.
    prev = {"cwd": "/prev/dir", "title": "old"}
    st = h.compute_update({"hook_event_name": "SessionStart", "session_id": "s",
                           "_now": 100.0}, prev)
    check("SessionStart falls back to prev cwd", st["cwd"] == "/prev/dir")

    # PreToolUse with no tool_input must not crash and must store None summary
    st = h.compute_update(ev("PreToolUse", tool_name="Bash"), {})
    check("PreToolUse no tool_input -> pending tool set", st["pending_tool"] == "Bash")
    check("PreToolUse no tool_input -> pending_input None", st["pending_input"] is None)

    # Sticky error: a successful PostToolUse keeps last_error visible but resets status
    st0 = h.compute_update(ev("PostToolUse", tool_name="Bash",
                              tool_response={"is_error": True, "error": "boom"}), {})
    st1 = h.compute_update(ev("PostToolUse", tool_name="Read",
                              tool_response={"is_error": False}, _now=2000.0), st0)
    check("recovery preserves last_error text", st1["last_error"] == "boom")
    check("recovery preserves error_at timestamp", st1["error_at"] == 1000.0)

    # UserPromptSubmit with empty/whitespace prompt does NOT clobber prior title.
    prev = {"title": "Existing title", "folder": "myproj"}
    st = h.compute_update(ev("UserPromptSubmit", prompt="   "), prev)
    check("blank prompt preserves title", st["title"] == "Existing title")

    # SessionEnd marks ended=True so main() can unlink the file.
    st = h.compute_update(ev("SessionEnd"), {})
    check("SessionEnd marks ended", st["ended"] is True)

    # Unknown event leaves prior status untouched.
    prev = {"status": "running", "last_event": "x"}
    st = h.compute_update(ev("MysteryEvent"), prev)
    check("unknown event preserves status", st["status"] == "running")


def test_install_hooks_idempotency():
    """install_hooks.py must be idempotent and uninstall must be a clean no-op
    when there are no hooks to remove."""
    print("install_hooks:")
    install_path = os.path.join(os.path.dirname(__file__), "..", "install_hooks.py")
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, HOME=tmp)
        # Install twice -> still exactly one entry per event group.
        for _ in range(2):
            r = subprocess.run([sys.executable, install_path, "/tmp/hook.py"],
                               env=env, capture_output=True, text=True, timeout=10)
            check("install exit 0", r.returncode == 0)
        with open(os.path.join(tmp, ".claude", "settings.json")) as f:
            data = json.load(f)
        groups = data["hooks"]["PreToolUse"]
        tagged = [g for g in groups if any(hh.get("_tag") == "cc-statusbar" for hh in g.get("hooks", []))]
        check("install idempotent: exactly one tagged group", len(tagged) == 1)
        all_tagged_hooks = [hh for g in groups for hh in g.get("hooks", []) if hh.get("_tag") == "cc-statusbar"]
        check("install idempotent: exactly one tagged entry", len(all_tagged_hooks) == 1)

        # Uninstall: removes our entries, leaves the file.
        subprocess.run([sys.executable, install_path, "--uninstall"], env=env,
                       capture_output=True, text=True, timeout=10)

    # Uninstall on a fresh HOME where ~/.claude does not exist must be a no-op.
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, HOME=tmp)
        r = subprocess.run([sys.executable, install_path, "--uninstall"], env=env,
                           capture_output=True, text=True, timeout=10)
        check("uninstall exit 0 on empty HOME", r.returncode == 0)
        # BUG: uninstall currently creates settings.json containing "{}"
        # See: https://github.com/LinkAgent/claudedot/issues  (filed bug A)
        settings = os.path.join(tmp, ".claude", "settings.json")
        check("uninstall does not create settings.json from nothing",
              not os.path.exists(settings))


def test_install_hooks_preserves_user_hooks():
    """User-configured hooks must survive both install and uninstall."""
    print("install_hooks user hooks:")
    install_path = os.path.join(os.path.dirname(__file__), "..", "install_hooks.py")
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, ".claude"))
        user_settings = {
            "hooks": {
                "PreToolUse": [
                    {"matcher": "Bash", "hooks": [{"type": "command", "command": "/u/h.sh"}]}
                ]
            }
        }
        with open(os.path.join(tmp, ".claude", "settings.json"), "w") as f:
            json.dump(user_settings, f)
        env = dict(os.environ, HOME=tmp)
        subprocess.run([sys.executable, install_path, "/tmp/cc.py"], env=env,
                       capture_output=True, text=True, timeout=10)
        subprocess.run([sys.executable, install_path, "--uninstall"], env=env,
                       capture_output=True, text=True, timeout=10)
        with open(os.path.join(tmp, ".claude", "settings.json")) as f:
            data = json.load(f)
        check("user PreToolUse hook preserved",
              data["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "/u/h.sh")
        check("our hooks removed from user file",
              not any(hh.get("_tag") == "cc-statusbar"
                      for g in data["hooks"]["PreToolUse"]
                      for hh in g.get("hooks", [])))


if __name__ == "__main__":
    test_transitions()
    test_pending_capture()
    test_error_shapes()
    test_truncate()
    test_end_to_end_subprocess()
    test_garbage_input()
    test_truncate_edges()
    test_pending_summary_edges()
    test_error_detection_edges()
    test_state_path_sanitization()
    test_compute_update_edges()
    test_install_hooks_idempotency()
    test_install_hooks_preserves_user_hooks()
    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} checks")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    print("ALL PASSED")
