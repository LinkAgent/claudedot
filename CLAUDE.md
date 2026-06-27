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

The list mirrors what Claude itself shows: from the **last 24h**, the sessions that are *running*, *need your input*, or *errored*. `mergeSessions` drops anything whose decayed (`effectiveStatus`) status is idle, so finished work that doesn't await you, stale-running sessions, and history all disappear.

The five `Status` cases:
- **running** — agent actively working. Native `busy`; a Desktop session whose transcript tail ends on an *executing tool* / a user turn (within `toolLivenessWindow = 15min` — long, because a subagent / long Bash appends nothing to the transcript until it returns, so a 90s window would hide a genuinely-busy session mid-tool-call); or a Desktop session with a **fresh hook** reporting running (Stop hasn't fired) — the latter catches an agent that momentarily wrote text mid-turn. See `classifyTail` / `TranscriptTail` and `inferDesktopStatus`.
- **waiting** — agent is **blocked on you** for an explicit choice/approval: native `waiting`, a hook `waiting` (AskUserQuestion / ExitPlanMode / `permission_prompt` Notification), or a transcript tail ending on a user-blocking tool. Urgent — outranks running, shows the approval panel.
- **done** — "**Needs input**": the agent finished its turn **ending on a question** (the transcript's last line carries `?`/`？` → `TranscriptTail.finishedAsking`), and only for a session you've **engaged with recently** (`lastFocusedAt` within `desktopNeedsInputWindow`, 24h) — so a conversation a background loop appended a question to, that you abandoned days ago, is *not* surfaced. Lights the owl the **same yellow** as `waiting` and counts toward the badge, but sorts **below** running and shows no panel. A plain *completed* turn (no question) is hidden.
- **error** — a tool failed (hook overlay, recent only).
- **idle** — nothing to show; **hidden** from the list.

What "needs input" is, precisely: an **explicit choice/approval** (AskUserQuestion / ExitPlanMode / permission) → `waiting`, **or** a turn whose **last line is a question** → `done` — never a turn that merely completed work.

Aggregate icon picks the max: `error (4) > waiting (3) > running (2) > done (1) > idle (0)`. A "running" session older than 90s decays to idle in the aggregate (unless `trustedActive`). The **menu-bar badge number** (`badgeCount`) matches the glyph's state — error count when red, needs-input count (`waiting + done`) when yellow, running count when green — so digit and colour always agree.

**Desktop status is transcript-grounded, not hook-trusted.** A Desktop native entry can have a hook stuck at "running" long after the agent stopped. So `mergeSessions` drives Desktop status from the `loadDesktop` transcript scan (mtime + tail + `lastFocusedAt`); the hook only **upgrades** a finished tail to running when it's *fresh* (within 90s), and overlays error + pending-approval details. `loadDesktop` excludes **scheduled-task** (cron bot) sessions and bounds the set via the pure `filterWelcomeSessions` (drop `isScheduled`, keep `waiting` regardless of age, else within 24h).

The **menu-bar glyph** is a vector owl (`owlImage(for:diameter:)`), `NSBezierPath` → `NSImage`, color = aggregate state via `statusColor(_:)` (running green / waiting + done yellow / error red / idle gray). `Status.emoji` in `Model.swift` is a fallback for headless contexts only.

The **popover status dots** (`DotView`) share `statusColor(_:)` with the owl glyph so the popover dot and the menu-bar icon read as the same state at a glance. Running and waiting dots get a faint static base ring plus an animated pulse ring (`viewDidMoveToWindow`).

**Notification = the precise "needs you" signal**, subdivided by matcher (`install_hooks.py` registers `permission_prompt` and `idle_prompt`, passing `--notify-kind`; the payload itself has no type field — claude-code#11964). The hook records `notify_kind`: `permission_prompt` → urgent `waiting`; `idle_prompt` → calm (does not escalate).

### Previewing the UI (no Screen Recording permission)

`screencapture` of the live menu bar/popover fails without TCC Screen Recording access. Instead use the built-in snapshot modes (all render offscreen via `NSView.cacheDisplay`, no Screen Recording needed):

- `…/claudedot --snapshot out.png` — popover (light + dark, demo data via `demoData()`)
- `…/claudedot --snapshot-island out.png` — dynamic island, folded + expanded × 0/2/5 sessions, on a simulated screen with a synthetic notch (so the wrap-the-notch positioning can be inspected). Uses `IslandLayout` for sizes — same code path as the live `DynamicIslandController`, so what's in the PNG matches what ships.
- `…/claudedot --owls out.png` — the four owl glyph states as a strip.

For runtime diagnostics on a real screen (without screen capture), set `CLAUDEDOT_DEBUG_ISLAND=1` before launch — `DynamicIslandController` writes its resolved screen frame, safe-area insets, and computed panel rect to stderr on every `applyFrame`.

## Jump-to-session

Clicking a session row (or an approval panel's "Jump to respond") calls `jump(pid:cwd:)` — three tiers, falling through on failure:
1. `focusTerminalForPid` — `ttyForPid` (`ps -o tty=`) + AppleScript against Terminal.app / iTerm2 to select the exact tab whose `tty` matches.
2. `hostAppForPid` — walks the process tree (`parentPid` via `ps -o ppid=`) up to the first `.regular` `NSRunningApplication` (the owning GUI app: VS Code, JetBrains, other terminals) and `activate`s it. No special permission needed (unlike AppleScript).
3. `openTerminalAt` — opens the session's folder in a new Terminal window.

`Session.pid` is threaded from the native registry through `mergeSessions`. The app **cannot answer a permission prompt remotely** (it's typed in the terminal), so the approval panel's actions jump to the session rather than resolving it.
