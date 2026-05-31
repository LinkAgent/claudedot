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

    init?(json: [String: Any]) {
        guard let id = json["session_id"] as? String else { return nil }
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
         pendingTool: String? = nil, pendingInput: String? = nil) {
        self.id = id; self.folder = folder; self.cwd = cwd; self.status = status
        self.title = title; self.lastEvent = lastEvent; self.lastError = lastError
        self.errorAt = errorAt; self.updatedAt = updatedAt; self.pid = pid
        self.pendingTool = pendingTool; self.pendingInput = pendingInput
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
    }

    init(pid: Int32, sessionId: String, cwd: String, nativeStatus: String,
         waitingFor: String? = nil, kind: String = "interactive",
         entrypoint: String = "cli", updatedAt: Double) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd
        self.folder = (cwd as NSString).lastPathComponent
        if self.folder.isEmpty { self.folder = cwd }
        self.nativeStatus = nativeStatus; self.waitingFor = waitingFor
        self.kind = kind; self.entrypoint = entrypoint; self.updatedAt = updatedAt
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

// Merge the authoritative native sessions with our hook-derived enrichment.
// Native drives discovery + base status; hooks add error state, prompt titles
// and finer-grained activity. Hook-only sessions (e.g. headless `claude -p`
// runs that never appear in the native registry) are included while recent.
func mergeSessions(native: [NativeSession], hooks: [String: Session],
                   now: Double = Date().timeIntervalSince1970) -> [Session] {
    var out: [Session] = []
    var usedHookIds = Set<String>()

    for n in native {
        let h = hooks[n.sessionId]
        if h != nil { usedHookIds.insert(n.sessionId) }

        var status = mapNativeStatus(n.nativeStatus)
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

        out.append(Session(id: n.sessionId, folder: n.folder, cwd: n.cwd, status: status,
                           title: title, lastEvent: lastEvent, lastError: h?.lastError,
                           errorAt: h?.errorAt, updatedAt: updated, pid: n.pid,
                           pendingTool: h?.pendingTool, pendingInput: h?.pendingInput))
    }

    for (id, h) in hooks where !usedHookIds.contains(id) {
        // No native entry (not a tracked process) — include only if it's recent
        // and actually doing something, so ended sessions don't linger.
        if now - h.updatedAt < 120 && h.status != .idle {
            out.append(h)
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
func aggregateStatus(_ sessions: [Session], now: Double = Date().timeIntervalSince1970) -> Status {
    var best: Status = .idle
    for s in sessions {
        let isRecent = now - s.updatedAt < runningLivenessWindow
        let effective: Status = (s.status == .running && !isRecent) ? .idle : s.status
        if effective.priority > best.priority { best = effective }
    }
    return best
}

// MARK: - Usage / token helpers (pure, used by the popover's usage meter)

// Compact a token/count into a short human string: 950, 1.5K, 12.4M, 2.0B.
func formatCount(_ n: Int) -> String {
    if n < 1_000 { return "\(n)" }
    let d = Double(n)
    if n < 1_000_000     { return String(format: "%.1fK", d / 1_000) }
    if n < 1_000_000_000 { return String(format: "%.1fM", d / 1_000_000) }
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
