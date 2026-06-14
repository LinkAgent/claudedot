// Headless tests for the shared model logic. Compiled together with the real
// Model.swift (no AppKit), so it exercises production code.
//   swiftc app/Sources/Model.swift app/tests/model_test.swift -o /tmp/mt && /tmp/mt

import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool) {
    print((cond ? "  ok   " : "  FAIL ") + name)
    if !cond { failures += 1 }
}

let now = 1_000_000.0

// --- Session JSON parsing ---
let good = Session(json: [
    "session_id": "s1", "folder": "proj", "cwd": "/a/b",
    "status": "error", "title": "do x", "last_event": "boom",
    "last_error": "psql refused", "error_at": now, "updated_at": now
])
check("parses valid json", good != nil)
check("status parsed", good?.status == .error)
check("lastError parsed", good?.lastError == "psql refused")

check("rejects json without session_id", Session(json: ["status": "idle"]) == nil)

let defaulted = Session(json: ["session_id": "s2"])
check("missing status defaults to idle", defaulted?.status == .idle)
check("unknown status falls back to idle",
      Session(json: ["session_id": "s3", "status": "weird"])?.status == .idle)

// --- aggregateStatus priority ---
func sess(_ st: Status, age: Double) -> Session {
    Session(id: "x", status: st, updatedAt: now - age)
}
check("empty -> idle", aggregateStatus([], now: now) == .idle)
check("error beats waiting+running",
      aggregateStatus([sess(.running, age: 1), sess(.waiting, age: 1), sess(.error, age: 1)], now: now) == .error)
check("waiting beats running",
      aggregateStatus([sess(.running, age: 1), sess(.waiting, age: 1)], now: now) == .waiting)
check("running when only running",
      aggregateStatus([sess(.running, age: 1), sess(.idle, age: 1)], now: now) == .running)
check("stale running decays to idle",
      aggregateStatus([sess(.running, age: 120)], now: now) == .idle)
check("fresh running stays running",
      aggregateStatus([sess(.running, age: 10)], now: now) == .running)
// trustedActive disables the running decay — used when native says busy or a
// Desktop hook is the live signal. A long "thinking" turn (no events for 2min)
// should stay running in the glyph, not flip to idle.
let trustedStale = Session(id: "t", status: .running,
                            updatedAt: now - 600, trustedActive: true)
check("trustedActive running stays running past window",
      aggregateStatus([trustedStale], now: now) == .running)
check("trustedActive running counts as active",
      activeCount([trustedStale], now: now) == 1)
check("untrusted stale running drops from activeCount",
      activeCount([sess(.running, age: 600)], now: now) == 0)

// --- effectiveStatus: the one rule the badge / popover / island all share ---
check("effective: fresh running stays running",
      effectiveStatus(sess(.running, age: 10), now: now) == .running)
check("effective: stale running decays to idle",
      effectiveStatus(sess(.running, age: 600), now: now) == .idle)
check("effective: trustedActive stale running stays running",
      effectiveStatus(trustedStale, now: now) == .running)
check("effective: fresh error stays error",
      effectiveStatus(sess(.error, age: 10), now: now) == .error)
check("effective: stale error decays to idle",
      effectiveStatus(sess(.error, age: 100000), now: now) == .idle)
check("effective: waiting always waiting",
      effectiveStatus(sess(.waiting, age: 100000), now: now) == .waiting)

// One stale-running + one fresh-waiting: every "active" surface must report
// the same thing (this is the bug in #21 — badge said 1, popover said 2).
let mixedActive = [sess(.running, age: 600), sess(.waiting, age: 1)]
check("statusCount running excludes the stale one", statusCount(mixedActive, .running, now: now) == 0)
check("statusCount waiting counts the fresh one", statusCount(mixedActive, .waiting, now: now) == 1)
check("activeCount agrees with the per-status split",
      activeCount(mixedActive, now: now) == statusCount(mixedActive, .running, now: now)
                                          + statusCount(mixedActive, .waiting, now: now)
                                          + statusCount(mixedActive, .error, now: now))
check("aggregate of the mixed set is waiting (running decayed)",
      aggregateStatus(mixedActive, now: now) == .waiting)
