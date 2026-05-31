# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app (`ClaudeStatusBar`, product name "Claude Dot") that shows the live status of every running Claude Code session. The menu-bar glyph is a vector owl whose color = aggregate state; clicking it opens a popover (usage meter + sessions + approval panels + footer) styled after `design/claudedot.html`.

## Commands

```bash
./run_tests.sh   # Python hook tests + Swift model tests (run this to validate any change)
./build.sh       # build build/ClaudeStatusBar.app only (swiftc, no Xcode/SPM)
./install.sh     # build + install app to ~/Applications, hook to ~/.claude/statusbar, merge settings.json, register LaunchAgent
./uninstall.sh   # remove app, LaunchAgent, and only the hooks this tool added
```

Both suites use a tiny custom runner (not pytest/XCTest) that runs every test and exits non-zero on any failure — there is no single-test filter. `python3 tests/test_hook.py` runs the Python suite directly. The Swift suite is staged by `run_tests.sh`, which copies `app/tests/model_test.swift` to `main.swift` (top-level code requires that filename) and compiles it against `Model.swift`.

## Architecture

The core idea is **two data sources merged**, with native discovery as the source of truth and hooks as an enrichment layer:

1. **Native registry** (`~/.claude/sessions/<pid>.json`) — written by Claude Code itself, one file per running session. Authoritative for *which* sessions exist and their `busy`/`waiting` state. Liveness = the pid is alive (`kill(pid, 0)`), so dead sessions vanish with no staleness timer. Every running session appears here, even ones started before this tool was installed.

2. **Hook state** (`~/.claude/statusbar/sessions/<session_id>.json`) — written by `hook/cc_statusbar_hook.py`, wired into 8 lifecycle events. Adds what the native registry lacks: **error detection** (failed tool calls), **prompt-text titles**, and **pending-approval capture** (`pending_tool` / `pending_input`, the tool + command/URL awaiting approval, set on PreToolUse and cleared on PostToolUse/Stop/UserPromptSubmit).

The app polls both dirs every 1.5s and calls `mergeSessions` (in `Model.swift`): native drives base status; a hook `error` overlays only while recent (`runningLivenessWindow = 90s`), after which native recovery wins. Hook-only sessions (headless `claude -p` that never hit the native registry) show while recent and non-idle.

### Popover & extra data sources

Two more local sources back the popover (read-only, lazily on open):
- **`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`** — per-session transcript. `tokensFor(id)` reads it **incrementally** (caches a byte offset + running total per session; transcripts only append) and sums `sessionTokenTotal` for the row's cumulative token count. `findTranscript` locates the file by scanning project subdirs for `<sessionId>.jsonl` (avoids guessing the cwd→dirname encoding).
- **Today's usage** (`loadTodayUsage`) is derived **straight from the transcripts**, NOT from `~/.claude/stats-cache.json` — that cache can lag by weeks (and its `costUSD` is often 0), so it's unusable for "today". The app scans project `.jsonl` files modified in the last ~8 days, sums `usage` per UTC date (today + weekly peak for the bar), and caches per-file by mtime. Yields today's tokens, messages, sessions, top model, and `liveTokens` (sum of non-idle sessions).

- **Subscription limits** — the popover's hero is the **current-session** limit % + reset (the weekly figure is scraped too but intentionally not displayed). These come from Claude Code's `/status`, which computes them **locally** (no API call, no quota burn) but only renders in the interactive TUI — there is no CLI/JSON for it. `hook/cc_usage_probe.py` drives `/status` in a **pseudo-terminal** (Python `pty`): it runs `claude` in a dedicated scratch dir (`~/.claude/statusbar/probe`, auto-accepting the trust prompt with Enter), sends `/status`, arrows over to the **Usage** tab, scrapes the rendered text, and writes `~/.claude/statusbar/usage.json`. The app's `maybeProbe()` spawns it (via `/bin/zsh -lc` so `claude` is on PATH) at launch and every ~10 min; `loadTodayUsage` overlays the JSON. The probe's own throwaway `claude` session is filtered from the list by its cwd (`== probeDir`). When `usage.json` is absent the popover falls back to the today-tokens hero. NOTE: this is ANSI-scraping a TUI — fragile to Claude Code version changes; if the meter goes blank, re-check the `/status` tab order and labels in the probe.

