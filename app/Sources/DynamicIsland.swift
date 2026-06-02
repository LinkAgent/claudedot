// Dynamic Island — a top-center floating capsule that mirrors the live aggregate
// session state. Folded: a status dot + active-session count. Hovered: expands
// to a list of non-idle sessions, each clickable to jump back to its terminal.
//
// Pinned to the MacBook's built-in display (the one carrying the notch). When
// the lid is closed in clamshell mode the built-in screen isn't in
// `NSScreen.screens`, and the island hides — by design (its whole visual gag
// is wrapping the notch; no notch, no island). On a Mac without notch hardware
// at all (Mac mini, MBA M1) it falls back to a slim capsule tucked under the
// menu bar so desktop users still get the surface.
//
// Coexists with the menu-bar owl (both update from the same `refresh()` tick in
// AppDelegate). Toggled from the popover footer; preference persisted in
// UserDefaults. No new data sources: feeds on the SessionVM array the popover
// already builds, so the model layer doesn't change.
//
// Diagnostic dump: set CLAUDEDOT_DEBUG_ISLAND=1 to log the resolved screen,
// safe-area insets, and panel frame to stderr on every applyFrame.

import AppKit

enum IslandState { case folded, expanded }

// MARK: - Layout (pure)

// Pure layout math, kept separate from AppKit window/view machinery so the
// snapshot renderer + future unit tests can exercise it without instantiating
// an NSPanel.
struct IslandLayout {
    // Folded must be wide enough to comfortably encompass the notch (~200pt on
    // 14/16" MacBooks) so the capsule visually wraps it AND there's a generous
    // hit target on each side for hover (see issue #14). Height = notch halo +
    // content strip (the part visible BELOW the notch).
    static let foldedWidth: CGFloat = 320
    static let foldedContentH: CGFloat = 32
    static let expandedWidth: CGFloat = 420
    static let rowHeight: CGFloat = 36
    static let listVPad: CGFloat = 8

    // The non-content "halo" — pixels reserved at the top of the capsule that
    // overlap the notch cutout. 0 on non-notch Macs.
    static func notchInset(safeAreaTop: CGFloat) -> CGFloat { safeAreaTop }

    static func foldedSize(safeAreaTop: CGFloat) -> NSSize {
        NSSize(width: foldedWidth, height: notchInset(safeAreaTop: safeAreaTop) + foldedContentH)
    }

    static func expandedSize(safeAreaTop: CGFloat, rowCount: Int) -> NSSize {
        let rows = max(1, rowCount)
        let h = notchInset(safeAreaTop: safeAreaTop) + listVPad * 2 + CGFloat(rows) * rowHeight
        return NSSize(width: expandedWidth, height: h)
    }

    // Number of vertical rows the expanded view will draw given the session
    // list. Bounded at 6, plus an extra row for "+N more" when truncating.
    // Returns 1 (a placeholder "No active sessions" row) when the list is empty.
    static func visibleRows(_ nonIdleCount: Int) -> Int {
        if nonIdleCount == 0 { return 1 }
        return min(nonIdleCount, 6) + (nonIdleCount > 6 ? 1 : 0)
    }

    // Origin of the panel on a notch-bearing screen: centered horizontally on
    // the screen, top edge AT the screen top so the notch eats into the
    // capsule and reads as one continuous pill.
    static func origin(on screenFrame: NSRect, size: NSSize, hasNotch: Bool,
                       menuBarHeight: CGFloat) -> NSPoint {
        let x = screenFrame.midX - size.width / 2
        let y: CGFloat
        if hasNotch {
            y = screenFrame.maxY - size.height
        } else {
            // No notch: tuck a hair under the menu bar.
            y = screenFrame.maxY - menuBarHeight - 2 - size.height
        }
        return NSPoint(x: x, y: y)
    }
}

// MARK: - Controller

final class DynamicIslandController {
    static let defaultsKey = "showDynamicIsland"

    private var panel: NSPanel?
    private var host: IslandHostView?
    private(set) var state: IslandState = .folded
    private var collapseWork: DispatchWorkItem?
    private var screenObs: NSObjectProtocol?
    private var spaceObs: NSObjectProtocol?

    // Whether this Mac was observed to have a built-in notch at any point in
    // this session. Lets us distinguish "no notch hardware" (Mac mini / MBA M1
    // → show under-menu-bar fallback) from "notch closed in clamshell" (hide
    // entirely).
    private var sawNotchHardware: Bool = false

