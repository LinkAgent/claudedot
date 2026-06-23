// Pure model + logic, free of AppKit, so it can be unit-tested headlessly.
// Both the app (main.swift) and the test harness compile this exact file.

import Foundation

enum Status: String {
    // running  = the agent is actively working.
    // waiting  = blocked on the user RIGHT NOW (approval / a question) — urgent.
    // done     = finished a turn, the result awaits your review (a Desktop session
    //            you haven't opened yet). Surfaced in the list as "needs review"
    //            but deliberately CALM: it does not light the menu-bar glyph the way
    //            an urgent `waiting` does (see Status.priority / aggregateStatus).
    // error    = a tool failed.
    // idle     = nothing to show; hidden from the list entirely.
    case running, waiting, done, error, idle

    // Fallback glyphs (the app draws flat colored dots; these keep the model
    // self-describing and are used by headless contexts/tests). Color scheme:
    // running = green, needs-input = yellow, done = green-check, error = red,
    // idle = neutral.
    var emoji: String {
        switch self {
        case .running: return "🟢"
        case .waiting: return "🟡"
        case .done:    return "✅"
        case .error:   return "🔴"
        case .idle:    return "⚪️"
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Needs input"
        case .done:    return "Needs input"
        case .error:   return "Error"
        case .idle:    return "Idle"
        }
    }

    // Priority for choosing the aggregate icon and sort order. Higher wins.
    // `done` ("Needs input" — the agent finished its turn and it's YOUR turn to
    // reply, exactly what Claude Desktop's welcome page labels "Needs input") sits
    // ABOVE idle so it lights the owl glyph + counts in the badge, but BELOW
    // running so an actively-working session still sorts to the top. Urgent
    // `waiting` (a pending approval / question) outranks it.
    var priority: Int {
        switch self {
        case .error:   return 4
        case .waiting: return 3
        case .running: return 2
        case .done:    return 1
        case .idle:    return 0
        }
    }
}

struct Session {
    var id: String
    var folder: String
    var cwd: String
    var status: Status
    var title: String
    var lastEvent: String
    var lastError: String?
    var errorAt: Double?
    var updatedAt: Double
    // Pid of the Claude Code process, when known (from the native registry).
    // Lets the app focus the exact terminal tab running this session.
    var pid: Int32?
    // When the session is awaiting approval, the tool + a short summary of its
    // input (e.g. the Bash command, the WebFetch URL) captured by the hook on
    // PreToolUse. Drives the approval panel's "pending action" line.
    var pendingTool: String?
    var pendingInput: String?
    // The Notification kind when the hook last fired one (issue #30):
    // "permission_prompt" (urgent approval) or "idle_prompt" (gentle "you've been
    // away"). Lets the UI phrase / sound the two differently. nil otherwise.
    var notifyKind: String?
    // True for Claude Desktop (Cowork / agent-mode) sessions. They can't be
    // focused via a terminal/tty or resolved remotely — jump just brings the
    // desktop app forward (see `jump` in main.swift).
    var isDesktop: Bool = false
    // "Trust the status without an age check." Set by mergeSessions when the
    // status comes from a still-live, authoritative source (native registry's
    // busy/waiting, or a hook on a Desktop session whose pid is alive). It
    // disables the runningLivenessWindow decay in aggregateStatus / activeCount
    // / islandFocusSession so a session that's actually busy (e.g. the model is
    // thinking and no events have fired for 2 minutes) doesn't flip to idle in
    // the glyph. updatedAt still reflects the last real event for display.
    var trustedActive: Bool = false

    init?(json: [String: Any]) {
        guard let id = json["session_id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.pid = (json["pid"] as? Int).map(Int32.init)
            ?? (json["pid"] as? Double).map { Int32($0) }
        self.folder = (json["folder"] as? String) ?? "session"
        self.cwd = (json["cwd"] as? String) ?? ""
        self.status = Status(rawValue: (json["status"] as? String) ?? "idle") ?? .idle
        self.title = (json["title"] as? String) ?? self.folder
        self.lastEvent = (json["last_event"] as? String) ?? ""
        self.lastError = json["last_error"] as? String
        self.errorAt = json["error_at"] as? Double
        self.updatedAt = (json["updated_at"] as? Double) ?? 0
        self.pendingTool = json["pending_tool"] as? String
        self.pendingInput = json["pending_input"] as? String
        self.notifyKind = json["notify_kind"] as? String
    }

    // Test-friendly memberwise initializer.
    init(id: String, folder: String = "f", cwd: String = "", status: Status,
         title: String = "", lastEvent: String = "", lastError: String? = nil,
         errorAt: Double? = nil, updatedAt: Double, pid: Int32? = nil,
         pendingTool: String? = nil, pendingInput: String? = nil,
         notifyKind: String? = nil,
         isDesktop: Bool = false, trustedActive: Bool = false) {
        self.id = id; self.folder = folder; self.cwd = cwd; self.status = status
        self.title = title; self.lastEvent = lastEvent; self.lastError = lastError
        self.errorAt = errorAt; self.updatedAt = updatedAt; self.pid = pid
        self.pendingTool = pendingTool; self.pendingInput = pendingInput
        self.notifyKind = notifyKind
        self.isDesktop = isDesktop; self.trustedActive = trustedActive
    }
}

// A "running" session only counts as live for this many seconds; afterwards it
// is treated as idle so a finished session settles quickly in the aggregate.
let runningLivenessWindow: Double = 90

// MARK: - Native session registry
// Claude Code itself writes ~/.claude/sessions/<pid>.json for every running
// session. This is the authoritative list of ALL running tasks (independent of
// our hooks): liveness == the pid is alive. We use it for discovery and base
// status, and overlay our hook data for error detection + prompt titles.

struct NativeSession {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var folder: String
    var nativeStatus: String   // "busy" | "waiting" | ...
    var waitingFor: String?
    var kind: String
    var entrypoint: String
    var updatedAt: Double       // seconds (native file stores ms)
    var startedAt: Double       // seconds; falls back to 0 if absent