// trustedActive flips the same stale-running session back to counted everywhere.
let mixedTrusted = [trustedStale, sess(.waiting, age: 1)]
check("trusted stale running counts in statusCount", statusCount(mixedTrusted, .running, now: now) == 1)
check("trusted mixed activeCount == 2", activeCount(mixedTrusted, now: now) == 2)
// Errors are transient in the aggregate: a fresh error shows, but one past the
// runningLivenessWindow (90s) decays to idle so native recovery can win — see
// the dynamic-island spec's §3 error transience note + aggregateStatus().
check("fresh error shows",
      aggregateStatus([sess(.error, age: 10)], now: now) == .error)
check("stale error decays to idle (transient)",
      aggregateStatus([sess(.error, age: 100000)], now: now) == .idle)

// --- relativeAge ---
check("just now", relativeAge(now, now: now) == "just now")
check("seconds", relativeAge(now - 30, now: now) == "30s ago")
check("minutes", relativeAge(now - 600, now: now) == "10m ago")
check("hours", relativeAge(now - 7200, now: now) == "2h ago")
check("days", relativeAge(now - 172800, now: now) == "2d ago")

// --- emoji/label coverage ---
check("emojis distinct",
      Set([Status.running, .waiting, .error, .idle].map { $0.emoji }).count == 4)

// --- NativeSession parsing ---
let nat = NativeSession(json: [
    "pid": 50711, "sessionId": "adcb", "cwd": "/Users/demo/workspace/dashboard-app",
    "status": "waiting", "waitingFor": "permission prompt", "kind": "interactive",
    "entrypoint": "cli", "updatedAt": (now * 1000.0)
])
check("native parses", nat != nil)
check("native pid", nat?.pid == 50711)
check("native folder from cwd", nat?.folder == "dashboard-app")
check("native ms->seconds", nat?.updatedAt == now)
check("native rejects no sessionId", NativeSession(json: ["pid": 1, "status": "busy"]) == nil)
check("native rejects no pid", NativeSession(json: ["sessionId": "x", "status": "busy"]) == nil)
check("activity text for waiting", (nat?.activityText ?? "").contains("permission prompt"))

check("map busy->running", mapNativeStatus("busy") == .running)
check("map waiting->waiting", mapNativeStatus("waiting") == .waiting)
check("map unknown->idle", mapNativeStatus("compacting") == .idle)

// --- mergeSessions ---
func nsess(_ id: String, _ st: String, age: Double = 1, waiting: String? = nil) -> NativeSession {
    NativeSession(pid: 123, sessionId: id, cwd: "/a/\(id)", nativeStatus: st,
                  waitingFor: waiting, updatedAt: now - age)
}
func hsess(_ id: String, _ st: Status, age: Double = 1, err: String? = nil, title: String = "") -> Session {
    Session(id: id, folder: id, cwd: "/a/\(id)", status: st, title: title,
            lastEvent: "ev", lastError: err, errorAt: err != nil ? now - age : nil,
            updatedAt: now - age)
}

// native discovery with no hooks at all -> still shows every running task
let m1 = mergeSessions(native: [nsess("a", "busy"), nsess("b", "waiting")], hooks: [:], now: now)
check("native-only discovery count", m1.count == 2)
check("native-only busy -> running", m1.first(where: { $0.id == "a" })?.status == .running)
check("native-only waiting -> waiting", m1.first(where: { $0.id == "b" })?.status == .waiting)
// Native busy/waiting are authoritative — merge marks them trusted so the
// aggregate doesn't decay them during a long thinking turn.
check("native busy is trustedActive",
      m1.first(where: { $0.id == "a" })?.trustedActive == true)
check("native waiting is trustedActive",
      m1.first(where: { $0.id == "b" })?.trustedActive == true)
let m1Idle = mergeSessions(native: [nsess("idle", "idle")], hooks: [:], now: now)
check("native idle is NOT trustedActive",
      m1Idle.first?.trustedActive == false)
// A native busy session whose updatedAt is ancient still stays running in the
// aggregate — this is the "model is thinking for minutes" case.
let m1Old = mergeSessions(native: [nsess("a", "busy", age: 600)], hooks: [:], now: now)
check("ancient native busy still aggregates as running",
      aggregateStatus(m1Old, now: now) == .running)

