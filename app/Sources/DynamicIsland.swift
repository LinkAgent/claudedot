// Dynamic Island — a floating black pill that sits INSIDE the menu bar (2pt
// gap top + bottom within the 32pt menu-bar height) and mirrors the live
// aggregate session state. It wraps the MacBook notch: the lead segment shows
// to the LEFT of the notch, the trail segment to the RIGHT, and the empty
// notch-core in the middle is overlapped by the physical cutout. The same
// shape & math run on non-notch Macs — the core is just a black gap in the
// middle of the pill (visually a wider menu-bar capsule).
//
// Surface model (§4 of design/dynamic-island.html v0.3):
//
//   layout: closed | opened       × variant: sessionList | approval | question | completion
//
// closed = lead (22×22 owl) + notch-core (180pt empty) + trail (count + word).
// Word is one of "Running" / "Awaiting" / "Error". idle hides trail entirely.
// Hovering for ≥180ms opens to `sessionList` (480pt fixed width, drawer hangs
// below the head into the content area). Hook events route to the card
// variants:
//   • a session entering .waiting    → approval (or question, for AskUserQuestion)
//   • a session completing           → completion
// Cards auto-collapse after 12s / 12s / 6s. Pointer enter+leave on a card
// collapses immediately. Dedupe: same (variant, session) re-trigger suppressed
// for 30s (§6).
//
// Coexists with the menu-bar owl (both update from the same `refresh()` tick
// in AppDelegate). Default ON, persisted in UserDefaults.showDynamicIsland.
// Toggle via the popover footer.
//
// Diagnostic dump: CLAUDEDOT_DEBUG_ISLAND=1 logs screen frame, safe-area
// insets, and computed panel rect to stderr on every applyFrame.

import AppKit

// MARK: - Surface model

enum IslandLayout: Equatable { case closed, opened }

enum IslandCardVariant: Equatable {
    case sessionList
    case approval(sessionId: String)
    case question(sessionId: String)
    case completion(sessionId: String)

    var priority: Int {
        switch self {
        case .approval:    return 4
        case .question:    return 3
        case .completion:  return 2
        case .sessionList: return 1
        }
    }
}

// Geometry constants — pure so the snapshot renderer and unit tests can use
// them without standing up an NSPanel. v0.3 contract (§2.0 + §7 + §9 of the
// spec).
//
// §2.0 is a HARD contract:
//   - Total height = 28pt (in 32pt menu bar with 2pt air gaps top + bottom).
//   - Bottom edge MUST NOT exceed the menu bar bottom by even one pixel —
//     the island cannot occlude content below the menu bar.
//   - 4 corners full rounded, radius = 14pt (true pill, not "flat top + rounded
//     bottom wrap"). It's a FLOATING capsule, not a screen-top extension.
//
// The pill horizontally wraps the notch via 3 segments: lead (owl) sits to
// the LEFT of the notch, notch-core (180pt empty) is OVERLAID by the physical
// notch (it appears between the lead and the trail because the notch eats
// those pixels), trail (count + word) sits to the RIGHT of the notch.
// On a non-notch Mac the notch-core is just a wider middle of the pill (§9).
struct IslandGeom {
    // §2.0 (2026-06 update): pill height = NSScreen.menuBarHeight − 2 (1pt
    // gap top + 1pt gap bottom). HARDCODED 28pt was a bug — 14"/16" MBP menu
    // bar is ~38pt so the pill read as visibly shorter than neighboring
    // status items (battery, clock, etc.); M1 Air / Intel Mac menu bar is
    // ~24pt so the pill spilled past it. islandHeight is now threaded through
    // foldedSize/expandedSize/origin/layout, computed from
    // NSScreen.islandHeight per tick.
    static let fallbackIslandH: CGFloat = 28   // used only when no screen present
    static let airGap: CGFloat = 1   // 1pt top + 1pt bottom = pillH = menuBar − 2

    // Lead segment is asymmetric per §2.0 (2026-06): the pill is a full
    // capsule whose left arc curves inward up to islandHeight/2 from the edge.
    // With symmetric 12pt padding the owl visually pinned against the arc and
    // read as off-center. 16pt L + 10pt R restores perceived centering —
    // the 6pt delta compensates for the curvature. Right padding stays small
    // because the right side abuts the notch-core (a straight edge).
    static let owlSize: CGFloat = 22
    static let leadLPad: CGFloat = 16
    static let leadRPad: CGFloat = 10
    static let leadW: CGFloat = leadLPad + owlSize + leadRPad   // = 48
    // Fallback notch-core width when the screen API gives us nothing useful.
    // Picked at 220 so a non-notch Mac still gets a pill wider than the
    // widest 16" MBP notch (~225pt) — keeps the visual & functional parity
    // §9 calls for, no narrow stub. Per spec §2.0 (updated 2026-06): "fallback
    // 到 220pt 而非 180pt". The HARDCODED 180 was a bug — 14" MBP notch is
    // ~205pt and 16" Max is ~225pt, both wider, so the trail's first token
    // (the count digit) fell inside the physical notch and got clipped.
    static let coreFallback: CGFloat = 220
    // Left/right safety buffer around the notch — 12pt on each side so the
    // trail (and the lead) don't crash into the notch's soft edge gradient.
    static let coreSafetyMargin: CGFloat = 24
    // Trail breathing room: 18pt between the notch-core and the count's left
    // edge so the digit isn't pressed up against the notch. 16pt from the
    // word's right edge to the pill's rounded right end so the pill's curve
    // doesn't clip the last letter.
    static let trailLGap: CGFloat = 18
    static let trailRPad: CGFloat = 16
    // §2.0 (2026-06): closedRadius is height/2 at use-site, NOT a constant.
    // openedRadius stays fixed at 18 — the drawer can be 150pt tall, so
    // using bounds.height/2 would render a balloon, not a card.
    static let openedRadius: CGFloat = 18

    // Expanded — §2.0 / §7: head reuses the closed pill's 3-segment strip
    // at the same height (= live islandHeight); drawer hangs below.
    static let expandedW: CGFloat = 480
    static let listVPad: CGFloat = 6
    static let footH: CGFloat = 24
    static let rowH: CGFloat = 38
    static let cardVPad: CGFloat = 10
    static let approvalH: CGFloat = 124
    static let questionH: CGFloat = 168
    static let completionH: CGFloat = 116
    static let maxRows: Int = 5

