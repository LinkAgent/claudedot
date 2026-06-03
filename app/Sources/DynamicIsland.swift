// Dynamic Island — a top-center floating capsule that mirrors the live aggregate
// session state. Always pure black so it blends with the MacBook notch.
//
// Surface model (§4 of design/dynamic-island.html):
//
//   layout: closed | opened       × variant: sessionList | approval | question | completion
//
// closed shows 3 things only: face-changing owl, activeCount, and the highest-
// priority status line (error > waiting > running > idle). Hovering for ≥180ms
// opens to `sessionList`. Hook events route to the card variants:
//   • a session entering .waiting    → approval (or question, for AskUserQuestion)
//   • a session completing           → completion
// Cards are temporary surfaces — they auto-collapse after 12s / 12s / 6s
// respectively, and collapse immediately once the pointer enters & leaves.
//
// Coexists with the menu-bar owl (both update from the same `refresh()` tick in
// AppDelegate). Toggled from the popover footer; preference persisted in
// UserDefaults. No new data sources: feeds on the SessionVM array the popover
// already builds, so the model layer doesn't change.
//
// Diagnostic dump: set CLAUDEDOT_DEBUG_ISLAND=1 to log the resolved screen,
// safe-area insets, and panel frame to stderr on every applyFrame.

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

// Geometry constants per §7 of the spec. Pure so the snapshot renderer and
// future unit tests can use them without standing up an NSPanel.
struct IslandGeom {
    static let foldedW: CGFloat = 250
    static let foldedIdleW: CGFloat = 140
    static let foldedH: CGFloat = 24        // content strip BELOW the notch
    static let expandedW: CGFloat = 420
    static let rowH: CGFloat = 38
    static let headH: CGFloat = 40
    static let listVPad: CGFloat = 6
    static let footH: CGFloat = 22
    static let cardVPad: CGFloat = 10
    static let approvalH: CGFloat = 124
    static let questionH: CGFloat = 160
    static let completionH: CGFloat = 112
    static let maxRows: Int = 5

    static func notchInset(safeAreaTop: CGFloat) -> CGFloat { safeAreaTop }

    static func foldedSize(safeAreaTop: CGFloat, idle: Bool) -> NSSize {
        let w = idle ? foldedIdleW : foldedW
        return NSSize(width: w, height: notchInset(safeAreaTop: safeAreaTop) + foldedH)
    }

    static func expandedSize(safeAreaTop: CGFloat,
                              variant: IslandCardVariant,
                              rowCount: Int) -> NSSize {
        let inset = notchInset(safeAreaTop: safeAreaTop)
        let body: CGFloat
        switch variant {
        case .sessionList:
            let rows = max(1, min(rowCount, maxRows))
            let overflow: CGFloat = rowCount > maxRows ? rowH * 0.7 : 0
            body = headH + listVPad * 2 + CGFloat(rows) * rowH + overflow + footH
        case .approval:    body = headH + approvalH
        case .question:    body = headH + questionH
        case .completion:  body = headH + completionH
        }
        return NSSize(width: expandedW, height: inset + body)
    }

    static func origin(on screenFrame: NSRect, size: NSSize, hasNotch: Bool,
                       menuBarHeight: CGFloat) -> NSPoint {
        let x = screenFrame.midX - size.width / 2
        let y: CGFloat
        if hasNotch {
            y = screenFrame.maxY - size.height
        } else {
            y = screenFrame.maxY - menuBarHeight - 2 - size.height
        }
        return NSPoint(x: x, y: y)
    }
}

