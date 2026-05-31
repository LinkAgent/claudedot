# DESIGN.md — Claude Dot

> Design language summary for the **Claude Dot** macOS menu-bar app, written in
> the spirit of Anthropic's Claude desktop/web aesthetic.
>
> **Note:** Anthropic does not publish an official Claude Desktop `DESIGN.md`.
> This file distills the *publicly observable* Claude visual language (warm
> cream surfaces, editorial serif, terracotta accent, flat minimal chrome) into
> the standard 9-section `DESIGN.md` format. It is the source-of-truth for this
> project, not an official Anthropic document.

---

## 1. Visual Theme & Atmosphere

Warm, editorial, calm. The interface should feel like a well-set page of print,
not a neon dashboard. Restraint is the whole point: one accent color, generous
hairlines instead of boxes, serif type carrying the personality. Density is
*comfortable* — tight enough for a menu-bar popover, never cramped.

- **Mood:** quiet, literate, premium-but-unfussy
- **Density:** compact-comfortable (336px-wide popover)
- **Texture:** flat surfaces, no glassmorphism, no gradients on content; only a
  faint radial wash on the page backdrop for depth
- **Personality source:** typography + a single terracotta accent, not effects

---

## 2. Color Palette & Roles

Two themes share identical token *names*; only the values flip. Switch by setting
`[data-theme]` on the root — no other CSS changes.

### Light (cream — default)
| Token | Hex | Role |
| --- | --- | --- |
| `--surface` | `#F7F4EC` | popover background |
| `--raise` | `#FBFAF5` | hover / input fill |
| `--canvas-a` / `--canvas-b` | `#E4DECF` / `#D2CCBD` | page backdrop wash |
| `--border` | `#E3DCCB` | primary hairline / divider |
| `--border-soft` | `#EBE5D7` | secondary hairline |
| `--ink` | `#2B2A27` | primary text |
| `--ink-2` | `#6B6760` | secondary text |
| `--ink-3` | `#9A968C` | tertiary / metadata |
| `--accent` | `#E96945` | terracotta — the only accent |
| `--accent-2` | `#D99A82` | accent, dimmed (fractional states) |
| `--green` | `#6B8E5E` | success / done |

### Dark (warm charcoal)
| Token | Hex | Role |
| --- | --- | --- |
| `--surface` | `#1F1F1E` | popover background |
| `--raise` | `#2E2C26` | hover / input fill |
| `--canvas-a` / `--canvas-b` | `#1F1E1B` / `#141310` | page backdrop wash |
| `--border` | `#3A382F` | primary hairline / divider |
| `--border-soft` | `#322F29` | secondary hairline |
| `--ink` | `#ECE8DD` | primary text |
| `--ink-2` | `#A8A399` | secondary text |
| `--ink-3` | `#6F6B61` | tertiary / metadata |
| `--accent` | `#E96945` | terracotta (brightened for dark) |
| `--accent-2` | `#9C5238` | accent, dimmed |
| `--green` | `#7A9B76` | success / done |

**Rule:** accent appears *only* on: brand mark, the "Dot" word, waiting-state
indicators, the filled portion of the usage bar, and icon hover. Never as a
fill behind large blocks of content.

---

## 3. Typography Rules

Three families, each with one job. The serif carries the brand; mono carries the
data; system sans handles small functional labels.

| Family | Use | Notes |
| --- | --- | --- |
| **Newsreader** (serif) | Wordmark, big numerals, session names, body | Display + editorial voice. Weights 400/500/600. No italics. |
| **JetBrains Mono** | Counts, token figures, file paths, keycaps, % | Tabular, technical register |
| **-apple-system / SF** | Tiny caps labels, status lines, footer items | Functional UI chrome only |

- **Hero numeral** (usage %): Newsreader ~44px, weight 400, letter-spacing −1.5px
- **Section captions:** 9px, uppercase, letter-spacing 1.5px, `--ink-3`
- **No italics anywhere** — the brand reads upright.

---

## 4. Component Stylings

### Popover
336px wide, 16px radius, `--surface` fill, 0.5px `--border`, soft drop shadow.
Children stagger-in on open (`rise` keyframe, 0.04s increments).

### Usage meter
- Hero `%` numeral = the **current-session** limit used ("46% session used") +
  right-aligned reset time ("Resets 1:40am"). The **weekly** limit is
  intentionally not shown — the meter reflects the live/now window, not the week.
- **Segmented bar:** 20 segments, 2px gaps. Filled = `--accent`; the single
  fractional segment = `--accent-2`. Driven by the live session percentage so
  the bar always matches the number.
- Three mono micro-stats below: today's **tokens · messages · sessions**.
- **Data source:** the session %/reset come from Claude Code's `/status`, which
  computes them *locally* ("based on local sessions on this machine" — no API
  call, no quota burn). There is no CLI/JSON for it, so a pseudo-terminal probe
  (`cc_usage_probe.py`) drives the `/status` TUI, scrapes the Usage tab, and
  caches `usage.json` (~10 min). Token/message/session figures are summed from
  the local transcripts. Before the first probe lands, the hero falls back to
  today's token total. **Cost is not shown** — `/status`' "total cost" reflects
  the probe's own throwaway session (~$0), not real spend.