    init?(json: [String: Any]) {
        guard let sid = json["sessionId"] as? String else { return nil }
        // pid may decode as Int or Double depending on JSON backend.
        let pidVal = (json["pid"] as? Int).map(Int32.init)
            ?? (json["pid"] as? Double).map { Int32($0) }
        guard let pid = pidVal else { return nil }
        self.pid = pid
        self.sessionId = sid
        self.cwd = (json["cwd"] as? String) ?? ""
        self.folder = (self.cwd as NSString).lastPathComponent
        if self.folder.isEmpty { self.folder = self.cwd }
        self.nativeStatus = (json["status"] as? String) ?? "idle"
        self.waitingFor = json["waitingFor"] as? String
        self.kind = (json["kind"] as? String) ?? "interactive"
        self.entrypoint = (json["entrypoint"] as? String) ?? "cli"
        let ms = (json["updatedAt"] as? Double) ?? ((json["updatedAt"] as? Int).map(Double.init) ?? 0)
        self.updatedAt = ms / 1000.0
        let sms = (json["startedAt"] as? Double) ?? ((json["startedAt"] as? Int).map(Double.init) ?? 0)
        self.startedAt = sms / 1000.0
    }

    init(pid: Int32, sessionId: String, cwd: String, nativeStatus: String,
         waitingFor: String? = nil, kind: String = "interactive",
         entrypoint: String = "cli", updatedAt: Double, startedAt: Double = 0) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd
        self.folder = (cwd as NSString).lastPathComponent
        if self.folder.isEmpty { self.folder = cwd }
        self.nativeStatus = nativeStatus; self.waitingFor = waitingFor
        self.kind = kind; self.entrypoint = entrypoint
        self.updatedAt = updatedAt; self.startedAt = startedAt
    }

    // Human-readable activity line for the dropdown when no richer hook event.
    var activityText: String {
        switch nativeStatus {
        case "busy": return "working…"
        case "waiting": return waitingFor.map { "waiting · \($0)" } ?? "waiting for input"
        default: return "idle"
        }
    }
}

// Map Claude Code's native status to our display state.
// busy -> running, waiting -> needs-input, anything else -> idle.
func mapNativeStatus(_ status: String) -> Status {
    switch status {
    case "busy": return .running
    case "waiting": return .waiting
    default: return .idle
    }
}

// MARK: - Claude Desktop (Cowork / agent-mode) sessions
// The desktop app keeps its sessions in a SEPARATE registry at
//   ~/Library/Application Support/Claude/claude-code-sessions/<acct>/<ws>/local_<uuid>.json
// They DO also register in the native ~/.claude/sessions dir (with
// entrypoint == "claude-desktop", carrying a live pid) but with no
// busy/waiting/updatedAt — so the native entry can't tell their status or age.
// Some of them DO run the user's hooks now (interactive Cowork sessions in
// recent Claude Code builds), so when a hook state file exists for a desktop
// session we prefer it; only fall back to transcript inference when it doesn't.
struct DesktopSession {
    var sessionId: String   // == cliSessionId; maps to the transcript + token cache
    var cwd: String
    var folder: String
    var title: String
    var status: Status      // inferred by the loader (I/O) via inferDesktopStatus
    var prState: String?
    var prNumber: Int?
    var updatedAt: Double   // seconds (the file stores lastActivityAt in ms)
    // When the user last opened this session in Claude Desktop (file stores
    // lastFocusedAt in ms; 0 = never focused). Compared against the transcript
    // mtime to tell a finished-but-UNVIEWED session (→ .done, needs review) from
    // one the user has already looked at (→ idle, nothing to surface).
    var lastFocusedAt: Double = 0
    // The tool name the transcript tail ends on with no answer — set by the loader
    // for sessions blocked on the user (AskUserQuestion / ExitPlanMode). Drives the
    // approval panel and lets the merge distinguish "blocked" from "finished".
    var pendingTool: String? = nil
    // True for scheduled-task (cron bot) sessions — those carry a scheduledTaskId.
    // Claude Desktop's welcome page excludes them entirely, so we do too (issue
    // #32); they're headless automation, not something awaiting your attention.
    var isScheduled: Bool = false