// Dark palette — only the dark-theme tokens from DESIGN.md, NOT the
// menu-bar owl's Evernote/Giallo set. The island is always on a black field,
// so it needs the higher-contrast dark-mode palette.
enum IslandPalette {
    static let bg     = NSColor.black
    static let ink    = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 1)
    static let ink2   = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.62)
    static let ink3   = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.36)
    static let accent = NSColor(srgbRed: 233/255, green: 105/255, blue:  69/255, alpha: 1)
    static let green  = NSColor(srgbRed: 122/255, green: 155/255, blue: 118/255, alpha: 1)
    static let red    = NSColor(srgbRed: 210/255, green: 122/255, blue: 102/255, alpha: 1)
    static let border = NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.10)

    // Color of the pulse dot for each status. Per §5 of the spec: running uses
    // ink-3 (a low-key gray pulse — running is not the call-to-action), waiting
    // uses the accent (the island's strongest signal), error uses red.
    static func dotColor(for kind: IslandLabelKind) -> NSColor {
        switch kind {
        case .running: return ink3
        case .waiting: return accent
        case .error:   return red
        case .idle:    return NSColor(srgbRed: 236/255, green: 232/255, blue: 221/255, alpha: 0.18)
        }
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
    // Same (variant, session) won't auto-re-trigger within 30s of being shown,
    // per §6 ("已经折回的事件不重复推: 30s 内同一会话不重弹同类卡片").
    private var lastCardShown: [String: Double] = [:]
    private let cardDedupeWindow: Double = 30

    // Snapshot of each session's status from the prior update tick. Used to
    // detect transitions: idle→waiting (open approval/question card),
    // non-idle→idle (open completion card).
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
            // A new pending tool name on an already-waiting session also counts
            // — the old card has expired or the user moved on, and now a fresh
            // approval is pending.
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

    // The one place that reconciles "what should be on screen right now" with
    // the panel. Safe to call repeatedly.
    private func pushUpdate(animated: Bool) {
        guard enabled else { return }
        let target = resolveTarget()
        switch target {
        case .hidden:
            panel?.orderOut(nil)
            log("hidden")
        case .visible(let screen, let safeAreaTop, let hasNotch):
            ensurePanel()
            if hasNotch { sawNotchHardware = true }
            host?.topInset = IslandGeom.notchInset(safeAreaTop: safeAreaTop)
            host?.hasNotch = hasNotch
            host?.update(sessions: lastSessions, layout: layout, variant: variant)
            applyFrame(on: screen, safeAreaTop: safeAreaTop, hasNotch: hasNotch, animated: animated)
            if panel?.isVisible == false { panel?.orderFrontRegardless() }
        }
    }

    private enum Target {
        case hidden
        case visible(NSScreen, safeAreaTop: CGFloat, hasNotch: Bool)
    }

    private func resolveTarget() -> Target {
        let notchScreen: NSScreen? = {
            if #available(macOS 12.0, *) {
                return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            }
            return nil
        }()
        if let s = notchScreen {
            let safe: CGFloat = {
                if #available(macOS 12.0, *) { return s.safeAreaInsets.top }
                return 0
            }()
            return .visible(s, safeAreaTop: safe, hasNotch: true)
        }
        if sawNotchHardware { return .hidden }
        guard let main = NSScreen.main else { return .hidden }
        return .visible(main, safeAreaTop: 0, hasNotch: false)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: IslandGeom.foldedW, height: 64),
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
        let h = IslandHostView(frame: NSRect(x: 0, y: 0, width: IslandGeom.foldedW, height: 64))
        h.controller = self
        p.contentView = h
        panel = p
        host = h
    }

    // MARK: - State transitions

    // Set the visible surface. Used internally and by hover handlers in
    // IslandHostView. Animated.
    func setLayout(_ l: IslandLayout, variant v: IslandCardVariant = .sessionList) {
        // Idempotent — but always cancel pending hover-open work, so a quick
        // exit doesn't get re-opened by a late timer.
        if l == .closed { hoverOpenWork?.cancel(); hoverOpenWork = nil }
        let changed = (l != layout) || (v != variant)
        layout = l
        variant = v
        guard changed else { return }
        guard case .visible(let screen, let safeAreaTop, let hasNotch) = resolveTarget() else { return }
        host?.topInset = IslandGeom.notchInset(safeAreaTop: safeAreaTop)
        host?.hasNotch = hasNotch
        host?.update(sessions: lastSessions, layout: l, variant: v)
        applyFrame(on: screen, safeAreaTop: safeAreaTop, hasNotch: hasNotch, animated: true)
    }

    // Auto-expand to a card. Schedules its expiration timer per §6.
    func present(variant v: IslandCardVariant) {
        cardExpireWork?.cancel()
        let delay: TimeInterval
        switch v {
        case .sessionList:  delay = 0  // no expiration — user-driven
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
        // Don't override an active card with the sessionList just because the
        // user hovered over it — they can still see and click it.
        if case .opened = layout, case .sessionList = variant { return }
        if case .opened = layout, variant.priority > IslandCardVariant.sessionList.priority { return }
        let w = DispatchWorkItem { [weak self] in self?.setLayout(.opened, variant: .sessionList) }
        hoverOpenWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }
    func hoverExited() {
        hoverOpenWork?.cancel(); hoverOpenWork = nil
        // §6: pointer enters card & leaves → collapse immediately (look-and-go).
        // For sessionList we keep the 400ms grace so the user has time to move
        // onto a row without it slipping away.
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

    private func applyFrame(on screen: NSScreen, safeAreaTop: CGFloat, hasNotch: Bool, animated: Bool) {
        guard let panel = panel else { return }
        let size: NSSize = sizeForState(safeAreaTop: safeAreaTop)
        let origin = IslandGeom.origin(on: screen.frame, size: size,
                                       hasNotch: hasNotch,
                                       menuBarHeight: NSStatusBar.system.thickness)
        let r = NSRect(origin: origin, size: size)
        log("applyFrame layout=\(layout) variant=\(variant) screen=\(screen.frame) safeTop=\(safeAreaTop) panel=\(r)")
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

    private func sizeForState(safeAreaTop: CGFloat) -> NSSize {
        switch layout {
        case .closed:
            let agg = aggregateStatus(lastSessions.map { $0.s })
            return IslandGeom.foldedSize(safeAreaTop: safeAreaTop, idle: agg == .idle)
        case .opened:
            let nonIdle = activeCount(lastSessions.map { $0.s })
            return IslandGeom.expandedSize(safeAreaTop: safeAreaTop, variant: variant, rowCount: nonIdle)
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
    private var currentSessions: [SessionVM] = []
    private var currentLayout: IslandLayout = .closed
    private var currentVariant: IslandCardVariant = .sessionList
    private var lastSig: String = ""

    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { lastSig = ""; needsLayout = true } }
    }
    // True on a notch MBP — bottom corners round, top edges stay square so the
    // capsule tucks seamlessly under the notch. False on non-notch Macs — all
    // four corners get the same 14pt radius (spec §9 "非刘海机型：四角均匀").
    var hasNotch: Bool = false {
        didSet { if hasNotch != oldValue { needsLayout = true } }
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
        currentSessions = sessions
        currentLayout = layout
        currentVariant = variant
        // Signature covers what's actually drawn so we don't rebuild on every
        // 1.5s tick when nothing changed.
        let sig: String = {
            switch layout {
            case .closed:
                let label = islandFoldedLabel(sessions: sessions.map { $0.s })
                return "C|\(label.kind)|\(label.main)|\(label.sub)|\(activeCount(sessions.map { $0.s }))"
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
            v.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        inner = v
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let bg = bgLayer else { return }
        bg.frame = bounds
        // Bottom radius differs by layout: 16pt for the folded pill, 28pt
        // for the expanded card (spec §7 "圆角 28pt"). Non-notch Macs round
        // all four corners with the same radius (no notch to hide into).
        let bottom: CGFloat = currentLayout == .closed ? 16 : 28
        let top: CGFloat = hasNotch ? 0 : bottom
        applyShapedMask(topRadius: top, bottomRadius: bottom)
    }

    // Path mask: top corners round only on non-notch Macs (so the notch on a
    // notch MBP appears to BE the top of the capsule). The mask must have its
    // frame set to bounds — without that, CAShapeLayer renders at origin and
    // the corners visibly squared off (the bug v0.3 shipped with).
    private func applyShapedMask(topRadius tr: CGFloat, bottomRadius br: CGFloat) {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let path = CGMutablePath()
        // Bottom-left corner (origin) — counter-clockwise traversal.
        path.move(to: CGPoint(x: b.minX, y: b.minY + br))
        if br > 0 {
            path.addArc(center: CGPoint(x: b.minX + br, y: b.minY + br),
                        radius: br, startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
        }
        path.addLine(to: CGPoint(x: b.maxX - br, y: b.minY))
        if br > 0 {
            path.addArc(center: CGPoint(x: b.maxX - br, y: b.minY + br),
                        radius: br, startAngle: .pi * 1.5, endAngle: 0, clockwise: false)
        }
        path.addLine(to: CGPoint(x: b.maxX, y: b.maxY - tr))
        if tr > 0 {
            path.addArc(center: CGPoint(x: b.maxX - tr, y: b.maxY - tr),
                        radius: tr, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        }
        path.addLine(to: CGPoint(x: b.minX + tr, y: b.maxY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: b.minX + tr, y: b.maxY - tr),
                        radius: tr, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        }
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.path = path
        mask.frame = b
        mask.fillColor = NSColor.black.cgColor
        bgLayer?.mask = mask
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

    // MARK: - Folded surface

    private func makeFolded(_ sessions: [SessionVM]) -> NSView {
        let label = islandFoldedLabel(sessions: sessions.map { $0.s })
        let count = activeCount(sessions.map { $0.s })

        let owl = makeOwl(for: label.kind, size: 24)
        let countLabel = NSTextField(labelWithString: count > 0 ? "\(count)" : "")
        countLabel.font = serif(19, .medium)
        countLabel.textColor = IslandPalette.ink
        countLabel.drawsBackground = false
        countLabel.isBordered = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let mainColor: NSColor
        switch label.kind {
        case .waiting: mainColor = IslandPalette.accent
        case .error:   mainColor = IslandPalette.red
        case .running: mainColor = IslandPalette.ink
        case .idle:    mainColor = IslandPalette.ink3
        }
        let mainLabel = NSTextField(labelWithString: label.main)
        mainLabel.font = ui(11, label.kind == .idle ? .regular : .medium)
        mainLabel.textColor = mainColor
        mainLabel.lineBreakMode = .byTruncatingTail
        mainLabel.drawsBackground = false; mainLabel.isBordered = false
        mainLabel.translatesAutoresizingMaskIntoConstraints = false

        let subLabel = NSTextField(labelWithString: label.sub)
        subLabel.font = ui(10.5)
        subLabel.textColor = IslandPalette.ink2
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.drawsBackground = false; subLabel.isBordered = false
        subLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: label.sub.isEmpty ? [mainLabel] : [mainLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let pulse = PulseDot(color: IslandPalette.dotColor(for: label.kind), animate: label.kind != .idle)
        pulse.translatesAutoresizingMaskIntoConstraints = false

        // Idle: just owl + label (no count, no pulse), narrow.
        let stack: NSStackView
        if label.kind == .idle || count == 0 {
            stack = NSStackView(views: [owl, textStack])
            stack.spacing = 8
        } else {
            stack = NSStackView(views: [owl, countLabel, textStack, pulse])
            stack.spacing = 8
            stack.setCustomSpacing(6, after: owl)
            stack.setCustomSpacing(10, after: countLabel)
        }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: wrap.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }

    // MARK: - Expanded sessionList

    private func makeSessionList(_ sessions: [SessionVM]) -> NSView {
        let nonIdle = sessions.filter { $0.s.status != .idle }
        let waiting = nonIdle.filter { $0.s.status == .waiting }.count
        let agg = aggregateStatus(sessions.map { $0.s })

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        // Head
        let head = makeHead(label: islandFoldedLabel(sessions: sessions.map { $0.s }),
                             count: nonIdle.count, cap: waiting > 0
                                ? "active · \(waiting) awaiting"
                                : "active session\(nonIdle.count == 1 ? "" : "s")")
        root.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // Rows
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 1
        list.translatesAutoresizingMaskIntoConstraints = false
        list.edgeInsets = NSEdgeInsets(top: IslandGeom.listVPad, left: 6,
                                        bottom: IslandGeom.listVPad, right: 6)

        let visible = Array(nonIdle.prefix(IslandGeom.maxRows))
        let overflowCount = nonIdle.count - visible.count

        // Same-title disambiguation: if 2+ rows share a folder name, append
        // the cwd's last segment to the sub line of each duplicate.
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

        // Footer hint
        let foot = makeFooter(left: "Click a row to jump", right: "open popover")
        root.addArrangedSubview(foot)
        foot.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        _ = agg
        return root
    }

    private func makeListRow(_ vm: SessionVM, disambiguate: Bool) -> NSView {
        let s = vm.s
        let row = ClickRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: IslandGeom.rowH).isActive = true
        row.onClick = { [weak self] in self?.controller?.onJump(s.pid, s.cwd, s.isDesktop) }

        let kind: IslandLabelKind = {
            switch s.status {
            case .waiting: return .waiting
            case .running: return .running
            case .error:   return .error
            case .idle:    return .idle
            }
        }()
        let dot = staticDot(color: IslandPalette.dotColor(for: kind), diameter: 7,
                             halo: IslandPalette.dotColor(for: kind).withAlphaComponent(0.18))

        let title = NSTextField(labelWithString: s.folder)
        title.font = serif(13.5, .medium)
        title.textColor = IslandPalette.ink
        title.lineBreakMode = .byTruncatingTail
        title.drawsBackground = false; title.isBordered = false
        title.translatesAutoresizingMaskIntoConstraints = false

        // Sub line: `<b>tool</b> · sub` or `<b>state</b> · age`.
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

    // MARK: - Shared head / footer

    private func makeHead(label: IslandLabel, count: Int, cap: String) -> NSView {
        let owl = makeOwl(for: label.kind, size: 22)
        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = serif(22, .medium)
        countLabel.textColor = IslandPalette.ink
        countLabel.drawsBackground = false; countLabel.isBordered = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let capLabel = makeCapLabel(cap)
        let pulse = PulseDot(color: IslandPalette.dotColor(for: label.kind), animate: label.kind != .idle)
        pulse.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [owl, countLabel, capLabel, NSView(), pulse])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        // Faint divider below the head.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = IslandPalette.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(divider)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -6),
            divider.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            divider.heightAnchor.constraint(equalToConstant: 0.5),
            divider.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            wrap.heightAnchor.constraint(equalToConstant: IslandGeom.headH),
        ])
        return wrap
    }

    private func makeCapLabel(_ s: String) -> NSTextField {
        let a = NSAttributedString(string: s.uppercased(), attributes: [
            .font: ui(9.5, .semibold),
            .foregroundColor: IslandPalette.ink3,
            .kern: 1.4,
        ])
        let t = NSTextField(labelWithAttributedString: a)
        t.drawsBackground = false; t.isBordered = false
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
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
        let head = makeHead(label: IslandLabel(main: "Awaiting", sub: "", kind: .waiting),
                             count: 1,
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
        let head = makeHead(label: IslandLabel(main: "Question", sub: "", kind: .waiting),
                             count: 1, cap: "question · awaiting answer")
        let q = NSMutableAttributedString(string: !s.title.isEmpty ? s.title : "Awaiting your answer",
                                          attributes: [.font: ui(13), .foregroundColor: IslandPalette.ink])
        let body = makeCardBody(
            metaLeft: s.title.isEmpty ? s.folder : s.folder,
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
        let label = IslandLabel(main: "Done", sub: "", kind: .running)
        let head = makeHead(label: label, count: 1, cap: "done · \(relativeAge(s.updatedAt))")
        let q = NSMutableAttributedString(string: s.title.isEmpty ? s.folder : s.title,
                                          attributes: [.font: ui(13), .foregroundColor: IslandPalette.ink])
        let tokensVM = sessions.first(where: { $0.s.id == sessionId })?.tokens ?? 0
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

        // Meta row
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

        // Question
        let qLabel = NSTextField(labelWithAttributedString: question)
        qLabel.lineBreakMode = .byTruncatingTail
        qLabel.drawsBackground = false; qLabel.isBordered = false
        qLabel.translatesAutoresizingMaskIntoConstraints = false

        var subviews: [NSView] = [meta, qLabel]

        // Code block
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

        // Jump row
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
        // Top divider above the jump row
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

        // Countdown progress bar
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
        // Stretch the meta row, code block, jump row, and progress bar to full width.
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
        // Use the bundled state PNGs (StatusRunning.png / StatusWaiting.png /
        // StatusError.png / StatusIdle*.png) generated by scripts/render_icons.js
        // from design/claudedot-icons.html — these ARE the design icons.
        // statusIcon() prefers the bundle and only falls back to the hand-drawn
        // owlImage if the asset can't be loaded. We were calling owlImage()
        // directly, which silently used the fallback even when the design
        // assets were sitting right there in the bundle.
        let img = statusIcon(for: status, diameter: size)
        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: size).isActive = true
        iv.heightAnchor.constraint(equalToConstant: size).isActive = true
        // No extra layer clip — the bundled icon already includes its own
        // rounded-square shape; clipping it again would chop the highlights.
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

// 7pt circle with a slowly-pulsing ring. Always layer-backed so it composites
// cleanly on the black background.
final class PulseDot: NSView {
    let color: NSColor
    let animate: Bool
    init(color: NSColor, animate: Bool) {
        self.color = color; self.animate = animate
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        wantsLayer = true
        layer = CALayer()
        let d: CGFloat = 7
        let inset: CGFloat = (16 - d) / 2
        let core = CALayer()
        core.frame = NSRect(x: inset, y: inset, width: d, height: d)
        core.cornerRadius = d / 2
        core.backgroundColor = color.cgColor
        layer?.addSublayer(core)
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, animate, let layer = layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "ring" }) == true { return }
        let ring = CAShapeLayer()
        ring.name = "ring"
        let d: CGFloat = 7
        let inset: CGFloat = (16 - d) / 2
        let r = NSRect(x: inset, y: inset, width: d, height: d).insetBy(dx: -2, dy: -2)
        ring.path = CGPath(ellipseIn: r, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 1
        ring.opacity = 0
        ring.frame = bounds
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6; scale.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.6
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
    }
}

// A thin horizontal bar that drains over `duration` seconds. Used as the card
// countdown indicator.
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