    private var lastSessions: [SessionVM] = []
    private var lastTheme: Theme = .light
    private let debug: Bool = ProcessInfo.processInfo.environment["CLAUDEDOT_DEBUG_ISLAND"] != nil

    var onJump: (Int32?, String, Bool) -> Void = { _, _, _ in }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            if newValue {
                ensurePanel()
                pushUpdate()
            } else {
                panel?.orderOut(nil)
            }
        }
    }

    init() {
        screenObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.pushUpdate() }
        // Other apps entering/exiting fullscreen swap spaces; this is the
        // reliable signal (NSMenu.menuBarVisible is app-local — see #13).
        spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.pushUpdate() }
    }

    deinit {
        if let o = screenObs { NotificationCenter.default.removeObserver(o) }
        if let o = spaceObs { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    // Called by AppDelegate.refresh() on every tick.
    func update(sessions: [SessionVM], theme: Theme) {
        lastSessions = sessions
        lastTheme = theme
        guard enabled else { return }
        pushUpdate()
    }

    // The one place that reconciles "what should be on screen right now" with
    // the panel — re-checks screen presence, fullscreen state, sizing, and
    // content. Safe to call repeatedly.
    private func pushUpdate() {
        guard enabled else { return }
        let target = resolveTarget()
        switch target {
        case .hidden:
            panel?.orderOut(nil)
            log("hidden")
        case .visible(let screen, let safeAreaTop, let hasNotch):
            ensurePanel()
            if hasNotch { sawNotchHardware = true }
            host?.topInset = IslandLayout.notchInset(safeAreaTop: safeAreaTop)
            host?.update(sessions: lastSessions, state: state)
            applyFrame(on: screen, safeAreaTop: safeAreaTop, hasNotch: hasNotch, animated: false)
            if panel?.isVisible == false { panel?.orderFrontRegardless() }
        }
    }

    private enum Target {
        case hidden
        case visible(NSScreen, safeAreaTop: CGFloat, hasNotch: Bool)
    }

    // Decide whether and where to show. Hides in clamshell (notch was seen
    // before but no notch screen present now) and when a fullscreen app has
    // taken over the screen we'd be on.
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

        // No notch in current screen set.
        if sawNotchHardware {
            // We're on a notch MBP but the built-in display went away —
            // clamshell with lid closed. Hide.
            return .hidden
        }

        // True non-notch Mac (mini, Studio, MBA M1, older MBPs). Tuck under
        // the menu bar on the main screen so the surface is still useful.
        guard let main = NSScreen.main else { return .hidden }
        return .visible(main, safeAreaTop: 0, hasNotch: false)
    }

    private func ensurePanel() {
        if panel != nil { return }
        // Sized minimally; the next applyFrame will set the real geometry.
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: IslandLayout.foldedWidth, height: 64),
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
        let h = IslandHostView(frame: NSRect(x: 0, y: 0, width: IslandLayout.foldedWidth, height: 64))
        h.controller = self
        p.contentView = h
        panel = p
        host = h
    }

    func setState(_ s: IslandState) {
        guard s != state else { return }
        state = s
        // Re-run the whole reconciler so animated frame change picks the
        // right size + the host rebuilds its content for the new state.
        guard case .visible(let screen, let safeAreaTop, let hasNotch) = resolveTarget() else { return }
        host?.topInset = IslandLayout.notchInset(safeAreaTop: safeAreaTop)
        host?.update(sessions: lastSessions, state: s)
        applyFrame(on: screen, safeAreaTop: safeAreaTop, hasNotch: hasNotch, animated: true)
    }

    func scheduleCollapse(delay: TimeInterval = 0.4) {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.setState(.folded) }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    func cancelCollapse() { collapseWork?.cancel(); collapseWork = nil }

    private func applyFrame(on screen: NSScreen, safeAreaTop: CGFloat, hasNotch: Bool, animated: Bool) {
        guard let panel = panel else { return }
        let size: NSSize
        switch state {
        case .folded:
            size = IslandLayout.foldedSize(safeAreaTop: safeAreaTop)
        case .expanded:
            let nonIdle = lastSessions.filter { $0.s.status != .idle }.count
            size = IslandLayout.expandedSize(safeAreaTop: safeAreaTop,
                                             rowCount: IslandLayout.visibleRows(nonIdle))
        }
        let origin = IslandLayout.origin(on: screen.frame, size: size,
                                          hasNotch: hasNotch,
                                          menuBarHeight: NSStatusBar.system.thickness)
        let r = NSRect(origin: origin, size: size)
        log("applyFrame state=\(state) screen=\(screen.frame) safeTop=\(safeAreaTop) panel=\(r)")
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(r, display: true)
            }
        } else {
            panel.setFrame(r, display: true)
        }
    }

    private func log(_ msg: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[island] \(msg)\n".utf8))
    }
}