// hook error overlays a native busy session
let m2 = mergeSessions(native: [nsess("a", "busy")],
                       hooks: ["a": hsess("a", .error, err: "boom")], now: now)
check("hook error overlays native busy", m2.first?.status == .error)
check("hook error text surfaced", m2.first?.lastError == "boom")

// stale error (old) does NOT override a currently-busy native session
let m3 = mergeSessions(native: [nsess("a", "busy")],
                       hooks: ["a": hsess("a", .error, age: 1000, err: "old")], now: now)
check("stale error yields to native busy (recovery)", m3.first?.status == .running)

// hook prompt title enriches native session
let m4 = mergeSessions(native: [nsess("a", "busy")],
                       hooks: ["a": hsess("a", .running, title: "Fix login")], now: now)
check("hook title used", m4.first?.title == "Fix login")

// A hook saying "waiting" (AskUserQuestion / ExitPlanMode / Notification)
// must override a native "busy" for CLI sessions — the agent is blocked on the
// user, and the user-facing dot must reflect that rather than green-running.
let mWaitOverride = mergeSessions(
    native: [nsess("c", "busy")],
    hooks: ["c": hsess("c", .waiting, age: 1)], now: now)
check("hook waiting overrides native busy (CLI)",
      mWaitOverride.first?.status == .waiting)
// Stale hook waiting yields to native recovery — only fresh asks override.
let mWaitStale = mergeSessions(
    native: [nsess("c", "busy")],
    hooks: ["c": hsess("c", .waiting, age: 1000)], now: now)
check("stale hook waiting yields to native busy",
      mWaitStale.first?.status == .running)

// hook-only recent active session (headless run) is included
let m5 = mergeSessions(native: [], hooks: ["z": hsess("z", .running, age: 5)], now: now)
check("recent hook-only session included", m5.count == 1)
// hook-only idle/old session is dropped
let m6 = mergeSessions(native: [], hooks: ["z": hsess("z", .idle, age: 5)], now: now)
check("idle hook-only dropped", m6.count == 0)
let m7 = mergeSessions(native: [], hooks: ["z": hsess("z", .running, age: 999)], now: now)
check("old hook-only dropped", m7.count == 0)

// dead native sessions are filtered by the app (pidAlive) before merge, so a
// session present here is assumed alive; sorting is most-recent-first
let m8 = mergeSessions(native: [nsess("old", "busy", age: 50), nsess("new", "busy", age: 1)],
                       hooks: [:], now: now)
check("sorted most-recent-first", m8.first?.id == "new")

// Attention-needing sessions sort ahead of more-recently-updated ones: a
// waiting session (older updatedAt) must outrank a busy and an idle session
// that updated more recently, so it isn't buried in the list.
let m8a = mergeSessions(
    native: [nsess("idleNew", "idle", age: 0.5),
             nsess("busyNew", "busy", age: 1),
             nsess("waitOld", "waiting", age: 50)],
    hooks: [:], now: now)
check("waiting sorts ahead of newer busy/idle", m8a.first?.id == "waitOld")
check("busy sorts ahead of newer idle", m8a[1].id == "busyNew")
check("idle sorts last", m8a.last?.id == "idleNew")

// --- formatCount ---
check("count small", formatCount(950) == "950")
check("count K", formatCount(1_500) == "1.5K")
check("count M", formatCount(8_200_000) == "8.2M")
check("count M2", formatCount(12_400_000) == "12.4M")
check("count B", formatCount(2_000_000_000) == "2.0B")

// --- sessionTokenTotal ---
let tlines: [[String: Any]] = [
    ["type": "user"],  // no usage -> ignored
    ["message": ["usage": ["input_tokens": 100, "output_tokens": 20,
                           "cache_read_input_tokens": 5, "cache_creation_input_tokens": 3]]],
    ["message": ["usage": ["input_tokens": 50.0, "output_tokens": 10.0]]], // doubles
]
check("token total sums usage", sessionTokenTotal(tlines) == 100 + 20 + 5 + 3 + 50 + 10)
// "Today" consumption excludes cache reads (re-summed every message -> inflated).
check("token total excludes cache_read when asked",
      sessionTokenTotal(tlines, includeCacheRead: false) == 100 + 20 + 3 + 50 + 10)