    // Measure the trail at render-time font sizes (serif 17 count + SF 11.5
    // word + 5pt gap) so the pill width matches what actually draws.
    // trailLGap on the left keeps the count clear of the notch-core boundary;
    // trailRPad on the right keeps the word clear of the pill's rounded end.
    static func trailWidth(count: Int, word: String) -> CGFloat {
        guard !word.isEmpty, count > 0 else { return 0 }
        let countText = count >= 100 ? "99+" : "\(count)"
        let countFont: NSFont = {
            let b = NSFont.systemFont(ofSize: 17, weight: .medium)
            return b.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 17) } ?? b
        }()
        let wordFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let cw = ceil(NSAttributedString(string: countText, attributes: [.font: countFont]).size().width)
        let ww = ceil(NSAttributedString(string: word, attributes: [.font: wordFont]).size().width)
        return trailLGap + cw + 5 + ww + trailRPad
    }

    // Both `islandHeight` and `notchCoreWidth` are resolved per-screen each
    // tick — they depend on the display the pill is currently shown on, and
    // a didChangeScreenParameters notification can swap that under us.
    static func foldedSize(islandHeight: CGFloat, notchCoreWidth: CGFloat,
                            count: Int, word: String) -> NSSize {
        NSSize(width: leadW + notchCoreWidth + trailWidth(count: count, word: word),
               height: islandHeight)
    }

    static func expandedSize(islandHeight: CGFloat, notchCoreWidth: CGFloat,
                              variant: IslandCardVariant, rowCount: Int) -> NSSize {
        let body: CGFloat
        switch variant {
        case .sessionList:
            let rows = max(1, min(rowCount, maxRows))
            let overflow: CGFloat = rowCount > maxRows ? rowH * 0.7 : 0
            body = listVPad * 2 + CGFloat(rows) * rowH + overflow + footH
        case .approval:    body = approvalH
        case .question:    body = questionH
        case .completion:  body = completionH
        }
        // Head reuses the closed pill's 3-segment layout at islandHeight;
        // expandedW is fixed per spec §7. notchCoreWidth flows in via the
        // host so head trail visually aligns with the closed pill below.
        let _ = notchCoreWidth
        return NSSize(width: expandedW, height: islandHeight + body)
    }

    // Origin: pill sits 1pt below screen top (1pt air gap), bottom lands 1pt
    // above the menu bar bottom — the "上下各 1pt 气口" contract from §2.0.
    static func origin(on screenFrame: NSRect, size: NSSize) -> NSPoint {
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.maxY - airGap - size.height
        return NSPoint(x: x, y: y)
    }
}

// Dark-only palette (the island is always on black to blend with the notch).
enum IslandPalette {
    static let bg     = NSColor(srgbRed: 10/255,  green: 10/255,  blue: 10/255,  alpha: 1) // #0A0A0A
    static let ink    = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 1)
    static let ink2   = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.62)
    static let ink3   = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.36)
    static let accent = NSColor(srgbRed: 233/255, green: 105/255, blue:  69/255, alpha: 1)
    static let green  = NSColor(srgbRed: 122/255, green: 155/255, blue: 118/255, alpha: 1)
    static let red    = NSColor(srgbRed: 210/255, green: 122/255, blue: 102/255, alpha: 1)
    static let border = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.10)

    static func dotColor(for kind: IslandLabelKind) -> NSColor {
        switch kind {
        case .running: return ink3
        case .waiting: return accent
        case .error:   return red
        case .idle:    return NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.18)
        }
    }
}

// MARK: - Trail text helpers

// The single word shown in the closed trail per §3. Idle → empty (trail
// segment hides entirely, pill narrows).
func islandStatusWord(_ status: Status) -> String {
    switch status {
    case .running: return "Running"
    case .waiting: return "Awaiting"
    case .error:   return "Error"
    case .idle:    return ""
    }
}

// Color for the closed trail's status word per §5: waiting = accent (the
// island's strongest signal), error = red, running = ink, idle = ink-3.
func islandWordColor(_ status: Status) -> NSColor {
    switch status {
    case .running: return IslandPalette.ink
    case .waiting: return IslandPalette.accent
    case .error:   return IslandPalette.red
    case .idle:    return IslandPalette.ink3
    }
}

// Bridge between Status (Model.swift) and IslandLabelKind (used by the owl /
// dot helpers in Model.swift).
private func islandKind(for status: Status) -> IslandLabelKind {
    switch status {
    case .running: return .running
    case .waiting: return .waiting
    case .error:   return .error
    case .idle:    return .idle
    }
}

// MARK: - Controller

final class DynamicIslandController {
    static let defaultsKey = "showDynamicIsland"

    private var panel: NSPanel?
    private var host: IslandHostView?
    private(set) var layout: IslandLayout = .closed
    private(set) var variant: IslandCardVariant = .sessionList
    // Timers
    private var hoverOpenWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var cardExpireWork: DispatchWorkItem?
    private var screenObs: NSObjectProtocol?
    private var spaceObs: NSObjectProtocol?

    // Per-session debouncing: card variant → (sessionId → last-shown epoch).
    private var lastCardShown: [String: Double] = [:]
    private let cardDedupeWindow: Double = 30

    private var prevStatus: [String: Status] = [:]
    private var prevPendingTool: [String: String?] = [:]

    private var sawNotchHardware: Bool = false

    private var lastSessions: [SessionVM] = []
    private let debug: Bool = ProcessInfo.processInfo.environment["CLAUDEDOT_DEBUG_ISLAND"] != nil