    // Parses the persisted metadata. Returns nil for archived sessions or any
    // file missing a cliSessionId. Status defaults to .idle; the loader sets it
    // after reading the transcript tail.
    init?(json: [String: Any]) {
        guard let cid = json["cliSessionId"] as? String, !cid.isEmpty else { return nil }
        if (json["isArchived"] as? Bool) == true { return nil }
        self.sessionId = cid
        self.cwd = (json["cwd"] as? String) ?? ""
        self.folder = (self.cwd as NSString).lastPathComponent
        if self.folder.isEmpty { self.folder = self.cwd.isEmpty ? self.sessionId : self.cwd }
        let rawTitle = (json["title"] as? String) ?? ""
        self.title = rawTitle.isEmpty ? self.folder : rawTitle
        self.prState = json["prState"] as? String
        self.prNumber = (json["prNumber"] as? Int) ?? (json["prNumber"] as? Double).map { Int($0) }
        let ms = (json["lastActivityAt"] as? Double) ?? ((json["lastActivityAt"] as? Int).map(Double.init) ?? 0)
        self.updatedAt = ms / 1000.0
        let fms = (json["lastFocusedAt"] as? Double) ?? ((json["lastFocusedAt"] as? Int).map(Double.init) ?? 0)
        self.lastFocusedAt = fms / 1000.0
        if let sid = json["scheduledTaskId"] as? String, !sid.isEmpty { self.isScheduled = true }
        self.status = .idle
    }

    init(sessionId: String, cwd: String = "", title: String = "", status: Status,
         prState: String? = nil, prNumber: Int? = nil, updatedAt: Double,
         lastFocusedAt: Double = 0, pendingTool: String? = nil, isScheduled: Bool = false) {
        self.sessionId = sessionId; self.cwd = cwd
        self.folder = (cwd as NSString).lastPathComponent
        if self.folder.isEmpty { self.folder = cwd.isEmpty ? sessionId : cwd }
        self.title = title.isEmpty ? self.folder : title
        self.status = status; self.prState = prState; self.prNumber = prNumber
        self.updatedAt = updatedAt; self.lastFocusedAt = lastFocusedAt
        self.pendingTool = pendingTool; self.isScheduled = isScheduled
    }