check("token total empty", sessionTokenTotal([]) == 0)

// --- pending fields parse + merge ---
let pend = Session(json: ["session_id": "p", "status": "waiting",
                          "pending_tool": "Bash", "pending_input": "npm run build"])
check("pending tool parsed", pend?.pendingTool == "Bash")
check("pending input parsed", pend?.pendingInput == "npm run build")
let mp = mergeSessions(native: [nsess("a", "waiting")],
                       hooks: ["a": Session(id: "a", cwd: "/a/a", status: .waiting,
                                            updatedAt: now, pendingTool: "Bash",
                                            pendingInput: "npm run build")], now: now)
check("merge carries pending", mp.first?.pendingInput == "npm run build")

// --- DesktopSession parsing ---
let d0 = DesktopSession(json: [
    "cliSessionId": "cs1", "cwd": "/Users/me/proj", "title": "dev - x",
    "lastActivityAt": now * 1000.0, "prNumber": 42, "prState": "OPEN", "isArchived": false
])
check("desktop parses", d0 != nil)
check("desktop id is cliSessionId", d0?.sessionId == "cs1")
check("desktop folder from cwd", d0?.folder == "proj")
check("desktop ms->seconds", d0?.updatedAt == now)
check("desktop pr parsed", d0?.prNumber == 42)
check("desktop activity shows PR", (d0?.activityText ?? "").contains("PR #42"))
check("desktop rejects archived", DesktopSession(json: ["cliSessionId": "x", "isArchived": true]) == nil)
check("desktop rejects no cliSessionId", DesktopSession(json: ["cwd": "/a"]) == nil)

// --- transcript tail / status inference ---
let toolUseLines: [[String: Any]] = [
    ["message": ["role": "user", "content": [["type": "text", "text": "hi"]]]],
    ["message": ["role": "assistant", "content": [["type": "tool_use", "name": "Bash"]]]],
]
let answeredLines: [[String: Any]] = toolUseLines + [
    ["message": ["role": "user", "content": [["type": "tool_result"]]]],
]
let askLines: [[String: Any]] = [
    ["message": ["role": "assistant", "content": [["type": "tool_use", "name": "AskUserQuestion"]]]],
]
check("tail detects pending tool name", transcriptPendingTool(toolUseLines) == "Bash")
check("tail clears after tool_result", transcriptPendingTool(answeredLines) == nil)
check("tail empty -> no pending", transcriptPendingTool([]) == nil)
check("tail surfaces user-blocking tool", transcriptPendingTool(askLines) == "AskUserQuestion")

check("fresh + executing tool -> running (not waiting)",
      inferDesktopStatus(pendingTool: "Bash", mtime: now - 5, now: now) == .running)
check("fresh + no pending -> running",
      inferDesktopStatus(pendingTool: nil, mtime: now - 5, now: now) == .running)
check("stale generic pending -> idle",
      inferDesktopStatus(pendingTool: "Bash", mtime: now - 200, now: now) == .idle)
check("stale AskUserQuestion -> still waiting (blocked on user)",
      inferDesktopStatus(pendingTool: "AskUserQuestion", mtime: now - 99999, now: now) == .waiting)
check("stale ExitPlanMode -> still waiting",
      inferDesktopStatus(pendingTool: "ExitPlanMode", mtime: now - 99999, now: now) == .waiting)

// --- mergeSessions with desktop ---
func dsess(_ id: String, _ st: Status, age: Double = 1) -> DesktopSession {
    DesktopSession(sessionId: id, cwd: "/a/\(id)", title: "t", status: st, updatedAt: now - age)
}
let md1 = mergeSessions(native: [], hooks: [:], desktop: [dsess("d1", .running)], now: now)
check("desktop running session included", md1.count == 1 && md1.first?.id == "d1")
let md2 = mergeSessions(native: [], hooks: [:], desktop: [dsess("d1", .idle)], now: now)
check("desktop idle dropped", md2.count == 0)
let md3 = mergeSessions(native: [], hooks: [:], desktop: [dsess("d1", .running, age: 999)], now: now)
check("desktop stale running dropped", md3.count == 0)
// A waiting (needs-input) desktop session stays visible no matter how long it
// has been quiet — that quiet is the session waiting for the user.
let md3w = mergeSessions(native: [], hooks: [:], desktop: [dsess("d1", .waiting, age: 99999)], now: now)
check("desktop stale waiting kept", md3w.count == 1 && md3w.first?.status == .waiting)
let md4 = mergeSessions(native: [nsess("dup", "busy")], hooks: [:],
                        desktop: [dsess("dup", .waiting)], now: now)
