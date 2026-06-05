// Pure model + logic, free of AppKit, so it can be unit-tested headlessly.
// Both the app (main.swift) and the test harness compile this exact file.

import Foundation

enum Status: String {
    case running, waiting, error, idle

    // Fallback glyphs (the app draws flat colored dots; these keep the model
    // self-describing and are used by headless contexts/tests). Color scheme:
    // running = green, needs-input = yellow, error = red, idle = neutral.
    var emoji: String {
        switch self {
        case .running: return "🟢"
        case .waiting: return "🟡"
        case .error:   return "🔴"
        case .idle:    return "⚪️"
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Needs input"
        case .error:   return "Error"
        case .idle:    return "Idle"
        }
    }

    // Priority for choosing the aggregate icon. Higher wins.
    var priority: Int {
        switch self {
        case .error:   return 3
        case .waiting: return 2
        case .running: return 1
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
    }

    // Test-friendly memberwise initializer.
    init(id: String, folder: String = "f", cwd: String = "", status: Status,
         title: String = "", lastEvent: String = "", lastError: String? = nil,
         errorAt: Double? = nil, updatedAt: Double, pid: Int32? = nil,
         pendingTool: String? = nil, pendingInput: String? = nil,
         isDesktop: Bool = false, trustedActive: Bool = false) {
        self.id = id; self.folder = folder; self.cwd = cwd; self.status = status
        self.title = title; self.lastEvent = lastEvent; self.lastError = lastError
        self.errorAt = errorAt; self.updatedAt = updatedAt; self.pid = pid
        self.pendingTool = pendingTool; self.pendingInput = pendingInput
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
        self.status = .idle
    }

    init(sessionId: String, cwd: String = "", title: String = "", status: Status,
         prState: String? = nil, prNumber: Int? = nil, updatedAt: Double) {
        self.sessionId = sessionId; self.cwd = cwd
        self.folder = (cwd as NSString).lastPathComponent
        if self.folder.isEmpty { self.folder = cwd.isEmpty ? sessionId : cwd }
        self.title = title.isEmpty ? self.folder : title
        self.status = status; self.prState = prState; self.prNumber = prNumber
        self.updatedAt = updatedAt
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

// Name of the tool the transcript tail ends on with no following user/tool_result
// — i.e. the session is blocked awaiting approval, a running tool, or (for the
// user-blocking tools above) the user's answer. nil when the last role-bearing
// message is a user turn or carries no tool_use. This is the only live signal
// the transcript adds beyond file freshness.
func transcriptPendingTool(_ lines: [[String: Any]]) -> String? {
    for line in lines.reversed() {
        guard let msg = line["message"] as? [String: Any],
              let role = msg["role"] as? String else { continue }
        if role == "user" { return nil }   // a user turn (incl. tool_result) answered it
        if role == "assistant" {
            let content = msg["content"] as? [[String: Any]] ?? []
            // Prefer a user-blocking tool name if present, else the first tool_use.
            let toolNames = content.compactMap { item -> String? in
                (item["type"] as? String) == "tool_use" ? (item["name"] as? String ?? "") : nil
            }
            if let blocking = toolNames.first(where: { userBlockingTools.contains($0) }) { return blocking }
            return toolNames.first
        }
    }
    return nil
}

// Infer a Desktop session's status from its transcript:
//   • Ends on a user-blocking tool (AskUserQuestion / ExitPlanMode) → waiting,
//     REGARDLESS of how long it has been quiet — the agent is blocked on your
//     answer, and that wait is exactly when the transcript goes silent. Letting
//     it decay to idle (the old bug) made "needs input" sessions vanish.
//   • Otherwise freshness alone decides: a recently-written transcript is the
//     agent working, a quiet one is idle.
// A pending NON-blocking tool_use (Bash/Edit/…) is a tool EXECUTING, not awaiting
// you — so it stays "running", not "waiting". (Classifying a mid-execution tool as
// waiting made an actively-working session flip waiting↔running every poll, which
// added/removed the approval panel and flickered the popover up and down.)
// pendingTool is the tool name the transcript ends on (nil if none / answered).
func inferDesktopStatus(pendingTool: String?, mtime: Double,
                        now: Double = Date().timeIntervalSince1970) -> Status {
    if let t = pendingTool, userBlockingTools.contains(t) { return .waiting }
    return (now - mtime >= runningLivenessWindow) ? .idle : .running
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

    for n in native {
        let h = hooks[n.sessionId]
        if n.entrypoint == "claude-desktop" && h == nil { continue }
        if h != nil { usedHookIds.insert(n.sessionId) }

        var status = mapNativeStatus(n.nativeStatus)
        // Desktop native entries carry no busy/waiting field, so mapNativeStatus
        // always returns .idle for them — when a hook is present it's the ONLY
        // live status signal, so let it drive (running / waiting / error alike).
        if n.entrypoint == "claude-desktop", let h = h {
            status = h.status
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

        let updated = max(n.updatedAt, h?.updatedAt ?? 0)
        let title: String = {
            if let t = h?.title, !t.isEmpty, t != n.folder { return t }
            return n.folder
        }()
        let lastEvent: String = {
            if let h = h, h.updatedAt >= n.updatedAt, !h.lastEvent.isEmpty { return h.lastEvent }
            return n.activityText
        }()
        // Trust the resolved status without an age check when the source is
        // still live: native says busy/waiting right now (pid filtered alive in
        // loadNative), or this is a Desktop entry whose hook just reported
        // running/waiting. Without this flag the aggregate would flip to idle
        // 90s into a long "thinking" turn even though the session really is busy.
        let trusted: Bool = {
            if n.nativeStatus == "busy" || n.nativeStatus == "waiting" { return true }
            if n.entrypoint == "claude-desktop", let h = h,
               h.status == .running || h.status == .waiting { return true }
            return false
        }()

        out.append(Session(id: n.sessionId, folder: n.folder, cwd: n.cwd, status: status,
                           title: title, lastEvent: lastEvent, lastError: h?.lastError,
                           errorAt: h?.errorAt, updatedAt: updated, pid: n.pid,
                           pendingTool: h?.pendingTool, pendingInput: h?.pendingInput,
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
        // .waiting = blocked on the user (a question / plan approval) — keep it
        // visible no matter how long it's been quiet; that's the whole point of a
        // "needs input" flag. .running only counts while the transcript is fresh.
        let include = d.status == .waiting || (now - d.updatedAt < 120 && d.status == .running)
        if include {
            // Transcript-inferred waiting is "blocked on user" — never decay.
            // Running is gated on freshness above; let aggregate apply its own
            // staleness check so a session that quietly stalls (transcript stops
            // appending) drops out of the glyph after 90s.
            let trusted = d.status == .waiting
            out.append(Session(id: d.sessionId, folder: d.folder, cwd: d.cwd,
                               status: d.status, title: d.title,
                               lastEvent: d.activityText, updatedAt: d.updatedAt,
                               pid: desktopPid[d.sessionId], isDesktop: true,
                               trustedActive: trusted))
            seen.insert(d.sessionId)
        }
    }

    out.sort { $0.updatedAt > $1.updatedAt }
    return out
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
func aggregateStatus(_ sessions: [Session], now: Double = Date().timeIntervalSince1970) -> Status {
    var best: Status = .idle
    for s in sessions {
        // trustedActive disables the running decay: the source is still live
        // (native says busy/waiting right now, or a Desktop hook just updated).
        // Error transience still applies — a stale error always yields to
        // recovery regardless of trust.
        let isRecent = s.trustedActive || (now - s.updatedAt < runningLivenessWindow)
        let errorRecent: Bool = (s.errorAt ?? s.updatedAt) > now - runningLivenessWindow
        let effective: Status
        switch s.status {
        case .running: effective = isRecent ? .running : .idle
        case .error:   effective = errorRecent ? .error : .idle
        default:       effective = s.status
        }
        if effective.priority > best.priority { best = effective }
    }
    return best
}

// Sessions whose live status counts as "non-idle" for the island's count badge.
// Same rule as `aggregateStatus`: running must be recent; error must be within
// its 90s window. (A session that's idle natively but carries an aged-out error
// shouldn't pad the active count.)
func activeCount(_ sessions: [Session], now: Double = Date().timeIntervalSince1970) -> Int {
    sessions.reduce(0) { acc, s in
        switch s.status {
        case .idle: return acc
        case .running:
            let live = s.trustedActive || (now - s.updatedAt < runningLivenessWindow)
            return acc + (live ? 1 : 0)
        case .error:   return acc + ((s.errorAt ?? s.updatedAt) > now - runningLivenessWindow ? 1 : 0)
        case .waiting: return acc + 1
        }
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
// (one parsed JSON object per .jsonl line). Counts input + output + both cache
// tiers — i.e. total tokens processed by the session.
func sessionTokenTotal(_ lines: [[String: Any]]) -> Int {
    let keys = ["input_tokens", "output_tokens",
                "cache_read_input_tokens", "cache_creation_input_tokens"]
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