    // Dropdown activity line: marks the row as Desktop-origin and shows PR state.
    var activityText: String {
        var parts = ["Desktop"]
        if let n = prNumber {
            parts.append("PR #\(n)" + (prState.map { " · \($0.lowercased())" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}

// Tools whose pending tool_use means the session is BLOCKED ON THE USER (the
// agent asked a question / is waiting for plan approval) rather than executing.
// These stay "waiting" no matter how long the transcript has been quiet — that
// quiet IS the session waiting for you. See inferDesktopStatus.
let userBlockingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

// What the transcript's last role-bearing message represents — the live signal
// the transcript adds beyond file freshness. Distinguishing `.finished` (ends on
// assistant TEXT — the turn is over, a `Stop`) from `.runningTool` (ends on an
// assistant tool_use with no result yet — a tool is executing) is what stops a
// just-finished session from being mislabelled "running" purely because its file
// is fresh. The old `transcriptPendingTool` collapsed `.finished` and `.userTurn`
// both to nil, so `inferDesktopStatus` couldn't tell them apart (issue #31).
enum TranscriptTail: Equatable {
    case finished                 // assistant text, just COMPLETED work — does NOT need you
    case finishedAsking           // assistant text that ENDS ASKING you a question → needs input
    case runningTool(String)      // assistant non-blocking tool_use, no result yet → executing
    case blocking(String)         // assistant user-blocking tool (AskUserQuestion / ExitPlanMode)
    case userTurn                 // ends on a user message / tool_result → agent about to continue
    case none                     // no role-bearing message found in the tail

    // The tool name for the blocking/running cases (nil otherwise) — mirrors the
    // old `transcriptPendingTool` return so the approval panel keeps working.
    var toolName: String? {
        switch self {
        case .blocking(let t), .runningTool(let t): return t
        default: return nil
        }
    }
}

// Does the agent's final text END BY ASKING the user something? A finished turn
// is only "needs input" when the agent is actually waiting on your answer — a
// plain completion ("done, tests pass") is not. Heuristic: the last non-empty
// line carries a question mark (ASCII "?" or full-width "？"). This separates
// "要我继续吗？" from "已完成，已合并。" without misclassifying every finished turn.
func textEndsAsking(_ text: String) -> Bool {
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let last = lines.last(where: { !$0.isEmpty }) else { return false }
    return last.contains("?") || last.contains("？")
}

// Classify the transcript tail by walking back to the last role-bearing message.
func classifyTail(_ lines: [[String: Any]]) -> TranscriptTail {
    for line in lines.reversed() {
        guard let msg = line["message"] as? [String: Any],
              let role = msg["role"] as? String else { continue }
        if role == "user" { return .userTurn }   // a user turn (incl. tool_result)
        if role == "assistant" {
            let content = msg["content"] as? [[String: Any]] ?? []
            let toolNames = content.compactMap { item -> String? in
                (item["type"] as? String) == "tool_use" ? (item["name"] as? String ?? "") : nil
            }
            // A user-blocking tool wins; else an executing tool; else it's text.
            if let blocking = toolNames.first(where: { userBlockingTools.contains($0) }) {
                return .blocking(blocking)
            }
            if let tool = toolNames.first(where: { !$0.isEmpty }) {
                return .runningTool(tool)
            }
            // Text-only turn: needs input only if it ends asking you something.
            let text = content.compactMap { item -> String? in
                (item["type"] as? String) == "text" ? (item["text"] as? String) : nil
            }.joined(separator: "\n")
            return textEndsAsking(text) ? .finishedAsking : .finished
        }
    }
    return .none
}

// Backward-compatible accessor: the tool name the tail ends on (nil if finished /
// a user turn / empty). Kept so existing callers and the approval panel work.
func transcriptPendingTool(_ lines: [[String: Any]]) -> String? { classifyTail(lines).toolName }

// Outer bound for scanning/keeping Desktop sessions in the welcome-list filter
// (issue #32) — interactive sessions up to ~24h old.
let desktopDoneWindow: Double = 24 * 3600

// How recently a turn that ENDED ASKING you still counts as "Needs input". A
// genuinely unanswered question stays actionable for a while (you clear it by
// replying), so this tracks the 24h list window. A plain completed turn is NOT
// "needs input" regardless of age — see inferDesktopStatus / classifyTail.
let desktopNeedsInputWindow: Double = 24 * 3600

// Mirror the welcome page's selection: drop scheduled-task (bot) sessions, and
// anything older than the ~24h activity window — except a session blocked on you
// (`.waiting`), which stays no matter how long it's been quiet (that quiet IS the
// wait). Pure so it's unit-testable independent of the I/O scan (issue #32).
func filterWelcomeSessions(_ sessions: [DesktopSession],
                           now: Double = Date().timeIntervalSince1970) -> [DesktopSession] {
    sessions.filter { d in
        if d.isScheduled { return false }
        if d.status == .waiting { return true }
        return now - d.updatedAt < desktopDoneWindow
    }
}

// Infer a Desktop session's status from its transcript TAIL (not raw freshness)
// + when the user last opened it:
//   • `.blocking` (AskUserQuestion / ExitPlanMode) → waiting, REGARDLESS of how
//     long it's been quiet — the agent is blocked on your answer, and that quiet
//     IS the wait.
//   • `.runningTool` / `.userTurn` → a tool is executing or the agent is mid-turn:
//     running only while fresh; a stale one stalled/crashed → idle.
//   • `.finished` → the agent ENDED its turn (a `Stop`). It is NOT running just
//     because the file is fresh (the issue #31 bug). Surface as `.done` ("needs
//     review") only while recent AND unviewed (last write newer than
//     lastFocusedAt); opening it in Claude advances lastFocusedAt past the
//     transcript so it self-clears. Stale / already-viewed → idle (hidden).
//   • `.none` → no transcript content to act on → idle.
func inferDesktopStatus(tail: TranscriptTail, mtime: Double, lastFocusedAt: Double = 0,
                        now: Double = Date().timeIntervalSince1970) -> Status {
    switch tail {
    case .blocking:
        return .waiting
    case .runningTool, .userTurn:
        return (now - mtime < runningLivenessWindow) ? .running : .idle
    case .finishedAsking:
        // Agent finished its turn ENDING ON A QUESTION → your turn to answer.
        // Counts as "Needs input" only when BOTH (a) the question is recent and
        // (b) you've actually ENGAGED with the session recently (lastFocusedAt in
        // window). (b) drops abandoned sessions: a conversation you last opened
        // days ago that a background loop appended a question to is NOT something
        // awaiting you — welcome-page parity. You clear it by replying (→ running).
        let recentQuestion = now - mtime < desktopNeedsInputWindow
        let recentlyEngaged = lastFocusedAt > 0 && now - lastFocusedAt < desktopNeedsInputWindow
        return (recentQuestion && recentlyEngaged) ? .done : .idle
    case .finished:
        // Plain COMPLETED turn — the agent did the work and did NOT ask you
        // anything. This does NOT need further input, so it's hidden (idle); the
        // list stays "running + needs-input + error", not a history of done work.
        return .idle
    case .none:
        return .idle
    }
}

// Merge the authoritative native sessions with our hook-derived enrichment.
// Native drives discovery + base status; hooks add error state, prompt titles
// and finer-grained activity. Hook-only sessions (e.g. headless `claude -p`
// runs that never appear in the native registry) are included while recent.
// Desktop sessions (separate registry, status pre-inferred) are folded in last,
// de-duped against anything already surfaced.
func mergeSessions(native: [NativeSession], hooks: [String: Session],
                   desktop: [DesktopSession] = [],
                   now: Double = Date().timeIntervalSince1970) -> [Session] {
    var out: [Session] = []
    var usedHookIds = Set<String>()

    // Desktop sessions also appear here with entrypoint "claude-desktop" and a
    // live pid, but no busy/waiting/updatedAt. When a hook state file exists
    // for one we can merge it like any other native row (hook drives status,
    // native gives pid for jump-to-session); otherwise we skip it here and let
    // the transcript-driven desktop pass below own the row — without a hook the
    // native entry alone would surface a misleading zero-age idle row.
    var desktopPid: [String: Int32] = [:]
    for n in native where n.entrypoint == "claude-desktop" { desktopPid[n.sessionId] = n.pid }
    // Transcript-grounded Desktop status (running / waiting-blocked / done / idle),
    // keyed by id, produced by loadDesktop. For a Desktop native entry we trust
    // THIS over the hook's idle/running: the hook can stay stuck on "running" long
    // after the agent stopped, and its "idle" can't tell a finished-but-unreviewed
    // turn from one you've already seen. The hook still overlays error + pending
    // approval details below.
    var desktopByID: [String: DesktopSession] = [:]
    for d in desktop { desktopByID[d.sessionId] = d }

    for n in native {
        let h = hooks[n.sessionId]
        let dg = n.entrypoint == "claude-desktop" ? desktopByID[n.sessionId] : nil
        // A Desktop native entry with neither a transcript-grounded status nor a
        // hook carries no usable state (no busy/waiting field) — skip it here and
        // let the fresh-desktop fallback below own a brand-new conversation.
        if n.entrypoint == "claude-desktop" && dg == nil && h == nil { continue }
        if h != nil { usedHookIds.insert(n.sessionId) }

        var status = mapNativeStatus(n.nativeStatus)
        // Desktop native entries carry no busy/waiting field. The transcript scan
        // is the base, but a FRESH hook saying "running" means the agent is
        // actively working (Stop hasn't fired) even when the transcript tail
        // momentarily ended on text — without this an actively-running session
        // that's between tool calls reads as `.done` and the running count
        // under-reports (it should match the agents Claude shows as running).
        // A STALE running hook is ignored (the missed-Stop case from issue #31).
        if n.entrypoint == "claude-desktop" {
            let hookRunningFresh = h?.status == .running && now - (h?.updatedAt ?? 0) < runningLivenessWindow
            if let dg = dg {
                if dg.status == .waiting { status = .waiting }      // blocked on user wins
                else if hookRunningFresh { status = .running }      // fresh hook = actively working
                else { status = dg.status }                         // done / idle / running from transcript
            } else if let h = h, now - h.updatedAt < runningLivenessWindow {
                status = h.status                                   // no transcript yet: trust a fresh hook
            } else {
                status = .idle
            }
        }
        // Hook `waiting` overrides native `busy` for CLI sessions too: the hook
        // fires PreToolUse for AskUserQuestion / ExitPlanMode / Notification
        // (the user-blocking signals) while the native registry can still read
        // "busy" — without this override, a session that's literally blocked on
        // your answer would show green. Only honor it while the hook is recent;
        // a stale hook waiting yields to native (recovery).
        if let h = h, h.status == .waiting,
           now - h.updatedAt < runningLivenessWindow,
           status != .waiting {
            status = .waiting
        }
        // Error overlay: only our hooks know about tool failures. Apply while
        // the error is recent; if Claude has since gone busy/waiting natively
        // and the error aged out, the native status (recovery) wins.
        if let h = h, h.status == .error {
            let errTime = h.errorAt ?? h.updatedAt
            if now - errTime < runningLivenessWindow { status = .error }
        }

        // Desktop recency lives in the transcript mtime (dg.updatedAt); the native
        // entry has none and the hook's can lag, so fold it into the sort key.
        let updated = max(n.updatedAt, h?.updatedAt ?? 0, dg?.updatedAt ?? 0)
        let title: String = {
            if let t = h?.title, !t.isEmpty, t != n.folder { return t }
            if let t = dg?.title, !t.isEmpty { return t }
            return n.folder
        }()
        let lastEvent: String = {
            if let h = h, h.updatedAt >= n.updatedAt, !h.lastEvent.isEmpty { return h.lastEvent }
            if let dg = dg { return dg.activityText }
            return n.activityText
        }()
        // Trust the resolved status without an age check when the source is
        // still live: native says busy/waiting right now (pid filtered alive in
        // loadNative), or this is a Desktop entry whose hook just reported
        // running/waiting. Without this flag the aggregate would flip to idle
        // 90s into a long "thinking" turn even though the session really is busy.
        let trusted: Bool = {
            if n.nativeStatus == "busy" || n.nativeStatus == "waiting" { return true }
            // Desktop status is loader-gated (waiting never decays; done already
            // passed its recency+unviewed gate; running means a fresh transcript) —
            // so disable the 90s aggregate decay for all three.
            if n.entrypoint == "claude-desktop" {
                return status == .running || status == .waiting || status == .done
            }
            return false
        }()

        out.append(Session(id: n.sessionId, folder: n.folder, cwd: n.cwd, status: status,
                           title: title, lastEvent: lastEvent, lastError: h?.lastError,
                           errorAt: h?.errorAt, updatedAt: updated, pid: n.pid,
                           pendingTool: h?.pendingTool ?? dg?.pendingTool,
                           pendingInput: h?.pendingInput,
                           notifyKind: h?.notifyKind,
                           isDesktop: n.entrypoint == "claude-desktop",
                           trustedActive: trusted))
    }

    for (id, h) in hooks where !usedHookIds.contains(id) {
        // No native entry (not a tracked process) — include only if it's recent
        // and actually doing something, so ended sessions don't linger.
        if now - h.updatedAt < 120 && h.status != .idle {
            out.append(h)
        }
    }

    // Desktop sessions: include only recent + non-idle (mirrors the hook-only
    // rule, so the dozens of historical desktop sessions don't flood the list),
    // and skip any id already surfaced by native/hook discovery.
    var seen = Set(out.map { $0.id })

    // Fresh-Desktop fallback: a claude-desktop native entry with no hook and no
    // transcript on disk yet (startedAt within the last 5 min) is a brand-new
    // conversation. Without this we'd drop it entirely until the first hook or
    // transcript line. Surface as running so the user sees their new session.
    let freshDesktopWindow: Double = 300
    for n in native where n.entrypoint == "claude-desktop"
        && hooks[n.sessionId] == nil
        && !desktop.contains(where: { $0.sessionId == n.sessionId })
        && !seen.contains(n.sessionId)
        && n.startedAt > 0 && now - n.startedAt < freshDesktopWindow {
        out.append(Session(id: n.sessionId, folder: n.folder, cwd: n.cwd,
                           status: .running, title: n.folder,
                           lastEvent: "session started", updatedAt: n.startedAt,
                           pid: n.pid, isDesktop: true, trustedActive: true))
        seen.insert(n.sessionId)
    }

    for d in desktop where !seen.contains(d.sessionId) {
        // .waiting = blocked on the user (a question / plan approval); .done =
        // finished, awaiting your review — both stay visible no matter how long
        // they've been quiet (the loader already gated their recency). .running
        // only counts while the transcript is fresh.
        let include = d.status == .waiting || d.status == .done
            || (now - d.updatedAt < 120 && d.status == .running)
        if include {
            // waiting/done are loader-gated, so don't let the 90s aggregate decay
            // drop them. Running is gated on freshness above; leave it un-trusted
            // so a session that quietly stalls drops out of the glyph after 90s.
            let trusted = d.status == .waiting || d.status == .done
            out.append(Session(id: d.sessionId, folder: d.folder, cwd: d.cwd,
                               status: d.status, title: d.title,
                               lastEvent: d.activityText, updatedAt: d.updatedAt,
                               pid: desktopPid[d.sessionId],
                               pendingTool: d.pendingTool,
                               isDesktop: true, trustedActive: trusted))
            seen.insert(d.sessionId)
        }
    }

    // The list is exactly two categories: actively RUNNING + NEEDS-HANDLING
    // (waiting / done / error). Anything that decays to idle — an idle terminal, a
    // finished-and-seen Desktop chat, a stale-running session past its liveness
    // window — is dropped so the list mirrors the *current* Claude state rather
    // than accumulating history.
    var visible = out.filter { effectiveStatus($0, now: now) != .idle }

    // Sessions needing the user's attention come first (error > waiting > running
    // > done, via Status.priority), then most-recent-first within a rank. A
    // waiting/done Desktop session's updatedAt = transcript mtime, which stops
    // advancing while it waits, so a pure updatedAt sort would sink the very
    // session the user needs to act on below already-finished ones.
    visible.sort {
        $0.status.priority != $1.status.priority
            ? $0.status.priority > $1.status.priority
            : $0.updatedAt > $1.updatedAt
    }
    return visible
}

func relativeAge(_ epoch: Double, now: Double = Date().timeIntervalSince1970) -> String {
    let secs = Int(now - epoch)
    if secs < 5 { return "just now" }
    if secs < 60 { return "\(secs)s ago" }
    let mins = secs / 60
    if mins < 60 { return "\(mins)m ago" }
    let hrs = mins / 60
    if hrs < 24 { return "\(hrs)h ago" }
    return "\(hrs / 24)d ago"
}

// Choose the single icon that represents all sessions.
// error > waiting > running(live) > idle. Stale "running" decays to idle.
// Errors decay to idle after `runningLivenessWindow` too (the dynamic island
// spec calls out 90s for error transience — past the window, native recovery
// wins).
// The status a session presents *right now*, after liveness decay — the single
// rule every "is it active" surface shares (the owl glyph via aggregateStatus,
// the menu-bar badge, the popover RUNNING·WAITING split and "N active" label,
// and the dynamic island via activeCount). Computing "active" three different
// ways is how the badge, popover, and island ended up disagreeing.
//
//   running → only while trustedActive or within the 90s window, else idle.
//             trustedActive disables the decay: the source is still live
//             (native says busy/waiting now, or a Desktop hook just updated),
//             so a long thinking turn stays running instead of flipping to idle.
//   error   → yields to idle once aged out of its 90s window, regardless of
//             trust, so native recovery can win (island spec §3 transience).
//   waiting / idle → pass through unchanged.
func effectiveStatus(_ s: Session, now: Double = Date().timeIntervalSince1970) -> Status {
    switch s.status {
    case .running:
        let live = s.trustedActive || (now - s.updatedAt < runningLivenessWindow)
        return live ? .running : .idle
    case .error:
        let recent = (s.errorAt ?? s.updatedAt) > now - runningLivenessWindow
        return recent ? .error : .idle
    default:
        return s.status
    }
}

func aggregateStatus(_ sessions: [Session], now: Double = Date().timeIntervalSince1970) -> Status {
    var best: Status = .idle
    for s in sessions {
        let effective = effectiveStatus(s, now: now)
        if effective.priority > best.priority { best = effective }
    }
    return best
}

// Sessions whose live status counts as "non-idle" for the count badges.
// Shares `effectiveStatus` with aggregateStatus, so a stale-running session
// (or one carrying an aged-out error) never pads the active count.
func activeCount(_ sessions: [Session], now: Double = Date().timeIntervalSince1970) -> Int {
    sessions.reduce(0) { $0 + (effectiveStatus($1, now: now) == .idle ? 0 : 1) }
}

// Count sessions whose decayed (effective) status equals `status` — the
// per-status split (running vs waiting) the popover header and menu-bar badge
// show, kept consistent with the totals from `activeCount`.
func statusCount(_ sessions: [Session], _ status: Status,
                 now: Double = Date().timeIntervalSince1970) -> Int {
    sessions.reduce(0) { $0 + (effectiveStatus($1, now: now) == status ? 1 : 0) }
}

// The number shown next to the menu-bar owl glyph: the count of sessions in the
// SAME state the glyph's colour is showing (i.e. matching aggregateStatus), so
// the digit and the colour always agree. Priority error > needs-input > running
// > idle(no number). "Needs input" is waiting + done — both render the same
// yellow, so the yellow glyph's number covers both.
func badgeCount(_ sessions: [Session], now: Double = Date().timeIntervalSince1970) -> Int {
    switch aggregateStatus(sessions, now: now) {
    case .error:          return statusCount(sessions, .error, now: now)
    case .waiting, .done: return statusCount(sessions, .waiting, now: now) + statusCount(sessions, .done, now: now)
    case .running:        return statusCount(sessions, .running, now: now)
    case .idle:           return 0
    }
}

// MARK: - Dynamic Island folded label
//
// Pure rendering helper for the island's folded state. Picks the single
// highest-priority session and produces the (main, sub) text per the spec's
// §3 template table:
//
//   error   → "Error · <tool>"     · sub = last_error (truncated)
//   waiting → "Awaiting · <tool>"  · sub = pending_input (truncated)
//   running → "Running · <title>"  · sub = last_event / cwd folder
//   idle    → "Claude Dot"         · no sub
//
// The label's `kind` lets the view pick a color (accent for waiting, red for
// error, ink for running, ink-3 for idle) without knowing the templates.

enum IslandLabelKind { case idle, running, waiting, error }

struct IslandLabel: Equatable {
    var main: String
    var sub: String
    var kind: IslandLabelKind
}

// Truncate to `n` chars adding a single … (spec §7: main ≤ 12, sub ≤ 28).
func islandTruncate(_ s: String, _ n: Int) -> String {
    guard s.count > n else { return s }
    let cut = s.index(s.startIndex, offsetBy: max(0, n - 1))
    return String(s[..<cut]) + "…"
}

// Pick the session most worth showing in the folded label for the given
// aggregate status. For error/waiting we pick the most recent of that class
// (so the freshest signal wins). For running we pick the most recently
// updated running session. Returns nil for idle.
func islandFocusSession(_ sessions: [Session], aggregate: Status,
                        now: Double = Date().timeIntervalSince1970) -> Session? {
    switch aggregate {
    case .idle: return nil
    case .error:
        return sessions
            .filter { $0.status == .error && ($0.errorAt ?? $0.updatedAt) > now - runningLivenessWindow }
            .max(by: { ($0.errorAt ?? $0.updatedAt) < ($1.errorAt ?? $1.updatedAt) })
    case .waiting:
        return sessions.filter { $0.status == .waiting }
            .max(by: { $0.updatedAt < $1.updatedAt })
    case .running:
        return sessions
            .filter { $0.status == .running && ($0.trustedActive || now - $0.updatedAt < runningLivenessWindow) }
            .max(by: { $0.updatedAt < $1.updatedAt })
    case .done:
        return sessions.filter { $0.status == .done }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }
}

func islandFoldedLabel(sessions: [Session],
                        now: Double = Date().timeIntervalSince1970) -> IslandLabel {
    let agg = aggregateStatus(sessions, now: now)
    guard let focus = islandFocusSession(sessions, aggregate: agg, now: now) else {
        return IslandLabel(main: "Claude Dot", sub: "", kind: .idle)
    }
    switch agg {
    case .idle:
        return IslandLabel(main: "Claude Dot", sub: "", kind: .idle)
    case .done:
        // Agent finished its turn — your turn to reply ("Needs input", calm).
        return IslandLabel(main: "Needs input · " + islandTruncate(focus.folder, 12),
                           sub: islandTruncate(focus.folder, 28), kind: .waiting)
    case .error:
        let tool = focus.pendingTool ?? focus.lastEvent.components(separatedBy: " ").last ?? "—"
        let main = "Error · " + islandTruncate(tool, 12)
        let sub = islandTruncate(focus.lastError ?? focus.lastEvent, 28)
        return IslandLabel(main: main, sub: sub, kind: .error)
    case .waiting:
        // pendingTool may be nil if the native registry surfaced "waiting"
        // before the PreToolUse hook fired (or for sessions that don't run
        // hooks). Falling back to "approval" reads as a generic placeholder;
        // the folder name is more informative — it identifies WHICH session is
        // blocking, which is the question the user actually has.
        let main: String = {
            if let t = focus.pendingTool, !t.isEmpty {
                return "Awaiting · " + islandTruncate(t, 12)
            }
            return "Awaiting · " + islandTruncate(focus.folder, 12)
        }()
        // Sub: pending_input (the Bash command, the WebFetch URL) only.
        // NEVER fall back to title — that's the user's prompt text, and §8
        // Privacy: 岛上不暴露完整 prompt 内容. When pending_input is missing
        // show the cwd folder instead.
        let sub: String = {
            if let i = focus.pendingInput, !i.isEmpty {
                return islandTruncate(i, 28)
            }
            return islandTruncate(focus.folder, 28)
        }()
        return IslandLabel(main: main, sub: sub, kind: .waiting)
    case .running:
        // Same privacy rule: title may be the user's prompt — prefer folder.
        let main = "Running · " + islandTruncate(focus.folder, 14)
        let sub: String = {
            if !focus.lastEvent.isEmpty { return islandTruncate(focus.lastEvent, 28) }
            return islandTruncate(focus.folder, 28)
        }()
        return IslandLabel(main: main, sub: sub, kind: .running)
    }
}

// Variant the controller should auto-expand to for a given session. Maps the
// session's status / pending tool to the §4 variant taxonomy. Useful both for
// transition detection and for the snapshot renderer.
enum IslandVariant: String { case sessionList, approval, question, completion }

func islandVariantFor(pendingTool: String?) -> IslandVariant {
    if let t = pendingTool, userBlockingTools.contains(t) { return .question }
    return .approval
}

// The action the user must take for a session blocked on a pending tool, plus a
// human label for it, used to phrase the popover's approval panel. AskUserQuestion
// wants an *answer* (not an approval); ExitPlanMode is a plan to review; every
// other tool is an ordinary permission approval.
func approvalPrompt(pendingTool: String?) -> (verb: String, label: String) {
    switch pendingTool {
    case "AskUserQuestion": return ("Answer", "question")
    case "ExitPlanMode":    return ("Review", "plan")
    default:                return ("Approve", pendingTool ?? "a tool")
    }
}

// MARK: - Usage / token helpers (pure, used by the popover's usage meter)

// Compact a token/count into a short human string: 950, 1.5K, 12.4M, 2.0B.
func formatCount(_ n: Int) -> String {
    let d = Double(n)
    if abs(d) < 1_000          { return "\(n)" }
    if abs(d) < 999_500        { return String(format: "%.1fK", d / 1_000) }
    if abs(d) < 999_500_000    { return String(format: "%.1fM", d / 1_000_000) }
    return String(format: "%.1fB", d / 1_000_000_000)
}

// Sum the token usage across the assistant messages of a Claude Code transcript
// (one parsed JSON object per .jsonl line). Counts input + output + cache
// creation, and — by default — cache reads, i.e. total tokens processed.
//
// Pass includeCacheRead: false for "today" consumption: Claude Code re-reads the
// entire cached context on every turn, so cache_read_input_tokens re-counts the
// same prompt once per message and dominates the total (inflating it by 1–2
// orders of magnitude over a long day). Cache creation is paid once; cache reads
// are the cheap re-read of already-counted context.
func sessionTokenTotal(_ lines: [[String: Any]], includeCacheRead: Bool = true) -> Int {
    var keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
    if includeCacheRead { keys.append("cache_read_input_tokens") }
    var total = 0
    for line in lines {
        guard let msg = line["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { continue }
        for k in keys {
            if let v = usage[k] as? Int { total += v }
            else if let v = usage[k] as? Double { total += Int(v) }
        }
    }
    return total
}