check("desktop de-duped against native", md4.count == 1 && md4.first?.status == .running)

// A native row marks itself as a desktop session via entrypoint; merge must not
// surface it as a native (idle, zero-age) row — the transcript-driven desktop
// pass owns it, and the native pid is carried onto that row for jump/liveness.
func ndesk(_ id: String, age: Double = 1) -> NativeSession {
    NativeSession(pid: 777, sessionId: id, cwd: "/a/\(id)", nativeStatus: "idle",
                  entrypoint: "claude-desktop", updatedAt: now - age)
}
let md5 = mergeSessions(native: [ndesk("dk")], hooks: [:], desktop: [], now: now)
check("native claude-desktop entry not surfaced as idle row", md5.isEmpty)
let md6 = mergeSessions(native: [ndesk("dk")], hooks: [:], desktop: [dsess("dk", .running)], now: now)
check("desktop session carries native pid", md6.count == 1 && md6.first?.pid == 777)
check("desktop session flagged isDesktop", md6.first?.isDesktop == true)
check("desktop status from transcript, not native idle", md6.first?.status == .running)
// A genuine CLI session is unaffected and is NOT flagged desktop.
let md7 = mergeSessions(native: [nsess("cli1", "busy")], hooks: [:], now: now)
check("cli session not flagged desktop", md7.first?.isDesktop == false)

// Desktop native + hook: hook drives status, native pid is carried, isDesktop=true.
// This is the path used by Claude Desktop Cowork sessions that DO run user hooks
// (their native entry has no busy/waiting, so the hook is the only live signal).
let md8 = mergeSessions(native: [ndesk("dk2")],
                        hooks: ["dk2": hsess("dk2", .running, age: 1)],
                        desktop: [], now: now)
check("desktop+hook: one row, native pid",
      md8.count == 1 && md8.first?.pid == 777)
check("desktop+hook: hook status overrides native idle",
      md8.first?.status == .running)
check("desktop+hook: flagged isDesktop",
      md8.first?.isDesktop == true)
check("desktop+hook running is trustedActive",
      md8.first?.trustedActive == true)
// Even when hook says idle, the live native pid means the row is worth showing —
// hook idle on a desktop entry means "done, awaiting input", not "gone".
let md9 = mergeSessions(native: [ndesk("dk3")],
                        hooks: ["dk3": hsess("dk3", .idle, age: 1)],
                        desktop: [], now: now)
check("desktop+idle hook still surfaces the live row",
      md9.count == 1 && md9.first?.status == .idle && md9.first?.pid == 777)

// Fresh-Desktop fallback: native claude-desktop entry, no hook, no transcript
// (so loadDesktop's desktop list omits it), but startedAt is within the last
// 5 minutes — surface as running so a brand-new conversation isn't invisible.
let mdFresh = mergeSessions(
    native: [NativeSession(pid: 888, sessionId: "dkFresh", cwd: "/a/dkFresh",
                            nativeStatus: "idle", entrypoint: "claude-desktop",
                            updatedAt: 0, startedAt: now - 30)],
    hooks: [:], desktop: [], now: now)
check("fresh desktop (no hook, no transcript) surfaces",
      mdFresh.count == 1 && mdFresh.first?.id == "dkFresh")
check("fresh desktop fallback status = running",
      mdFresh.first?.status == .running)
check("fresh desktop fallback flagged isDesktop",
      mdFresh.first?.isDesktop == true)
check("fresh desktop fallback is trustedActive",
      mdFresh.first?.trustedActive == true)
