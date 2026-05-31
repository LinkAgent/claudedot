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
check("stale error still shows (attention persists)",
      aggregateStatus([sess(.error, age: 100000)], now: now) == .error)

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

print("")
if failures > 0 { print("FAILED: \(failures)"); exit(1) }
print("ALL PASSED")