    var onJump: (Int32?, String, Bool) -> Void = { _, _, _ in }
    var onOpenPopover: () -> Void = {}

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            if newValue {
                ensurePanel()
                pushUpdate(animated: false)
            } else {
                panel?.orderOut(nil)
            }
        }
    }

    init() {
        screenObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.pushUpdate(animated: false) }
        spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.pushUpdate(animated: false) }
    }

    deinit {
        if let o = screenObs { NotificationCenter.default.removeObserver(o) }
        if let o = spaceObs { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    // Called by AppDelegate.refresh() on every 1.5s tick.
    func update(sessions: [SessionVM], theme: Theme) {
        let prev = lastSessions
        lastSessions = sessions
        guard enabled else { return }
        detectTransitions(prev: prev, curr: sessions)
        pushUpdate(animated: false)
    }

    // Compare prior vs. current sessions and auto-expand to a card surface on
    // newly-arrived events. Debounced per (session, variant) within 30s.
    private func detectTransitions(prev: [SessionVM], curr: [SessionVM]) {
        let now = Date().timeIntervalSince1970
        var newPrevStatus: [String: Status] = [:]
        var newPrevTool: [String: String?] = [:]
        let prevById = Dictionary(uniqueKeysWithValues: prev.map { ($0.s.id, $0.s) })
        var bestTrigger: IslandCardVariant?

        for vm in curr {
            let s = vm.s
            let was = prevStatus[s.id] ?? (prevById[s.id]?.status ?? .idle)
            let wasTool = prevPendingTool[s.id] ?? prevById[s.id]?.pendingTool
            newPrevStatus[s.id] = s.status
            newPrevTool[s.id] = s.pendingTool

            // idle/running → waiting: a permission/question card just arrived
            if s.status == .waiting && was != .waiting {
                let v: IslandCardVariant = islandVariantFor(pendingTool: s.pendingTool) == .question
                    ? .question(sessionId: s.id) : .approval(sessionId: s.id)
                if shouldShow(v, now: now) {
                    bestTrigger = bestOf(bestTrigger, v)
                }
            }
            else if s.status == .waiting && s.pendingTool != nil && s.pendingTool != (wasTool ?? nil) {
                let v: IslandCardVariant = islandVariantFor(pendingTool: s.pendingTool) == .question
                    ? .question(sessionId: s.id) : .approval(sessionId: s.id)
                if shouldShow(v, now: now) {
                    bestTrigger = bestOf(bestTrigger, v)
                }
            }

            // Non-idle → idle: a session just completed
            if was != .idle && s.status == .idle {
                let v: IslandCardVariant = .completion(sessionId: s.id)
                if shouldShow(v, now: now) {
                    bestTrigger = bestOf(bestTrigger, v)
                }
            }
        }

        prevStatus = newPrevStatus
        prevPendingTool = newPrevTool

        if let v = bestTrigger {
            present(variant: v)
            stamp(v, at: now)
        }
    }

    private func shouldShow(_ v: IslandCardVariant, now: Double) -> Bool {
        guard let key = dedupeKey(v) else { return true }
        if let last = lastCardShown[key], now - last < cardDedupeWindow { return false }
        return true
    }
    private func stamp(_ v: IslandCardVariant, at now: Double) {
        if let k = dedupeKey(v) { lastCardShown[k] = now }
    }
    private func dedupeKey(_ v: IslandCardVariant) -> String? {
        switch v {
        case .sessionList:           return nil
        case .approval(let id):      return "approval:\(id)"
        case .question(let id):      return "question:\(id)"
        case .completion(let id):    return "completion:\(id)"
        }
    }
    private func bestOf(_ a: IslandCardVariant?, _ b: IslandCardVariant) -> IslandCardVariant {
        guard let a = a else { return b }
        return b.priority > a.priority ? b : a
    }

    private func pushUpdate(animated: Bool) {
        guard enabled else { return }
        let target = resolveTarget()
        switch target {
        case .hidden:
            panel?.orderOut(nil)
            log("hidden")
        case .visible(let screen, let hadNotch):
            ensurePanel()
            if hadNotch { sawNotchHardware = true }
            // Set live geometry BEFORE host.update so the first frame's
            // inner layout (notch-core width, head height, corner radius)
            // uses the right values on this screen.
            host?.notchCoreWidth = screen.islandNotchCoreWidth
            host?.islandHeight = screen.islandHeight
            host?.update(sessions: lastSessions, layout: layout, variant: variant)
            applyFrame(on: screen, animated: animated)
            if panel?.isVisible == false { panel?.orderFrontRegardless() }
        }
    }

    private enum Target {
        case hidden
        case visible(NSScreen, hasNotch: Bool)
    }

    // Screen selection per §9: prefer the built-in notch screen, NEVER use
    // NSScreen.main (it follows the key window, can be the external display).
    //   1. safeAreaInsets.top > 0       — built-in MBP with notch
    //   2. auxiliaryTopLeftArea present — built-in MBP, alternative API
    //   3. NSScreen.screens.first       — single-screen Mac fallback
    private func resolveTarget() -> Target {
        if #available(macOS 12.0, *) {
            if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
                return .visible(notched, hasNotch: true)
            }
            if let aux = NSScreen.screens.first(where: {
                ($0.auxiliaryTopLeftArea?.width ?? 0) > 0 || ($0.auxiliaryTopRightArea?.width ?? 0) > 0
            }) {
                return .visible(aux, hasNotch: true)
            }
        }
        if sawNotchHardware { return .hidden }
        guard let first = NSScreen.screens.first else { return .hidden }
        return .visible(first, hasNotch: false)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                            width: IslandGeom.leadW + IslandGeom.coreFallback + 80,
                                            height: IslandGeom.fallbackIslandH),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.becomesKeyOnlyIfNeeded = true
        let h = IslandHostView(frame: NSRect(x: 0, y: 0,
                                              width: IslandGeom.leadW + IslandGeom.coreFallback + 80,
                                              height: IslandGeom.fallbackIslandH))
        h.controller = self
        p.contentView = h
        panel = p
        host = h
    }

    // MARK: - State transitions

    func setLayout(_ l: IslandLayout, variant v: IslandCardVariant = .sessionList) {
        if l == .closed { hoverOpenWork?.cancel(); hoverOpenWork = nil }
        let changed = (l != layout) || (v != variant)
        layout = l
        variant = v
        guard changed else { return }
        guard case .visible(let screen, _) = resolveTarget() else { return }
        host?.notchCoreWidth = screen.islandNotchCoreWidth
        host?.islandHeight = screen.islandHeight
        host?.update(sessions: lastSessions, layout: l, variant: v)
        applyFrame(on: screen, animated: true)
    }

    // Auto-expand to a card. Schedules its expiration timer per §6.
    func present(variant v: IslandCardVariant) {
        cardExpireWork?.cancel()
        let delay: TimeInterval
        switch v {
        case .sessionList:  delay = 0
        case .approval:     delay = 12
        case .question:     delay = 12
        case .completion:   delay = 6
        }
        setLayout(.opened, variant: v)
        if delay > 0 {
            let w = DispatchWorkItem { [weak self] in self?.setLayout(.closed) }
            cardExpireWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        }
    }

    // Hover lifecycle from the host view.
    func hoverEntered() {
        cancelCollapse()
        hoverOpenWork?.cancel()
        if case .opened = layout, case .sessionList = variant { return }
        if case .opened = layout, variant.priority > IslandCardVariant.sessionList.priority { return }
        let w = DispatchWorkItem { [weak self] in self?.setLayout(.opened, variant: .sessionList) }
        hoverOpenWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }
    func hoverExited() {
        hoverOpenWork?.cancel(); hoverOpenWork = nil
        let delay: TimeInterval
        switch variant {
        case .sessionList: delay = 0.4
        case .approval, .question, .completion: delay = 0
        }
        scheduleCollapse(delay: delay)
    }
    func scheduleCollapse(delay: TimeInterval = 0.4) {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.setLayout(.closed) }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    func cancelCollapse() { collapseWork?.cancel(); collapseWork = nil }

    private func applyFrame(on screen: NSScreen, animated: Bool) {
        guard let panel = panel else { return }
        let core = screen.islandNotchCoreWidth
        let h = screen.islandHeight
        let size = sizeForState(islandHeight: h, notchCoreWidth: core)
        let origin = IslandGeom.origin(on: screen.frame, size: size)
        let r = NSRect(origin: origin, size: size)
        log("applyFrame layout=\(layout) variant=\(variant) screen=\(screen.frame) menuBar=\(screen.menuBarHeight) pillH=\(h) notchCore=\(core) panel=\(r)")
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(r, display: true)
            }
        } else {
            panel.setFrame(r, display: true)
        }
    }

    private func sizeForState(islandHeight: CGFloat, notchCoreWidth: CGFloat) -> NSSize {
        switch layout {
        case .closed:
            let agg = aggregateStatus(lastSessions.map { $0.s })
            let count = activeCount(lastSessions.map { $0.s })
            return IslandGeom.foldedSize(islandHeight: islandHeight,
                                          notchCoreWidth: notchCoreWidth,
                                          count: count, word: islandStatusWord(agg))
        case .opened:
            let nonIdle = activeCount(lastSessions.map { $0.s })
            return IslandGeom.expandedSize(islandHeight: islandHeight,
                                            notchCoreWidth: notchCoreWidth,
                                            variant: variant, rowCount: nonIdle)
        }
    }

    private func log(_ msg: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[island] \(msg)\n".utf8))
    }
}