// An old startedAt (beyond 5min) without hook or transcript is dropped — that
// fallback is only for brand-new conversations the other paths haven't caught up to.
let mdOld = mergeSessions(
    native: [NativeSession(pid: 889, sessionId: "dkOld", cwd: "/a/dkOld",
                            nativeStatus: "idle", entrypoint: "claude-desktop",
                            updatedAt: 0, startedAt: now - 9999)],
    hooks: [:], desktop: [], now: now)
check("old desktop without hook/transcript dropped", mdOld.isEmpty)
// If the desktop scanner already surfaced the session, the fresh-fallback does
// not duplicate it.
let mdFreshDup = mergeSessions(
    native: [NativeSession(pid: 890, sessionId: "dkDup", cwd: "/a/dkDup",
                            nativeStatus: "idle", entrypoint: "claude-desktop",
                            updatedAt: 0, startedAt: now - 5)],
    hooks: [:], desktop: [dsess("dkDup", .running)], now: now)
check("fresh-fallback de-duped with desktop scanner row", mdFreshDup.count == 1)

// NativeSession parses startedAt (ms -> seconds), falls back to 0
let natWithStart = NativeSession(json: ["pid": 1, "sessionId": "x", "status": "busy",
                                         "startedAt": now * 1000.0])
check("native parses startedAt", natWithStart?.startedAt == now)
let natNoStart = NativeSession(json: ["pid": 1, "sessionId": "y", "status": "busy"])
check("native missing startedAt -> 0", natNoStart?.startedAt == 0)

// --- Functional / edge-case coverage added below ---

// Status.priority ordering should match the documented hierarchy
check("priority order error>waiting>running>idle",
      Status.error.priority > Status.waiting.priority
      && Status.waiting.priority > Status.running.priority
      && Status.running.priority > Status.idle.priority)
check("status labels distinct",
      Set([Status.running, .waiting, .error, .idle].map { $0.label }).count == 4)

// formatCount boundary behaviour
check("formatCount 0", formatCount(0) == "0")
check("formatCount 999", formatCount(999) == "999")
check("formatCount 1000 rolls over to K", formatCount(1_000) == "1.0K")
check("formatCount one_thousand_K rolls over to M (no 1000.0K)",
      formatCount(999_999) != "1000.0K")  // see filed bug B
check("formatCount handles negative small", formatCount(-5) == "-5")

// relativeAge boundaries (transitions are >=, so exactly 5/60/3600/86400 cross over)
check("ra 4s -> just now (under 5s)", relativeAge(now - 4, now: now) == "just now")
check("ra exactly 5s shows seconds", relativeAge(now - 5, now: now) == "5s ago")
check("ra exactly 60s shows minutes", relativeAge(now - 60, now: now) == "1m ago")
check("ra exactly 3600s shows hours", relativeAge(now - 3600, now: now) == "1h ago")
check("ra exactly 86400s shows days", relativeAge(now - 86400, now: now) == "1d ago")
check("ra future timestamp -> just now", relativeAge(now + 30, now: now) == "just now")

// Session.init? — an empty string for session_id should be rejected (a row with
// no id is unrenderable and cannot dedup against native/desktop entries). See bug C.
check("Session rejects empty session_id", Session(json: ["session_id": ""]) == nil)

// pid stored as Double (JSONSerialization emits Double for non-integers)
let sd = Session(json: ["session_id": "x", "pid": 4242.0])
check("Session pid from Double", sd?.pid == 4242)

// mergeSessions must carry hook pending fields onto a native-driven row.
let mp2 = mergeSessions(
    native: [NativeSession(pid: 1, sessionId: "x", cwd: "/a", nativeStatus: "busy", updatedAt: now)],
    hooks: ["x": Session(id: "x", status: .running, updatedAt: now,
                         pendingTool: "Bash", pendingInput: "rm -rf /")],
    now: now)
check("merge surfaces hook pendingTool over native", mp2.first?.pendingTool == "Bash")
check("merge surfaces hook pendingInput over native", mp2.first?.pendingInput == "rm -rf /")

// aggregateStatus must NOT decay a stale waiting session — a needs-input
// session represents a question that hasn't been answered yet, and the wait
// IS the silence. (Matches the desktop "stale waiting kept" rule.)
let staleWait = Session(id: "x", status: .waiting, updatedAt: now - 99999)
check("stale waiting persists in aggregate",
      aggregateStatus([staleWait], now: now) == .waiting)