// MARK: - View

// The panel's content view: paints the capsule background, hosts the inner
// stack, owns the hover tracking that drives expand/collapse.
final class IslandHostView: NSView {
    weak var controller: DynamicIslandController?
    private var tracking: NSTrackingArea?
    private var inner: NSView?
    private var bgLayer: CALayer?
    private var currentSessions: [SessionVM] = []
    private var lastSig: String = ""

    // Pixels reserved at the top for the notch cutout. Content sits beneath
    // this so the notch overlaps an empty, fully-black halo and reads as part
    // of the capsule.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { lastSig = ""; needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        layer = root
        let bg = CALayer()
        bg.cornerCurve = .continuous
        bg.borderWidth = 0.5
        bg.backgroundColor = NSColor.black.cgColor
        bg.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        root.addSublayer(bg)
        bgLayer = bg
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func update(sessions: [SessionVM], state: IslandState) {
        currentSessions = sessions
        // Signature covers everything the island actually renders. Theme is
        // pinned to dark (island always blends with the notch's black), so it
        // isn't in the signature. topInset clears the sig via its didSet.
        let sig: String
        if state == .folded {
            let agg = aggregateStatus(sessions.map { $0.s })
            let active = sessions.filter { $0.s.status != .idle }.count
            sig = "F|\(agg.rawValue)|\(active)"
        } else {
            sig = "E|" + sessions.filter { $0.s.status != .idle }.prefix(6).map {
                "\($0.s.id):\($0.s.status.rawValue):\($0.s.folder)"
            }.joined(separator: "|")
        }
        if sig == lastSig { return }
        lastSig = sig

        inner?.removeFromSuperview()
        // Force dark island theme regardless of system appearance — the
        // island's whole point is to blend with the notch's black cutout.
        let theme = Theme.dark
        let v: NSView = state == .folded ? makeFolded(sessions, theme: theme)
                                         : makeExpanded(sessions, theme: theme)
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        // Inset content from the top by the notch height so it sits in the
        // strip BELOW the notch — the notch overlaps the unbroken black halo.
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
        if let bg = bgLayer {
            bg.frame = bounds
            bg.cornerRadius = min(bounds.height / 2, 18)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.cancelCollapse()
        controller?.setState(.expanded)
    }
    override func mouseExited(with event: NSEvent) {
        // Stay open while a waiting session needs attention — the whole point
        // of the expanded view is letting the user see what to approve.
        if currentSessions.contains(where: { $0.s.status == .waiting }) { return }
        controller?.scheduleCollapse()
    }

    // -- Folded: dot + "N session(s)" or "idle" --
    private func makeFolded(_ sessions: [SessionVM], theme: Theme) -> NSView {
        let agg = aggregateStatus(sessions.map { $0.s })
        let active = sessions.filter { $0.s.status != .idle }.count

        // Dot — explicit layer-backed view, fixed 9pt circle.
        let d: CGFloat = 9
        let dotLayer = CALayer()
        dotLayer.frame = NSRect(x: 0, y: 0, width: d, height: d)
        dotLayer.cornerRadius = d / 2
        dotLayer.backgroundColor = statusColor(agg).cgColor
        let dotHost = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        dotHost.wantsLayer = true
        dotHost.layer?.addSublayer(dotLayer)
        dotHost.translatesAutoresizingMaskIntoConstraints = false
        dotHost.widthAnchor.constraint(equalToConstant: d).isActive = true
        dotHost.heightAnchor.constraint(equalToConstant: d).isActive = true

        // Text — plain labelWithString + explicit font/color. Attributed-string
        // labels were silently failing to draw inside the folded view (the dot
        // showed but the text didn't); a plain label renders reliably.
        let str: String
        if active == 0 {
            str = "Claude · idle"
        } else {
            str = "Claude · \(active) " + (active == 1 ? "session" : "sessions")
        }
        let label = NSTextField(labelWithString: str)
        label.font = ui(11.5, .medium)
        label.textColor = active == 0 ? NSColor(white: 0.7, alpha: 1) : NSColor.white
        label.drawsBackground = false
        label.isBordered = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Compose as an NSStackView with hugging-tight intrinsic width, then
        // CENTER inside an explicit container view that fills the strip.
        // Previously I returned the bare wrap and centered the stack inside
        // it with only centerX/centerY constraints; the host gave the wrap a
        // size via fill constraints, but the stack inside it had ambiguous
        // width (centerX alone doesn't pin width) and AppKit collapsed the
        // label's frame to 0 — invisible text. Pinning the stack's leading
        // edge to a content-hug-driven width works, but plain "center in a
        // sized container" with explicit non-fill stack constraints is
        // simpler and more obviously correct.
        let hs = NSStackView(views: [dotHost, label])
        hs.orientation = .horizontal
        hs.alignment = .centerY
        hs.spacing = 8
        hs.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(hs)
        // Center the stack; cap its top/bottom so it gets a real frame even
        // when there's nothing else forcing a layout pass.
        NSLayoutConstraint.activate([
            hs.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            hs.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            hs.topAnchor.constraint(greaterThanOrEqualTo: wrap.topAnchor),
            hs.bottomAnchor.constraint(lessThanOrEqualTo: wrap.bottomAnchor),
            hs.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor, constant: 16),
            hs.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -16),
        ])
        return wrap
    }

    // -- Expanded: list of non-idle session rows --
    private func makeExpanded(_ sessions: [SessionVM], theme: Theme) -> NSView {
        let nonIdle = sessions.filter { $0.s.status != .idle }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: IslandLayout.listVPad, left: 10,
                                        bottom: IslandLayout.listVPad, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if nonIdle.isEmpty {
            let l = NSTextField(labelWithString: "No active sessions")
            l.font = ui(11.5)
            l.textColor = NSColor(white: 0.7, alpha: 1)
            l.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                l.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            ])
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            wrap.heightAnchor.constraint(equalToConstant: IslandLayout.rowHeight).isActive = true
            return stack
        }

        for vm in nonIdle.prefix(6) {
            let row = makeRow(vm, theme: theme)
            stack.addArrangedSubview(row)
            // Width is constrained AFTER addArrangedSubview so the row + stack
            // share an ancestor; otherwise activate() throws "no common ancestor".
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        if nonIdle.count > 6 {
            let l = NSTextField(labelWithString: "+\(nonIdle.count - 6) more — see popover")
            l.font = ui(10)
            l.textColor = NSColor(white: 0.55, alpha: 1)
            l.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(l)
        }
        return stack
    }

    private func makeRow(_ vm: SessionVM, theme: Theme) -> NSView {
        let s = vm.s
        let row = HoverRow(theme: theme)
        row.onClick = { [weak self] in self?.controller?.onJump(s.pid, s.cwd, s.isDesktop) }
        let dot = DotView(status: s.status)
        let name = NSTextField(labelWithString: s.folder)
        name.font = {
            let base = NSFont.systemFont(ofSize: 13, weight: .medium)
            return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 13) } ?? base
        }()
        name.textColor = NSColor.white
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        let (statusText, attn) = statusLine(for: s)
        let sub = NSTextField(labelWithString: statusText)
        sub.font = ui(10.5)
        sub.textColor = attn ? NSColor(hex: "E96945") : NSColor(white: 0.55, alpha: 1)
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false
        let info = NSStackView(views: [name, sub])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 0
        info.translatesAutoresizingMaskIntoConstraints = false
        let arrow = NSTextField(labelWithString: "→")
        arrow.font = ui(12)
        arrow.textColor = NSColor(white: 0.55, alpha: 1)
        arrow.translatesAutoresizingMaskIntoConstraints = false
        let hs = NSStackView(views: [dot, info, NSView(), arrow])
        hs.orientation = .horizontal
        hs.alignment = .centerY
        hs.spacing = 10
        hs.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(hs)
        NSLayoutConstraint.activate([
            hs.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            hs.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            hs.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            hs.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -5),
        ])
        row.heightAnchor.constraint(equalToConstant: IslandLayout.rowHeight).isActive = true
        return row
    }
}