The popover is an `NSPopover` rebuilt by `buildPopover(sessions:stats:theme:handlers:)` (a free function so it's reusable by snapshot mode). While open, `refresh()` rebuilds it only when a content `signature` changes. The visual system follows **`design/DESIGN.md`** (the project source-of-truth; `design/claudedot.html` is the matching HTML mock): warm cream / charcoal surfaces, a single terracotta `accent` (+ dimmed `accent2`), `green` for done; **serif** display/body (Newsreader → New York via `display()`), monospaced figures (JetBrains Mono → SF Mono via `mono()`), SF for tiny caps (`capLabel`); 16px popover / ~10px rows (`R`). `Theme.light`/`.dark` chosen from `effectiveAppearance`.

### Key files

| File | Role |
|------|------|
| `app/Sources/Model.swift` | Pure, AppKit-free model + merge/aggregation logic. **Compiled by both the app and the test harness — keep it dependency-free and testable.** |
| `app/Sources/main.swift` | AppKit: owl glyph, themed popover (`buildPopover`), data loading, jump-to-session, `--snapshot` mode. `LSUIElement`, single-instance. |
| `design/claudedot.html` | The popover's reference design — layout, palette, sections. Keep the native UI in sync with it. |
| `hook/cc_statusbar_hook.py` | Hook dispatcher: stdin payload → per-session state file. The pure logic is in `compute_update(payload, prev)`, isolated from I/O for testing. |
| `install_hooks.py` | Idempotent merge/removal of hooks in `~/.claude/settings.json`. |

## Critical invariants

- **The hook must never break Claude.** Any error → exit 0, and it prints **nothing to stdout** (some hook stdout, e.g. `UserPromptSubmit`, is injected into Claude's context). Preserve this in `cc_statusbar_hook.py`.
- **Keep logic in the pure layers.** Status mapping, merging, and aggregation live in `Model.swift` (Swift) and `compute_update` (Python) precisely so they can be unit-tested without AppKit or filesystem I/O. Add new behavior there, not in `main.swift`'s UI or the hook's `main()`.
- **Hook installation is tagged and idempotent.** `install_hooks.py` marks every entry it adds with `"_tag": "cc-statusbar"` so uninstall removes only its own hooks and leaves user-configured ones intact. Re-running install strips stale copies first. A `.statusbar-bak` backup of `settings.json` is written before modification.
- **State-file schema is shared across language boundaries.** The JSON keys written by the hook (`session_id`, `status`, `title`, `last_event`, `last_error`, `error_at`, `updated_at`, `ended`, …) are read by `Session.init?(json:)` in `Model.swift`. Changing keys requires updating both sides plus the tests.

## Status priority & colors

Aggregate icon picks the max: `error (3) > waiting (2) > running (1) > idle (0)`. Native `busy` → running, `waiting` → needs-input, else idle. A "running" session older than 90s decays to idle in the aggregate.

The **menu-bar glyph** is a vector owl (`owlImage(for:diameter:)`), `NSBezierPath` → `NSImage`, color = aggregate state via `statusColor(_:)` (running green / waiting yellow / error red / idle gray). `Status.emoji` in `Model.swift` is a fallback for headless contexts only.

The **popover status dots** (`DotView`) follow `design/DESIGN.md` §4 via `Theme.popoverDotColor`: running = grey + animated pulse ring, waiting = terracotta accent + pulse ring, error = red, idle = green ("done"). These intentionally differ from the owl glyph's traffic-light colors (`statusColor`: running green / waiting amber / error red / idle grey) — the owl is the at-a-glance menu-bar summary; the dots match the popover's design language.

### Previewing the UI (no Screen Recording permission)

`screencapture` of the live menu bar/popover fails without TCC Screen Recording access. Instead use the built-in snapshot mode: `…/ClaudeStatusBar --snapshot out.png` renders the popover (light + dark, demo data via `demoData()`) offscreen through an `NSWindow` + `cacheDisplay` and writes a PNG. The owl glyph can be previewed the same way (render `owlImage(for:)` into a PNG).

## Jump-to-session

Clicking a session row (or an approval panel's "Jump to respond") calls `jump(pid:cwd:)` — three tiers, falling through on failure:
1. `focusTerminalForPid` — `ttyForPid` (`ps -o tty=`) + AppleScript against Terminal.app / iTerm2 to select the exact tab whose `tty` matches.
2. `hostAppForPid` — walks the process tree (`parentPid` via `ps -o ppid=`) up to the first `.regular` `NSRunningApplication` (the owning GUI app: VS Code, JetBrains, other terminals) and `activate`s it. No special permission needed (unlike AppleScript).
3. `openTerminalAt` — opens the session's folder in a new Terminal window.

`Session.pid` is threaded from the native registry through `mergeSessions`. The app **cannot answer a permission prompt remotely** (it's typed in the terminal), so the approval panel's actions jump to the session rather than resolving it.