// inferDesktopStatus boundary at exactly the liveness window (>=, not >):
check("inferDesktopStatus exactly at 90s -> idle",
      inferDesktopStatus(pendingTool: nil, mtime: now - runningLivenessWindow, now: now) == .idle)
check("inferDesktopStatus just under 90s -> running",
      inferDesktopStatus(pendingTool: nil, mtime: now - (runningLivenessWindow - 1), now: now) == .running)

// NativeSession with no updatedAt parses but defaults to 0.
let natNoUp = NativeSession(json: ["sessionId": "x", "pid": 1, "status": "busy"])
check("NativeSession missing updatedAt -> 0", natNoUp?.updatedAt == 0)

// transcript: the LAST assistant tool_use determines the pending tool.
let multi: [[String: Any]] = [
    ["message": ["role": "assistant", "content": [["type": "tool_use", "name": "Bash"]]]],
    ["message": ["role": "assistant", "content": [["type": "tool_use", "name": "Edit"]]]],
]
check("transcript: last assistant tool wins", transcriptPendingTool(multi) == "Edit")

// transcript: blocking tool inside a multi-tool turn takes precedence.
let mixed: [[String: Any]] = [
    ["message": ["role": "assistant", "content": [
        ["type": "text", "text": "thinking"],
        ["type": "tool_use", "name": "Bash"],
        ["type": "tool_use", "name": "AskUserQuestion"],
    ]]],
]
check("transcript: blocking tool wins within turn",
      transcriptPendingTool(mixed) == "AskUserQuestion")

// DesktopSession with empty cwd should still produce a non-empty folder/title
// so the row is renderable. See filed bug D.
let dEmpty = DesktopSession(json: ["cliSessionId": "abc-xyz", "cwd": "",
                                    "lastActivityAt": now * 1000.0])
check("DesktopSession empty-cwd folder non-empty", !(dEmpty?.folder.isEmpty ?? true))
check("DesktopSession empty-cwd title non-empty", !(dEmpty?.title.isEmpty ?? true))

// DesktopSession.activityText with no PR -> just "Desktop"
let dNoPr = DesktopSession(sessionId: "x", cwd: "/a/b", status: .running, updatedAt: now)
check("desktop activity no PR -> 'Desktop'", dNoPr.activityText == "Desktop")

// sessionTokenTotal ignores lines lacking message/usage and tolerates malformed entries
let mixedLines: [[String: Any]] = [
    ["foo": "bar"],
    ["message": "not a dict"],
    ["message": ["usage": "not a dict"]],
    ["message": ["usage": ["input_tokens": 7]]],
]
check("sessionTokenTotal robust to malformed entries", sessionTokenTotal(mixedLines) == 7)

// mergeSessions sort tiebreak: identical updatedAt — should not crash and should preserve both
let tie1 = mergeSessions(
    native: [NativeSession(pid: 1, sessionId: "a", cwd: "/a/a", nativeStatus: "busy", updatedAt: now),
             NativeSession(pid: 2, sessionId: "b", cwd: "/a/b", nativeStatus: "busy", updatedAt: now)],
    hooks: [:], now: now)
check("merge sort tie keeps both rows", tie1.count == 2)

// --- Dynamic Island: activeCount + islandFoldedLabel ---
// activeCount mirrors the aggregate rules (running needs to be recent;
// error needs to be within its 90s window).
let icSessions: [Session] = [
    Session(id: "r1", status: .running, updatedAt: now - 10),
    Session(id: "r2", status: .running, updatedAt: now - 200), // stale -> doesn't count
    Session(id: "w1", status: .waiting, updatedAt: now - 5000), // waiting never decays
    Session(id: "e1", status: .error, errorAt: now - 10, updatedAt: now - 10),
    Session(id: "e2", status: .error, errorAt: now - 200, updatedAt: now - 200), // stale -> doesn't count
    Session(id: "i1", status: .idle, updatedAt: now),
]
check("activeCount counts fresh running + waiting + fresh error",
      activeCount(icSessions, now: now) == 3)