// MARK: - Host view

// The panel's content view. Paints the black pill, hosts the inner content,
// owns the hover tracking that drives expand/collapse.
final class IslandHostView: NSView {
    weak var controller: DynamicIslandController?
    private var tracking: NSTrackingArea?
    private var inner: NSView?
    private var bgLayer: CALayer?
    private var currentLayout: IslandLayout = .closed
    private var currentVariant: IslandCardVariant = .sessionList
    private var lastSig: String = ""
    // Live notch-core width — set by the controller from the resolved screen.
    // makeCoreSegment reads this so the empty middle of the pill matches the
    // physical notch on whichever display we're currently shown on.
    var notchCoreWidth: CGFloat = IslandGeom.coreFallback + IslandGeom.coreSafetyMargin {
        didSet { if notchCoreWidth != oldValue { lastSig = ""; needsLayout = true } }
    }
    // Live island (pill / head) height — set by the controller from the
    // resolved screen's menu-bar height. Drives both the closed pill's full
    // height and the expanded panel's head strip. Also drives the corner
    // radius (= islandHeight/2 for closed) so any height yields a full pill.
    var islandHeight: CGFloat = IslandGeom.fallbackIslandH {
        didSet { if islandHeight != oldValue { lastSig = ""; needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        let bg = CALayer()
        bg.backgroundColor = IslandPalette.bg.cgColor
        bg.masksToBounds = true
        layer?.addSublayer(bg)
        bgLayer = bg
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    func update(sessions: [SessionVM], layout: IslandLayout, variant: IslandCardVariant) {
        currentLayout = layout
        currentVariant = variant
        let sig: String = {
            switch layout {
            case .closed:
                let agg = aggregateStatus(sessions.map { $0.s })
                let n = activeCount(sessions.map { $0.s })
                return "C|\(agg.rawValue)|\(n)"
            case .opened:
                let rows = sessions.filter { $0.s.status != .idle }.prefix(IslandGeom.maxRows)
                    .map { "\($0.s.id):\($0.s.status.rawValue):\($0.s.pendingTool ?? ""):\($0.tokens)" }
                    .joined(separator: "|")
                return "O|\(variant)|\(rows)"
            }
        }()
        if sig == lastSig { return }
        lastSig = sig

        inner?.removeFromSuperview()
        let v: NSView
        switch layout {
        case .closed:
            v = makeFolded(sessions)
        case .opened:
            switch variant {
            case .sessionList:           v = makeSessionList(sessions)
            case .approval(let id):      v = makeApprovalCard(sessions, sessionId: id)
            case .question(let id):      v = makeQuestionCard(sessions, sessionId: id)
            case .completion(let id):    v = makeCompletionCard(sessions, sessionId: id)
            }
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        inner = v
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let bg = bgLayer else { return }
        bg.frame = bounds
        // Closed: full pill, radius = height/2 (works for ANY menu-bar
        // height — 14"/16" MBP ~38pt → 18pt radius; M1 Air ~24pt → 11pt
        // radius; per §2.0, NEVER hardcode 14pt).
        // Opened: fixed 18pt — the panel can be 150pt+ tall, so bounds/2
        // would render a balloon.
        bg.cornerRadius = currentLayout == .closed
            ? islandHeight / 2
            : IslandGeom.openedRadius
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) { controller?.hoverEntered() }
    override func mouseExited(with event: NSEvent)  { controller?.hoverExited() }

    // MARK: - Folded — 3-segment lead + core + trail

    private func makeFolded(_ sessions: [SessionVM]) -> NSView {
        let agg = aggregateStatus(sessions.map { $0.s })
        let count = activeCount(sessions.map { $0.s })
        let word = islandStatusWord(agg)

        let stack = NSStackView(views: [
            makeLeadSegment(for: agg),
            makeCoreSegment(),
            makeTrailSegment(count: count, word: word, status: agg),
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // Lead = 22×22 owl with asymmetric 16pt L / 10pt R padding (§2.0,
    // 2026-06) — the 6pt extra on the left visually re-centers the owl past
    // the pill's left arc.
    private func makeLeadSegment(for status: Status) -> NSView {
        let kind = islandKind(for: status)
        let owl = makeOwl(for: kind, size: IslandGeom.owlSize)
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(owl)
        NSLayoutConstraint.activate([
            owl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: IslandGeom.leadLPad),
            owl.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            wrap.widthAnchor.constraint(equalToConstant: IslandGeom.leadW),
        ])
        return wrap
    }

    // Notch-core: an empty 180pt-wide black gap that the hardware notch sits
    // inside on a notch Mac (the notch eats this segment), and on a non-notch
    // Mac is just a wider middle of the pill (visually a single capsule).
    private func makeCoreSegment() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        // Live notch-core width (set by the controller per current screen).
        // Includes the 12pt-per-side safety margin around the physical notch.
        v.widthAnchor.constraint(equalToConstant: notchCoreWidth).isActive = true
        return v
    }

    // Trail = `{count} {Word}` — Newsreader 14pt count, SF 11.5pt word.
    // Idle (word == "") returns a 0-width view so the pill collapses to
    // lead + core only.
    private func makeTrailSegment(count: Int, word: String, status: Status) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        if word.isEmpty || count == 0 {
            wrap.widthAnchor.constraint(equalToConstant: 0).isActive = true
            return wrap
        }
        let countText = count >= 100 ? "99+" : "\(count)"
        let countLabel = NSTextField(labelWithString: countText)
        // Mock CSS uses 19px; spec text §7 says 14pt. 17pt is the readable
        // middle that still clears the 28pt pill top with .centerY alignment.
        countLabel.font = serif(17, .medium)
        countLabel.textColor = IslandPalette.ink
        countLabel.drawsBackground = false; countLabel.isBordered = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let wordLabel = NSTextField(labelWithString: word)
        wordLabel.font = ui(11.5, .medium)
        wordLabel.textColor = islandWordColor(status)
        wordLabel.drawsBackground = false; wordLabel.isBordered = false
        wordLabel.translatesAutoresizingMaskIntoConstraints = false
        wordLabel.setContentHuggingPriority(.required, for: .horizontal)

        let hs = NSStackView(views: [countLabel, wordLabel])
        hs.orientation = .horizontal
        // centerY (not lastBaseline) — lastBaseline puts the BOTTOMS of both
        // glyphs at the strip's vertical center, which then sends the serif
        // count's ascender above the pill's top edge and gets clipped.
        hs.alignment = .centerY
        hs.spacing = 5
        hs.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(hs)
        NSLayoutConstraint.activate([
            hs.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -IslandGeom.trailRPad),
            hs.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            hs.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor, constant: 6),
        ])
        return wrap
    }

    // MARK: - Opened head (head + drawer)

    // The expanded head reuses the 28pt 3-segment pill shape; the only thing
    // that differs from `makeFolded` is the trail's content (a cap-lbl
    // contextual phrase instead of the single word).
    private func makeOpenedHead(status: Status, count: Int, cap: String) -> NSView {
        let stack = NSStackView(views: [
            makeLeadSegment(for: status),
            makeCoreSegment(),
            makeHeadTrail(count: count, cap: cap, status: status),
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        // Faint divider below the head so the drawer reads as a separate
        // region. Stays inside the rounded pill — no surface intersection.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = IslandPalette.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(divider)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrap.topAnchor),
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: islandHeight),
            divider.topAnchor.constraint(equalTo: stack.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            divider.heightAnchor.constraint(equalToConstant: 0.5),
            divider.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            wrap.heightAnchor.constraint(equalToConstant: islandHeight),
        ])
        return wrap
    }

    private func makeHeadTrail(count: Int, cap: String, status: Status) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: count > 0 ? "\(count)" : "")
        countLabel.font = serif(14, .medium)
        countLabel.textColor = IslandPalette.ink
        countLabel.drawsBackground = false; countLabel.isBordered = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let capLabel = NSTextField(labelWithString: cap.uppercased())
        let attr = NSAttributedString(string: cap.uppercased(), attributes: [
            .font: ui(9.5, .semibold),
            .foregroundColor: IslandPalette.ink3,
            .kern: 1.3,
        ])
        capLabel.attributedStringValue = attr
        capLabel.drawsBackground = false; capLabel.isBordered = false
        capLabel.lineBreakMode = .byTruncatingTail
        capLabel.translatesAutoresizingMaskIntoConstraints = false

        let hs = NSStackView(views: [countLabel, capLabel])
        hs.orientation = .horizontal
        hs.alignment = .centerY
        hs.spacing = 8
        hs.translatesAutoresizingMaskIntoConstraints = false

        wrap.addSubview(hs)
        NSLayoutConstraint.activate([
            hs.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -IslandGeom.trailRPad),
            hs.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            hs.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor, constant: 6),
        ])
        _ = status
        return wrap
    }

    // MARK: - Expanded sessionList drawer

    private func makeSessionList(_ sessions: [SessionVM]) -> NSView {
        let nonIdle = sessions.filter { $0.s.status != .idle }
        let waiting = nonIdle.filter { $0.s.status == .waiting }.count
        let agg = aggregateStatus(sessions.map { $0.s })

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let cap = waiting > 0
            ? "active · \(waiting) awaiting"
            : "active session\(nonIdle.count == 1 ? "" : "s")"
        let head = makeOpenedHead(status: agg, count: nonIdle.count, cap: cap)
        root.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 1
        list.translatesAutoresizingMaskIntoConstraints = false
        list.edgeInsets = NSEdgeInsets(top: IslandGeom.listVPad, left: 6,
                                        bottom: IslandGeom.listVPad, right: 6)

        let visible = Array(nonIdle.prefix(IslandGeom.maxRows))
        let overflowCount = nonIdle.count - visible.count
        let folderCounts = Dictionary(grouping: visible, by: { $0.s.folder }).mapValues { $0.count }

        for vm in visible {
            let dup = (folderCounts[vm.s.folder] ?? 0) > 1
            let row = makeListRow(vm, disambiguate: dup)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
        }
        if overflowCount > 0 {
            let more = makeOverflowRow(count: overflowCount)
            list.addArrangedSubview(more)
            more.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
        }
        if visible.isEmpty {
            let empty = NSTextField(labelWithString: "No active sessions")
            empty.font = ui(11.5)
            empty.textColor = IslandPalette.ink3
            empty.drawsBackground = false; empty.isBordered = false
            empty.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                empty.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                wrap.heightAnchor.constraint(equalToConstant: IslandGeom.rowH),
            ])
            list.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
        }
        root.addArrangedSubview(list)
        list.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let foot = makeFooter(left: "Click a row to jump", right: "open popover")
        root.addArrangedSubview(foot)
        foot.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        return root
    }

    private func makeListRow(_ vm: SessionVM, disambiguate: Bool) -> NSView {
        let s = vm.s
        let row = ClickRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: IslandGeom.rowH).isActive = true
        row.onClick = { [weak self] in self?.controller?.onJump(s.pid, s.cwd, s.isDesktop) }

        let kind = islandKind(for: s.status)
        let dot = staticDot(color: IslandPalette.dotColor(for: kind), diameter: 7,
                             halo: IslandPalette.dotColor(for: kind).withAlphaComponent(0.18))

        let title = NSTextField(labelWithString: s.folder)
        title.font = serif(13.5, .medium)
        title.textColor = IslandPalette.ink
        title.lineBreakMode = .byTruncatingTail
        title.drawsBackground = false; title.isBordered = false
        title.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSMutableAttributedString()
        let boldAttrs: [NSAttributedString.Key: Any] = [
            .font: ui(10.5, .medium), .foregroundColor: IslandPalette.ink2,
        ]
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: ui(10.5), .foregroundColor: IslandPalette.ink3,
        ]
        switch s.status {
        case .waiting:
            sub.append(NSAttributedString(string: s.pendingTool ?? "Awaiting", attributes: boldAttrs))
            if let input = s.pendingInput, !input.isEmpty {
                sub.append(NSAttributedString(string: " · " + islandTruncate(input, 32), attributes: normalAttrs))
            }
        case .running:
            sub.append(NSAttributedString(string: "running", attributes: boldAttrs))
            sub.append(NSAttributedString(string: " · " + relativeAge(s.updatedAt), attributes: normalAttrs))
        case .error:
            sub.append(NSAttributedString(string: (s.pendingTool ?? "tool") + " failed", attributes: boldAttrs))
            if let e = s.lastError, !e.isEmpty {
                sub.append(NSAttributedString(string: " · " + islandTruncate(e, 28), attributes: normalAttrs))
            }
        case .idle:
            sub.append(NSAttributedString(string: "idle", attributes: normalAttrs))
        }
        if disambiguate, !s.cwd.isEmpty {
            let tail = (s.cwd as NSString).lastPathComponent
            sub.append(NSAttributedString(string: "  …/\(tail)", attributes: [
                .font: mono(9.5), .foregroundColor: IslandPalette.ink3,
            ]))
        }
        let subLabel = NSTextField(labelWithAttributedString: sub)
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.drawsBackground = false; subLabel.isBordered = false
        subLabel.translatesAutoresizingMaskIntoConstraints = false

        let info = NSStackView(views: [title, subLabel])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2
        info.translatesAutoresizingMaskIntoConstraints = false

        let tok = NSTextField(labelWithString: vm.tokens > 0 ? formatCount(vm.tokens) : "")
        tok.font = mono(11)
        tok.textColor = IslandPalette.ink3
        tok.alignment = .right
        tok.drawsBackground = false; tok.isBordered = false
        tok.translatesAutoresizingMaskIntoConstraints = false
        tok.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [dot, info, NSView(), tok])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
        ])
        return row
    }

    private func makeOverflowRow(count: Int) -> NSView {
        let row = ClickRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: IslandGeom.rowH * 0.7).isActive = true
        row.onClick = { [weak self] in self?.controller?.onOpenPopover() }
        let l = NSTextField(labelWithString: "+\(count) more · open popover")
        l.font = ui(11)
        l.textColor = IslandPalette.ink3
        l.alignment = .center
        l.drawsBackground = false; l.isBordered = false
        l.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func makeFooter(left: String, right: String) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let l = NSTextField(labelWithString: left)
        l.font = ui(10.5); l.textColor = IslandPalette.ink3
        l.drawsBackground = false; l.isBordered = false
        l.translatesAutoresizingMaskIntoConstraints = false

        let r = ClickRow()
        r.onClick = { [weak self] in self?.controller?.onOpenPopover() }
        let rLabel = NSTextField(labelWithString: right)
        rLabel.font = ui(10.5); rLabel.textColor = IslandPalette.ink2
        rLabel.drawsBackground = false; rLabel.isBordered = false
        rLabel.translatesAutoresizingMaskIntoConstraints = false
        r.translatesAutoresizingMaskIntoConstraints = false
        r.addSubview(rLabel)
        NSLayoutConstraint.activate([
            rLabel.topAnchor.constraint(equalTo: r.topAnchor, constant: 2),
            rLabel.bottomAnchor.constraint(equalTo: r.bottomAnchor, constant: -2),
            rLabel.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 4),
            rLabel.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -4),
        ])

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = IslandPalette.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        wrap.addSubview(divider)
        wrap.addSubview(l)
        wrap.addSubview(r)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            divider.heightAnchor.constraint(equalToConstant: 0.5),
            divider.topAnchor.constraint(equalTo: wrap.topAnchor),
            l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            l.centerYAnchor.constraint(equalTo: wrap.centerYAnchor, constant: 4),
            r.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            r.centerYAnchor.constraint(equalTo: wrap.centerYAnchor, constant: 4),
            wrap.heightAnchor.constraint(equalToConstant: IslandGeom.footH),
        ])
        return wrap
    }

    // MARK: - Card variants

    private func makeApprovalCard(_ sessions: [SessionVM], sessionId: String) -> NSView {
        let s = session(sessions, id: sessionId) ?? sessions.first?.s ?? Session(id: "?", status: .waiting, updatedAt: 0)
        let head = makeOpenedHead(status: .waiting, count: 1,
                                   cap: "permission · \(s.pendingTool ?? "tool")")
        let q = NSMutableAttributedString()
        q.append(NSAttributedString(string: "Approve ", attributes: [
            .font: ui(13), .foregroundColor: IslandPalette.ink,
        ]))
        q.append(NSAttributedString(string: s.pendingTool ?? "tool", attributes: [
            .font: ui(13, .semibold), .foregroundColor: IslandPalette.accent,
        ]))
        let body = makeCardBody(
            metaLeft: s.title.isEmpty ? s.folder : s.title,
            metaTag: prettyCwd(s.cwd),
            question: q,
            code: s.pendingInput,
            opts: [],
            duration: 12,
            jump: { [weak self] in self?.controller?.onJump(s.pid, s.cwd, s.isDesktop) })
        return wrapCard(head: head, body: body)
    }

    private func makeQuestionCard(_ sessions: [SessionVM], sessionId: String) -> NSView {
        let s = session(sessions, id: sessionId) ?? sessions.first?.s ?? Session(id: "?", status: .waiting, updatedAt: 0)
        let head = makeOpenedHead(status: .waiting, count: 1,
                                   cap: "question · awaiting answer")
        let q = NSMutableAttributedString(string: !s.title.isEmpty ? s.title : "Awaiting your answer",
                                          attributes: [.font: ui(13), .foregroundColor: IslandPalette.ink])
        let body = makeCardBody(
            metaLeft: s.folder,
            metaTag: prettyCwd(s.cwd),
            question: q,
            code: nil,
            opts: [],
            duration: 12,
            jump: { [weak self] in self?.controller?.onJump(s.pid, s.cwd, s.isDesktop) })
        return wrapCard(head: head, body: body)
    }

    private func makeCompletionCard(_ sessions: [SessionVM], sessionId: String) -> NSView {
        let s = session(sessions, id: sessionId) ?? sessions.first?.s ?? Session(id: "?", status: .idle, updatedAt: 0)
        let tokensVM = sessions.first(where: { $0.s.id == sessionId })?.tokens ?? 0
        let head = makeOpenedHead(status: .running, count: 1,
                                   cap: "done · \(relativeAge(s.updatedAt))")
        let q = NSMutableAttributedString(string: s.title.isEmpty ? s.folder : s.title,
                                          attributes: [.font: ui(13), .foregroundColor: IslandPalette.ink])
        let body = makeCardBody(
            metaLeft: s.folder,
            metaTag: tokensVM > 0 ? "\(formatCount(tokensVM)) tokens" : prettyCwd(s.cwd),
            question: q,
            code: nil,
            opts: [],
            duration: 6,
            jump: { [weak self] in self?.controller?.onJump(s.pid, s.cwd, s.isDesktop) },
            tone: .done)
        return wrapCard(head: head, body: body)
    }

    enum CardTone { case attention, done }

    private func wrapCard(head: NSView, body: NSView) -> NSView {
        let stack = NSStackView(views: [head, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        head.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeCardBody(metaLeft: String, metaTag: String,
                              question: NSAttributedString, code: String?,
                              opts: [String], duration: TimeInterval,
                              jump: @escaping () -> Void,
                              tone: CardTone = .attention) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let metaL = NSTextField(labelWithString: metaLeft)
        metaL.font = ui(9.5, .semibold); metaL.textColor = IslandPalette.ink2
        let metaR = NSTextField(labelWithString: metaTag)
        metaR.font = mono(9.5); metaR.textColor = IslandPalette.ink3
        for f in [metaL, metaR] {
            f.drawsBackground = false; f.isBordered = false
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        let meta = NSStackView(views: [metaL, NSView(), metaR])
        meta.orientation = .horizontal; meta.alignment = .firstBaseline
        meta.translatesAutoresizingMaskIntoConstraints = false

        let qLabel = NSTextField(labelWithAttributedString: question)
        qLabel.lineBreakMode = .byTruncatingTail
        qLabel.drawsBackground = false; qLabel.isBordered = false
        qLabel.translatesAutoresizingMaskIntoConstraints = false

        var subviews: [NSView] = [meta, qLabel]

        if let code = code, !code.isEmpty {
            let cv = NSTextField(labelWithString: islandTruncate(code, 90))
            cv.font = mono(11)
            cv.textColor = IslandPalette.ink
            cv.lineBreakMode = .byTruncatingTail
            cv.drawsBackground = true
            cv.backgroundColor = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.06)
            cv.isBordered = false
            cv.translatesAutoresizingMaskIntoConstraints = false
            cv.wantsLayer = true
            cv.layer?.cornerRadius = 6
            cv.layer?.borderWidth = 0.5
            cv.layer?.borderColor = IslandPalette.border.cgColor
            subviews.append(cv)
        }

        let jumpRow = ClickRow()
        jumpRow.onClick = jump
        jumpRow.translatesAutoresizingMaskIntoConstraints = false
        let arrow = NSTextField(labelWithString: "→")
        let txt = NSTextField(labelWithString: "Jump to terminal to respond")
        arrow.font = ui(12); arrow.textColor = IslandPalette.ink3
        txt.font = ui(12, .medium); txt.textColor = IslandPalette.ink
        for f in [arrow, txt] {
            f.drawsBackground = false; f.isBordered = false
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        let jHStack = NSStackView(views: [arrow, txt, NSView()])
        jHStack.orientation = .horizontal; jHStack.alignment = .centerY; jHStack.spacing = 10
        jHStack.translatesAutoresizingMaskIntoConstraints = false
        jumpRow.addSubview(jHStack)
        NSLayoutConstraint.activate([
            jHStack.leadingAnchor.constraint(equalTo: jumpRow.leadingAnchor, constant: 2),
            jHStack.trailingAnchor.constraint(equalTo: jumpRow.trailingAnchor, constant: -2),
            jHStack.topAnchor.constraint(equalTo: jumpRow.topAnchor, constant: 6),
            jHStack.bottomAnchor.constraint(equalTo: jumpRow.bottomAnchor, constant: -6),
        ])
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = IslandPalette.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [divider, jumpRow])
        actions.orientation = .vertical; actions.alignment = .leading; actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        divider.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        jumpRow.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        subviews.append(actions)

        let progress = CountdownBar(duration: duration,
                                     color: tone == .done ? IslandPalette.green : IslandPalette.ink3)
        progress.translatesAutoresizingMaskIntoConstraints = false
        subviews.append(progress)

        let body = NSStackView(views: subviews)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 7
        body.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            body.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
        ])
        for v in [meta, qLabel, jumpRow, progress, actions] {
            v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        return wrap
    }

    // MARK: - Helpers

    private func session(_ vms: [SessionVM], id: String) -> Session? {
        vms.first(where: { $0.s.id == id })?.s
    }

    private func prettyCwd(_ cwd: String) -> String {
        if cwd.isEmpty { return "" }
        let abbr = (cwd as NSString).abbreviatingWithTildeInPath
        return islandTruncate(abbr, 28)
    }

    private func makeOwl(for kind: IslandLabelKind, size: CGFloat) -> NSView {
        let status: Status
        switch kind {
        case .running: status = .running
        case .waiting: status = .waiting
        case .error:   status = .error
        case .idle:    status = .idle
        }
        // Bundled state PNGs from design/claudedot-icons.html via render_icons.js.
        let img = statusIcon(for: status, diameter: size)
        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: size).isActive = true
        iv.heightAnchor.constraint(equalToConstant: size).isActive = true
        return iv
    }

    private func staticDot(color: NSColor, diameter d: CGFloat, halo: NSColor) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: d + 6, height: d + 6))
        v.wantsLayer = true
        let dot = CALayer()
        dot.frame = NSRect(x: 3, y: 3, width: d, height: d)
        dot.cornerRadius = d / 2
        dot.backgroundColor = color.cgColor
        let h = CALayer()
        h.frame = NSRect(x: 0, y: 0, width: d + 6, height: d + 6)
        h.cornerRadius = (d + 6) / 2
        h.backgroundColor = halo.cgColor
        v.layer?.addSublayer(h)
        v.layer?.addSublayer(dot)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: d + 6).isActive = true
        v.heightAnchor.constraint(equalToConstant: d + 6).isActive = true
        return v
    }

    private func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.serif) {
            return NSFont(descriptor: d, size: size) ?? base
        }
        return base
    }
}