### Session row
- 7px status **dot** (left), info block (center), mono token count (right)
- Dot states: `wait` (accent + pulsing ring) · `run` (grey + pulsing ring) ·
  `done` (green, static). Reserve an `error` variant.
- Hover: row background → `--raise`

### Approval panel
- Rendered directly under a row **only** when that session is waiting
- Shows the pending tool + its command/URL in a mono `<code>` pill (captured by
  the hook on `PreToolUse`: `pending_tool` / `pending_input`)
- **Implemented behavior:** the menu-bar app can't answer a permission prompt
  remotely — the prompt is typed in the terminal — so the panel's action is a
  single hairline row, "→ Jump to terminal to respond", that focuses the exact
  tab/window running that session. Hover → accent text; no filled buttons.
- **Design target (not yet built):** if remote response ever becomes possible,
  expand to dynamic, tool-dependent options mirroring Claude Code's real prompt
  — Option 1 "Yes"; Option 2 "Yes, don't ask again…" with a `.tab` scope pill
  cycling local → project → user (Bash → command pattern, WebFetch → domain);
  Option 3 "No, tell Claude what to do" revealing a free-text reply. Hairline
  rows, hover nudges right 6px, no fills.

### Footer menu
Native-style menu items, icon + label + optional mono keycap hint. Icon turns
accent on hover.

---

## 5. Layout Principles

- **Single column**, vertically sectioned by hairline rules (`--border-soft`)
- Section padding: ~13–18px horizontal; rows ~9px vertical
- Hairline dividers are **inset** (`margin: 0 12-18px`), never full-bleed
- Whitespace rhythm favors breathing room around the hero, tighter in the list
- Right-aligned numerics throughout for scan-ability

---

## 6. Depth & Elevation

Minimal. Claude's surfaces are *flat* — depth comes from hairline borders and a
single soft shadow on the floating popover, not stacked shadows on content.

| Element | Elevation |
| --- | --- |
| Popover | `0 12px 40px rgba(80,70,55,0.18)` (light) / `0 20px 60px rgba(0,0,0,0.6)` (dark) |
| Rows, panels, inputs | flat — differentiated by `--raise` fill + 0.5px border only |
| Dividers | 0.5px hairline, never a drop shadow |

No inner shadows, no neumorphism, no bevels.

---

## 7. Do's and Don'ts

**Do**
- Let the serif + one accent do the work
- Keep accent scarce and meaningful (status, brand, the filled bar)
- Use hairlines and inset dividers to separate, not boxes or cards
- Right-align and monospace all figures
- Mirror Claude Code's real, tool-dependent approval options

**Don't**
- No glassmorphism, gradients-on-content, or heavy/stacked shadows
- No italics
- No second accent color; no large accent fills behind text
- No filled "button" treatment in the approval list — keep it text + hairline
- No generic system serif as the display face (use Newsreader, not Georgia-only)
- Don't hard-code the usage bar — generate segments from the live percentage

---

## 8. Responsive Behavior

This is a fixed-width macOS popover, so "responsive" means *content-adaptive*,
not breakpoint-driven.

- **Width:** fixed 336px; height grows with session count
- **Long values:** file paths and commands truncate with ellipsis / wrap in the
  `<code>` block (`word-break`), never overflow the popover
- **Empty states:** hide the menu-bar count badge when 0 active sessions; show a
  quiet "No active sessions" line in the list
- **Touch targets:** rows/options ≥ 32px tall for trackpad precision
- **Theme:** follow macOS system appearance (`prefers-color-scheme` /
  `NSApp.effectiveAppearance`); the in-UI toggle is preview-only

---

## 9. Agent Prompt Guide

Reusable prompts to stay on-system when extending this UI:

- *"Add a new session state. Reuse the `.dot` pattern: pick a token color
  (`--accent` / `--ink-3` / `--green` / a new `error` red), match the existing
  7px dot + optional pulsing ring. Status text uses `.st`, add `.attn` only if it
  needs the user."*
- *"Add a settings screen. Keep the cream/charcoal token set, Newsreader
  headings, hairline dividers, flat surfaces, terracotta accent only on active
  toggles. No cards, no shadows on content."*
- *"Build an approval panel for tool X. Options must mirror Claude Code's real
  prompt for that tool: dynamic count, tool-appropriate option-2 scope, option 3
  always 'No, tell Claude what to do' with a reply field. Hairline rows, no fills."*
- *"Make a compact variant. Reduce row padding ~25%, drop the usage micro-stats
  to one line, keep type scale and tokens unchanged."*

---

*Tokens, rules, and rationale kept in one file so an agent can stay on-system
even in cases this document doesn't explicitly cover.*