check("activeCount empty -> 0", activeCount([], now: now) == 0)

// Stale error (>90s) decays out of aggregateStatus
let staleErr = Session(id: "e", status: .error, errorAt: now - 200, updatedAt: now - 200)
check("stale error decays in aggregate",
      aggregateStatus([staleErr], now: now) == .idle)

// islandFoldedLabel — empty → idle "Claude Dot"
let l0 = islandFoldedLabel(sessions: [], now: now)
check("idle label main", l0.main == "Claude Dot")
check("idle label kind", l0.kind == .idle)
check("idle label sub empty", l0.sub == "")

// Running session → "Running · <folder>" (privacy: never use title, which
// holds the user's prompt text)
let lr = islandFoldedLabel(sessions: [
    Session(id: "r", folder: "refactor-status", status: .running,
            title: "do something secret",  // must NOT leak into the label
            lastEvent: "Bash · npm run build", updatedAt: now - 5),
], now: now)
check("running label kind", lr.kind == .running)
check("running label main uses folder", lr.main == "Running · refactor-stat…")
check("running label sub uses lastEvent", lr.sub.contains("Bash"))
check("running label never leaks title (prompt)", !lr.main.contains("secret") && !lr.sub.contains("secret"))

// Waiting beats running and uses accent
let lw = islandFoldedLabel(sessions: [
    Session(id: "r", folder: "x", status: .running, updatedAt: now - 5),
    Session(id: "w", folder: "sample-api", status: .waiting,
            updatedAt: now - 2, pendingTool: "Bash", pendingInput: "npm test --watch"),
], now: now)
check("waiting wins over running", lw.kind == .waiting)
check("waiting main = Awaiting · <tool>", lw.main == "Awaiting · Bash")
check("waiting sub = pending_input", lw.sub == "npm test --watch")

// Error beats waiting (and only counts within the 90s window)
let le = islandFoldedLabel(sessions: [
    Session(id: "w", status: .waiting, updatedAt: now - 2, pendingTool: "Bash"),
    Session(id: "e", folder: "release-tools", status: .error,
            lastError: "permission denied", errorAt: now - 10,
            updatedAt: now - 10, pendingTool: "Edit"),
], now: now)
check("error wins overall", le.kind == .error)
check("error main = Error · <tool>", le.main == "Error · Edit")
check("error sub = last_error", le.sub == "permission denied")

// Aged-out error: 91s old → no longer error → waiting wins
let leStale = islandFoldedLabel(sessions: [
    Session(id: "w", status: .waiting, updatedAt: now - 2, pendingTool: "Bash"),
    Session(id: "e", status: .error, lastError: "old",
            errorAt: now - 100, updatedAt: now - 100, pendingTool: "Edit"),
], now: now)
check("aged-out error yields to waiting", leStale.kind == .waiting)

// islandTruncate length & ellipsis
check("truncate keeps short", islandTruncate("short", 12) == "short")
check("truncate adds ellipsis when long",
      islandTruncate("0123456789ABCD", 8) == "0123456…")
check("truncate result length ≤ n",
      islandTruncate("0123456789ABCD", 8).count <= 8)

// Variant routing: AskUserQuestion → question, regular tool → approval
check("variant for AskUserQuestion -> question",
      islandVariantFor(pendingTool: "AskUserQuestion") == .question)
check("variant for ExitPlanMode -> question",
      islandVariantFor(pendingTool: "ExitPlanMode") == .question)
check("variant for Bash -> approval",
      islandVariantFor(pendingTool: "Bash") == .approval)
check("variant for nil tool -> approval",
      islandVariantFor(pendingTool: nil) == .approval)

// islandFocusSession picks the freshest of the relevant class
let waiters = [
    Session(id: "old", status: .waiting, updatedAt: now - 50, pendingTool: "Bash"),
    Session(id: "new", status: .waiting, updatedAt: now - 1,  pendingTool: "Edit"),
]
check("focus picks freshest waiting",
      islandFocusSession(waiters, aggregate: .waiting, now: now)?.id == "new")

print("")
if failures > 0 { print("FAILED: \(failures)"); exit(1) }
print("ALL PASSED")
