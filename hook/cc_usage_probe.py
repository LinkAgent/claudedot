#!/usr/bin/env python3
"""Scrape Claude Code's /status Usage tab for subscription-limit data.

`/status` computes session/week usage % + reset times LOCALLY ("based on local
sessions on this machine") — no API call, no quota burn — but it's only shown in
the interactive TUI. There is no CLI/JSON command for it, so we drive the TUI in
a pseudo-terminal, switch to the Usage tab, scrape the rendered text, and write
the parsed values to ~/.claude/statusbar/usage.json for the menu-bar app.

Runs in a dedicated, auto-trusted scratch dir so its throwaway session is easy
for the app to filter out (it never persists; the app drops sessions whose cwd
is this probe dir). Best-effort: any failure just leaves the previous JSON.

Usage: cc_usage_probe.py [output.json]   (CLAUDE_BIN env overrides the binary)
"""
import pty, os, time, select, re, struct, fcntl, termios, signal, json, sys, shutil

PROBE_DIR = os.path.expanduser("~/.claude/statusbar/probe")
DEFAULT_OUT = os.path.expanduser("~/.claude/statusbar/usage.json")


def find_claude():
    if os.environ.get("CLAUDE_BIN"):
        return os.environ["CLAUDE_BIN"]
    found = shutil.which("claude")
    if found:
        return found
    for p in ("~/.nvm/versions/node/*/bin/claude", "/opt/homebrew/bin/claude",
              "/usr/local/bin/claude", "~/.local/bin/claude", "~/.claude/local/claude"):
        import glob
        hits = glob.glob(os.path.expanduser(p))
        if hits:
            return hits[0]
    return "claude"


def capture():
    os.makedirs(PROBE_DIR, exist_ok=True)
    claude = find_claude()
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.chdir(PROBE_DIR)
        os.execvp(claude, ["claude"])
        os._exit(1)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 55, 120, 0, 0))
    buf = bytearray()

    def drain(t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.3)
            if r:
                try:
                    d = os.read(fd, 65536)
                except OSError:
                    return False
                if not d:
                    return False
                buf.extend(d)
        return True

    drain(7)
    os.write(fd, b"\r")          # accept the trust prompt (default = "Yes") if shown
    drain(3)
    os.write(fd, b"/status\r")   # open the status dialog (defaults to Status tab)
    drain(4)
    os.write(fd, b"\x1b[C"); drain(1)   # Status -> Config
    os.write(fd, b"\x1b[C"); drain(6)   # Config -> Usage (let "Refreshing…" settle)
    for b in (b"\x1b", b"\x03", b"\x03"):
        try:
            os.write(fd, b); time.sleep(0.2)
        except OSError:
            pass
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    _cleanup_sessions(pid)
    return buf


def _cleanup_sessions(pid):
    """Remove the session file our SIGKILL'd claude left behind (named <pid>.json),
    plus any older leftovers whose cwd is our scratch dir. Also sweeps the
    statusbar hook-state dir for files our own hook wrote on the probe's behalf
    (cwd==PROBE_DIR) — otherwise they pile up forever, one per probe run."""
    import json as _json
    sdir = os.path.expanduser("~/.claude/sessions")
    for name in ([f"{pid}.json"] + (os.listdir(sdir) if os.path.isdir(sdir) else [])):
        p = os.path.join(sdir, name)
        try:
            if name == f"{pid}.json":
                os.remove(p); continue
            if name.endswith(".json") and _json.load(open(p)).get("cwd") == PROBE_DIR:
                os.remove(p)
        except OSError:
            pass
    hdir = os.path.expanduser("~/.claude/statusbar/sessions")
    if os.path.isdir(hdir):
        for name in os.listdir(hdir):
            if not name.endswith(".json"):
                continue
            p = os.path.join(hdir, name)
            try:
                if _json.load(open(p)).get("cwd") == PROBE_DIR:
                    os.remove(p)
            except (OSError, ValueError):
                pass


def parse(raw):
    clean = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw)
    clean = re.sub(r"\x1b\][^\x07]*\x07", "", clean)
    clean = re.sub(r"\x1b[=>]", "", clean)
    clean = re.sub(r"[█▌▐▒▓░▏▎▍▋▊▉]", " ", clean)
    clean = " ".join(clean.replace("\r", " ").split())

    def pct(after):
        m = re.search(after + r".*?(\d+)\s*%\s*used", clean)
        return int(m.group(1)) if m else None

    def reset(after):
        m = re.search(after + r".*?Resets\s+([^()]+?)\s*\(([^)]+)\)", clean)
        return (m.group(1).strip(), m.group(2).strip()) if m else (None, None)

    out = {"fetched_at": time.time()}
    out["session_pct"] = pct(r"Current session")
    out["week_pct"] = pct(r"Current week \(all models\)")
    out["sonnet_pct"] = pct(r"Current week \(Sonnet only\)")
    out["session_reset"], out["session_tz"] = reset(r"Current session")
    out["week_reset"], out["week_tz"] = reset(r"Current week \(all models\)")
    m = re.search(r"Total cost:\s*\$?([\d.]+)", clean)
    out["total_cost"] = float(m.group(1)) if m else None
    m = re.search(r"(\d+)\s*%\s*of your usage was at\s*>?\s*150k context", clean)
    out["high_context_pct"] = int(m.group(1)) if m else None
    return out


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT
    try:
        data = parse(capture().decode("utf-8", "replace"))
    except Exception:
        return  # leave the previous file intact on any failure
    # Only write if we actually scraped at least one figure.
    if data.get("session_pct") is None and data.get("week_pct") is None and data.get("total_cost") is None:
        return
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, out_path)
    print(json.dumps(data))


if __name__ == "__main__":
    main()