// MARK: - Reusable subviews

// A thin horizontal bar that drains over `duration` seconds. Card countdown.
final class CountdownBar: NSView {
    let duration: TimeInterval
    let color: NSColor
    private var fill: CALayer?
    init(duration: TimeInterval, color: NSColor) {
        self.duration = duration; self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 1.5))
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.08).cgColor
        layer?.cornerRadius = 0.75
        let f = CALayer()
        f.backgroundColor = color.cgColor
        f.cornerRadius = 0.75
        layer?.addSublayer(f)
        fill = f
        heightAnchor.constraint(equalToConstant: 1.5).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fill?.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let f = fill else { return }
        f.removeAllAnimations()
        f.frame = bounds
        let anim = CABasicAnimation(keyPath: "transform.scale.x")
        anim.fromValue = 1
        anim.toValue = 0
        anim.duration = duration
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        f.anchorPoint = CGPoint(x: 0, y: 0.5)
        f.frame = bounds
        f.add(anim, forKey: "drain")
    }
}

// Plain hover-highlight clickable container.
final class ClickRow: NSView {
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.04).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func mouseUp(with event: NSEvent) { onClick?() }
}

// MARK: - NSScreen extensions

extension NSScreen {
    // Width of the physical notch on a notched MacBook display, in screen
    // points. Three-tier resolution per design/dynamic-island.html §2.0
    // (2026-06 update):
    //
    //   1. Reverse-derive from auxiliary areas: notch = frame.width −
    //      auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width. Apple
    //      models the menu bar AROUND the notch as two sub-rects; whatever
    //      isn't covered IS the notch.
    //   2. If auxiliary areas aren't reported, fall back to safeAreaInsets.top
    //      × 5.5 (an empirical aspect-ratio estimate — the notch is roughly
    //      5–6x as wide as it is tall on every MBP shipped so far).
    //   3. Non-notch Macs / API unavailable: 220pt floor, wide enough to
    //      cover the worst-case 16" Max notch (~225pt) plus safety margin
    //      (§9 "非刘海机型: 形态完全等同刘海机型" — pill width should not
    //      collapse just because there's no real notch).
    //
    // Why 220 (not 180): the previous hardcoded 180pt placed the trail's
    // first token (the count digit) at +90pt from screen center, but the
    // real 14" Pro notch extends to ±102pt, so "5 Awaiting" on a real MBP
    // had the "5" eaten by the notch. See spec §9 "notch 宽度差异（实机
    // bug）" for the field report.
    var realNotchWidth: CGFloat {
        if #available(macOS 12.0, *) {
            if let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
                let derived = frame.width - left.width - right.width
                if derived > 0 { return derived }
            }
            let inset = safeAreaInsets.top
            if inset > 0 { return inset * 5.5 }
        }
        return 220
    }

    // The pill's notch-core segment width. Equal to the physical notch width
    // plus 12pt safety margin on each side (per spec §2.0) so the visual
    // notch core comfortably encloses the cutout — keeping the trail's first
    // token clear of the notch's soft-edge gradient.
    var islandNotchCoreWidth: CGFloat {
        realNotchWidth + IslandGeom.coreSafetyMargin
    }

    // Visible menu bar height in screen points. Three-tier per spec §2.0
    // (2026-06):
    //
    //   1. Notch Mac: safeAreaInsets.top IS the menu bar visual height (the
    //      menu bar is drawn to the notch's full vertical extent so app menus
    //      sit beside the cutout). ~38pt on 14"/16" MBP M-series.
    //   2. Non-notch Mac: frame.maxY − visibleFrame.maxY measures the chrome
    //      above the user-visible area (menu bar; dock at side doesn't count).
    //      Clamp < 80pt to discard weird display configs.
    //   3. NSStatusBar.system.thickness + 2 — ~24pt floor when both APIs
    //      give us nothing useful.
    //
    // Used to size the pill so it visually matches neighboring status items.
    // Previously hardcoded 28pt left a visible "stub" gap on notched Macs and
    // overflowed on non-notch Macs.
    var menuBarHeight: CGFloat {
        if #available(macOS 12.0, *) {
            let inset = safeAreaInsets.top
            if inset > 0 { return inset }
        }
        let chrome = frame.maxY - visibleFrame.maxY
        if chrome > 0 && chrome < 80 { return chrome }
        return NSStatusBar.system.thickness + 2
    }

    // Pill height: menu bar − 2pt (1pt air gap top + 1pt bottom).
    var islandHeight: CGFloat { menuBarHeight - 2 }
}
