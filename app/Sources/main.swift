// Claude Dot — a macOS menu-bar app that reflects the live state of your Claude
// Code sessions and surfaces usage + pending approvals in a rich popover.
//
// Data sources (all local, read-only):
//   ~/.claude/sessions/<pid>.json            native registry (discovery + state)
//   ~/.claude/statusbar/sessions/<id>.json   our hook enrichment (errors, titles,
//                                             pending tool/input for approvals)
//   ~/.claude/projects/<dir>/<id>.jsonl       transcript → per-session token totals
//   ~/.claude/stats-cache.json                today's tokens, cost (usage meter)
//
// The menu-bar glyph is a vector owl whose color = aggregate state. Clicking it
// opens an NSPopover styled after design/claudedot.html. Pure AppKit, swiftc.
//
// Run with `--snapshot <png>` to render the popover (light+dark, demo data)
// offscreen to a file — used to preview the UI without Screen Recording access.

import AppKit
import Foundation

// Model, Status, relativeAge, aggregateStatus, formatCount, sessionTokenTotal
// live in Model.swift (shared with the headless test harness).

// MARK: - Claude Dot face icon (color = aggregate state)

// Status face colors follow design/claudedot-icons.html.
func statusColor(_ s: Status, appearance: NSAppearance? = nil) -> NSColor {
    switch s {
    case .running: return NSColor(hex: "00A82D") // Evernote-style green
    case .waiting: return NSColor(hex: "FEA700") // Giallo Orion yellow
    case .error:   return NSColor(hex: "D40000") // Rosso Mars red
    case .idle:
        let app = appearance ?? NSApp.effectiveAppearance
        let dark = app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(hex: "F2EFE7") : NSColor(hex: "2B2A27")
    }
}

func faceForeground(for status: Status, appearance: NSAppearance? = nil) -> NSColor {
    if status != .idle { return .white }
    let app = appearance ?? NSApp.effectiveAppearance
    let dark = app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return dark ? NSColor(hex: "2B2A27") : NSColor(hex: "ECE8DD")
}

func faceImage(background bg: NSColor, foreground fg: NSColor, diameter d: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: d, height: d))
    img.lockFocus()
    defer { img.unlockFocus() }
    img.isTemplate = false

    bg.setFill()
    let rect = NSRect(x: 0, y: 0, width: d, height: d)
    NSBezierPath(roundedRect: rect, xRadius: d * 0.225, yRadius: d * 0.225).fill()

    // Upper brow mask, matching the square face system in claudedot-icons.html.
    fg.setFill()
    let brow = NSBezierPath()
    brow.move(to: NSPoint(x: d * 0.04, y: d * 0.64))
    brow.curve(to: NSPoint(x: d * 0.43, y: d * 0.50),
               controlPoint1: NSPoint(x: d * 0.13, y: d * 0.83),
               controlPoint2: NSPoint(x: d * 0.28, y: d * 0.67))
    brow.curve(to: NSPoint(x: d * 0.50, y: d * 0.43),
               controlPoint1: NSPoint(x: d * 0.47, y: d * 0.47),
               controlPoint2: NSPoint(x: d * 0.49, y: d * 0.44))
    brow.curve(to: NSPoint(x: d * 0.57, y: d * 0.50),
               controlPoint1: NSPoint(x: d * 0.51, y: d * 0.44),
               controlPoint2: NSPoint(x: d * 0.53, y: d * 0.47))
    brow.curve(to: NSPoint(x: d * 0.96, y: d * 0.64),
               controlPoint1: NSPoint(x: d * 0.72, y: d * 0.67),
               controlPoint2: NSPoint(x: d * 0.87, y: d * 0.83))
    brow.curve(to: NSPoint(x: d * 0.52, y: d * 0.27),
               controlPoint1: NSPoint(x: d * 0.82, y: d * 0.52),
               controlPoint2: NSPoint(x: d * 0.63, y: d * 0.42))
    brow.line(to: NSPoint(x: d * 0.50, y: d * 0.24))
    brow.line(to: NSPoint(x: d * 0.48, y: d * 0.27))
    brow.curve(to: NSPoint(x: d * 0.04, y: d * 0.64),
               controlPoint1: NSPoint(x: d * 0.37, y: d * 0.42),
               controlPoint2: NSPoint(x: d * 0.18, y: d * 0.52))
    brow.close()
    brow.fill()

    // Lower eyes are background-colored cutouts inside the white mask.
    bg.setFill()
    func eye(_ cx: CGFloat, flip: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx - d * 0.17 * flip, y: d * 0.43))
        p.curve(to: NSPoint(x: cx + d * 0.15 * flip, y: d * 0.35),
                controlPoint1: NSPoint(x: cx - d * 0.09 * flip, y: d * 0.25),
                controlPoint2: NSPoint(x: cx + d * 0.08 * flip, y: d * 0.24))
        p.curve(to: NSPoint(x: cx + d * 0.20 * flip, y: d * 0.48),
                controlPoint1: NSPoint(x: cx + d * 0.19 * flip, y: d * 0.39),
                controlPoint2: NSPoint(x: cx + d * 0.21 * flip, y: d * 0.43))
        p.curve(to: NSPoint(x: cx - d * 0.17 * flip, y: d * 0.43),
                controlPoint1: NSPoint(x: cx + d * 0.08 * flip, y: d * 0.43),
                controlPoint2: NSPoint(x: cx - d * 0.04 * flip, y: d * 0.50))
        p.close()
        p.fill()
    }
    eye(d * 0.34, flip: 1)
    eye(d * 0.66, flip: -1)
    return img
}

func owlImage(for status: Status, diameter d: CGFloat, appearance: NSAppearance? = nil) -> NSImage {
    faceImage(background: statusColor(status, appearance: appearance),
              foreground: faceForeground(for: status, appearance: appearance),
              diameter: d)
}

func appIconImage(diameter d: CGFloat) -> NSImage {
    faceImage(background: NSColor(hex: "E96945"), foreground: .white, diameter: d)
}

func bundledStatusIconName(for status: Status, appearance: NSAppearance? = nil) -> String {
    switch status {
    case .running: return "StatusRunning"
    case .waiting: return "StatusWaiting"
    case .error: return "StatusError"
    case .idle:
        let app = appearance ?? NSApp.effectiveAppearance
        let dark = app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? "StatusIdleDark" : "StatusIdleLight"
    }
}

func bundledStatusIcon(for status: Status, diameter d: CGFloat, appearance: NSAppearance? = nil) -> NSImage? {
    let name = bundledStatusIconName(for: status, appearance: appearance)
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: d, height: d)
    return img
}

func statusIcon(for status: Status, diameter d: CGFloat, appearance: NSAppearance? = nil) -> NSImage {
    bundledStatusIcon(for: status, diameter: d, appearance: appearance)
        ?? owlImage(for: status, diameter: d, appearance: appearance)
}

// MARK: - Theme (Claude cream / charcoal palette, design/claudedot.html)

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: alpha)
    }
}

// Palette per design/DESIGN.md (project source-of-truth): warm cream / charcoal,
// a single terracotta accent, green for done. Two themes share token names.
struct Theme {
    let canvas, surface, raise, border, borderSoft: NSColor
    let ink, ink2, ink3, accent, accent2, green, danger: NSColor
    let codeBg: NSColor
    let isDark: Bool

    static let light = Theme(
        canvas: NSColor(hex: "D2CCBD"), surface: NSColor(hex: "F7F4EC"), raise: NSColor(hex: "FBFAF5"),
        border: NSColor(hex: "E3DCCB"), borderSoft: NSColor(hex: "EBE5D7"),
        ink: NSColor(hex: "2B2A27"), ink2: NSColor(hex: "6B6760"), ink3: NSColor(hex: "9A968C"),
        accent: NSColor(hex: "E96945"), accent2: NSColor(hex: "D99A82"), green: NSColor(hex: "6B8E5E"),
        danger: NSColor(hex: "B0432B"),
        codeBg: NSColor(srgbRed: 180/255, green: 165/255, blue: 135/255, alpha: 0.18), isDark: false)

    static let dark = Theme(
        canvas: NSColor(hex: "141310"), surface: NSColor(hex: "1F1F1E"), raise: NSColor(hex: "2E2C26"),
        border: NSColor(hex: "3A382F"), borderSoft: NSColor(hex: "322F29"),
        ink: NSColor(hex: "ECE8DD"), ink2: NSColor(hex: "A8A399"), ink3: NSColor(hex: "6F6B61"),
        accent: NSColor(hex: "E96945"), accent2: NSColor(hex: "9C5238"), green: NSColor(hex: "7A9B76"),
        danger: NSColor(hex: "D4604A"),
        codeBg: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28), isDark: true)

    static func current(_ appearance: NSAppearance) -> Theme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

// Rounding: 16px popover, ~10px rows, small pills.
enum R { static let sm: CGFloat = 6; static let md: CGFloat = 10; static let card: CGFloat = 16 }

// Fonts per DESIGN.md §3: Newsreader (serif) for display/body, JetBrains Mono
// for figures, SF for tiny labels. No external fonts → serif = New York.
func display(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.serif) { return NSFont(descriptor: d, size: size) ?? base }
    return base
}
func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}
func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

// MARK: - View models

struct UsageStats {
    var todayTokens = 0          // tokens across all sessions today (UTC)
    var todayMessages = 0        // assistant turns today
    var sessionsToday = 0        // distinct sessions active today
    var liveTokens = 0           // sum over currently non-idle sessions
    var topModel = ""
    var topModelShare = 0.0
    // Subscription limits scraped from /status (via cc_usage_probe.py). nil until
    // the first probe completes.
    var weekPct: Int?
    var sessionPct: Int?
    var weekReset: String?
    var sessionReset: String?
    var highContextPct: Int?
}

struct SessionVM {
    var s: Session
    var tokens: Int
}

// MARK: - Custom views

// Status dot with an animated pulse ring for running/waiting.
final class DotView: NSView {
    let status: Status
    init(status: Status) {
        self.status = status
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 14).isActive = true
        heightAnchor.constraint(equalToConstant: 14).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = statusColor(status)
        let r: CGFloat = 3.5, cx = bounds.midX, cy = bounds.midY
        if status == .running || status == .waiting { // faint static base ring
            c.withAlphaComponent(0.45).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: cx-6, y: cy-6, width: 12, height: 12))
            ring.lineWidth = 1; ring.stroke()
        }
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx-r, y: cy-r, width: r*2, height: r*2)).fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, status == .running || status == .waiting, let layer = layer else { return }
        if layer.sublayers?.contains(where: { $0.name == "pulse" }) == true { return }
        let ring = CAShapeLayer()
        ring.name = "pulse"
        let c = statusColor(status)
        ring.path = CGPath(ellipseIn: CGRect(x: bounds.midX-6, y: bounds.midY-6, width: 12, height: 12), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = c.cgColor
        ring.lineWidth = 1
        ring.opacity = 0
        layer.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6; scale.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = status == .waiting ? 1.5 : 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: CGRect(x: bounds.midX-6, y: bounds.midY-6, width: 12, height: 12), transform: nil)
        ring.add(group, forKey: "pulse")
    }
}

// 20-segment usage bar (DESIGN.md §4): filled segments = accent, the single
// fractional segment = accent-2, the rest = border. Built from a live ratio.
final class SegBar: NSView {
    init(ratio: Double, theme: Theme) {
        super.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 5).isActive = true
        translatesAutoresizingMaskIntoConstraints = false
        let segs = 20
        let filled = max(0, min(Double(segs), ratio * Double(segs)))
        let full = Int(filled.rounded(.down))
        let partial = filled - Double(full) > 0.05
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for i in 0..<segs {
            let seg = NSView()
            seg.wantsLayer = true
            seg.layer?.cornerRadius = 1
            let color: NSColor = i < full ? theme.accent : (i == full && partial ? theme.accent2 : theme.border)
            seg.layer?.backgroundColor = color.cgColor
            stack.addArrangedSubview(seg)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A clickable row with a hover highlight (used for sessions + footer items).
final class HoverRow: NSView {
    var onClick: (() -> Void)?
    private let theme: Theme
    private var tracking: NSTrackingArea?
    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = R.md
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = theme.raise.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
    override func mouseUp(with event: NSEvent) { onClick?() }
}

// MARK: - Popover builder

struct PopoverHandlers {
    var jump: (Int32?, String, Bool) -> Void = { _, _, _ in }
    var newSession: () -> Void = {}
    var viewLogs: () -> Void = {}
    var preferences: () -> Void = {}
    var quit: () -> Void = {}
    // Dynamic Island toggle wired to the footer "Dynamic Island" item. nil
    // hides the row in contexts (snapshot mode) that have no island.
    var toggleIsland: (() -> Void)?
    var islandEnabled: Bool = false
}

func buildPopover(sessions: [SessionVM], stats statsIn: UsageStats, theme: Theme, handlers: PopoverHandlers) -> NSView {
    var stats = statsIn
    stats.liveTokens = sessions.filter { $0.s.status != .idle }.reduce(0) { $0 + $1.tokens }
    let W: CGFloat = 336
    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 0
    root.translatesAutoresizingMaskIntoConstraints = false
    root.wantsLayer = true
    root.layer?.backgroundColor = theme.surface.cgColor
    root.widthAnchor.constraint(equalToConstant: W).isActive = true

    func add(_ v: NSView) {
        root.addArrangedSubview(v)
        v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
        v.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
    }
    func label(_ s: String, _ f: NSFont, _ c: NSColor, _ align: NSTextAlignment = .left) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = f; t.textColor = c; t.alignment = align
        t.lineBreakMode = .byTruncatingTail
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }
    func divider() -> NSView {
        let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = theme.borderSoft.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }
    func pad(_ v: NSView, _ t: CGFloat, _ l: CGFloat, _ b: CGFloat, _ r: CGFloat) -> NSView {
        let box = NSView(); box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: t),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: l),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -b),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -r),
        ])
        return box
    }

    // ── 1) HEADER ──
    let mark = NSMutableAttributedString()
    mark.append(NSAttributedString(string: "✳ ", attributes: [.foregroundColor: theme.accent, .font: display(13, .medium)]))
    mark.append(NSAttributedString(string: "Claude ", attributes: [.foregroundColor: theme.ink, .font: display(20, .semibold)]))
    mark.append(NSAttributedString(string: "Dot", attributes: [.foregroundColor: theme.accent, .font: display(20, .semibold)]))
    let markLabel = NSTextField(labelWithAttributedString: mark)
    markLabel.translatesAutoresizingMaskIntoConstraints = false
    // Decay stale-running sessions (effectiveStatus) so this split matches the
    // owl glyph, the menu-bar badge, and the "N active" label below.
    let runCount = statusCount(sessions.map { $0.s }, .running)
    let waitCount = statusCount(sessions.map { $0.s }, .waiting)
    let rightStack = NSStackView(views: [
        capLabel("RUNNING · WAITING", theme, .right),
        label("\(runCount) · \(waitCount)", mono(12, .medium), theme.ink, .right),
    ])
    rightStack.orientation = .vertical; rightStack.alignment = .trailing; rightStack.spacing = 3
    rightStack.translatesAutoresizingMaskIntoConstraints = false
    let headRow = NSStackView(views: [markLabel, NSView(), rightStack])
    headRow.orientation = .horizontal; headRow.alignment = .centerY
    headRow.translatesAutoresizingMaskIntoConstraints = false
    add(pad(headRow, 16, 18, 12, 18))

    // ── 2) USAGE METER (today's token usage) ──
    let usage = NSStackView()
    usage.orientation = .vertical; usage.alignment = .leading; usage.spacing = 11
    usage.translatesAutoresizingMaskIntoConstraints = false

    // HERO: when the /status probe has reported, lead with the CURRENT-SESSION
    // limit % (the live usage window) + its reset; else fall back to today's
    // token count. (Weekly limit is intentionally not shown.)
    let hero = NSMutableAttributedString()
    let heroRight: NSStackView
    if let sp = stats.sessionPct {
        hero.append(NSAttributedString(string: "\(sp)", attributes: [.foregroundColor: theme.ink, .font: display(40, .regular), .kern: -1.5]))
        hero.append(NSAttributedString(string: "%", attributes: [.foregroundColor: theme.ink3, .font: display(20, .regular)]))
        hero.append(NSAttributedString(string: "  session used", attributes: [.foregroundColor: theme.ink3, .font: ui(11)]))
        heroRight = NSStackView(views: [
            label("Resets", ui(10), theme.ink3, .right),
            label(stats.sessionReset ?? "—", mono(11, .medium), theme.ink2, .right),
        ])
    } else {
        hero.append(NSAttributedString(string: formatCount(stats.todayTokens), attributes: [.foregroundColor: theme.ink, .font: display(40, .regular), .kern: -1.0]))
        hero.append(NSAttributedString(string: "  tokens today", attributes: [.foregroundColor: theme.ink3, .font: ui(11)]))
        heroRight = NSStackView(views: [
            label("Top model", ui(10), theme.ink3, .right),
            label(stats.topModel.isEmpty ? "—" : stats.topModel, mono(11, .medium), theme.ink2, .right),
        ])
    }
    let heroLabel = NSTextField(labelWithAttributedString: hero)
    heroLabel.translatesAutoresizingMaskIntoConstraints = false
    heroRight.orientation = .vertical; heroRight.alignment = .trailing; heroRight.spacing = 1
    heroRight.translatesAutoresizingMaskIntoConstraints = false
    let topRow = NSStackView(views: [heroLabel, NSView(), heroRight])
    topRow.orientation = .horizontal; topRow.alignment = .lastBaseline
    topRow.translatesAutoresizingMaskIntoConstraints = false
    topRow.widthAnchor.constraint(equalToConstant: W - 36).isActive = true
    usage.addArrangedSubview(topRow)

    // BAR: current-session fill when available, else today-vs-peak.
    let ratio: Double = stats.sessionPct.map { Double($0) / 100 }
        ?? 0  // no /status data yet → hero falls back to today's tokens, bar empty
    let bar = SegBar(ratio: ratio, theme: theme)
    usage.addArrangedSubview(bar)
    bar.widthAnchor.constraint(equalToConstant: W - 36).isActive = true

    // FOOT micro-stats — today-oriented.
    let footItems: [NSView] = [
        footStat("Today", formatCount(stats.todayTokens), theme), NSView(),
        footStat("Msgs", "\(stats.todayMessages)", theme), NSView(),
        footStat("Sessions", "\(stats.sessionsToday)", theme),
    ]
    let foot = NSStackView(views: footItems)
    foot.orientation = .horizontal; foot.alignment = .firstBaseline; foot.spacing = 6
    foot.translatesAutoresizingMaskIntoConstraints = false
    foot.widthAnchor.constraint(equalToConstant: W - 36).isActive = true
    usage.addArrangedSubview(foot)
    add(pad(usage, 4, 18, 16, 18))

    add(divider())

    // ── 3) SESSIONS LIST ──
    let active = activeCount(sessions.map { $0.s })
    let cap = NSStackView(views: [
        capLabel("SESSIONS", theme),
        NSView(),
        label("\(active) active", mono(9, .regular), theme.ink3, .right),
    ])
    cap.orientation = .horizontal
    cap.translatesAutoresizingMaskIntoConstraints = false
    add(pad(cap, 13, 18, 6, 18))

    let list = NSStackView()
    list.orientation = .vertical; list.alignment = .leading; list.spacing = 1
    list.translatesAutoresizingMaskIntoConstraints = false

    if sessions.isEmpty {
        let empty = label("No active sessions", ui(12), theme.ink3)
        list.addArrangedSubview(pad(empty, 6, 10, 10, 10))
    }

    // Cap the visible rows so a long backlog can't push the footer off-screen;
    // sessions are pre-sorted (attention first, then most recent) so the head is
    // the relevant slice. The hidden tail is surfaced via a "+N more" hint.
    let rowCap = 10
    let visibleSessions = Array(sessions.prefix(rowCap))
    for vm in visibleSessions {
        let s = vm.s
        let row = HoverRow(theme: theme)
        row.onClick = { handlers.jump(s.pid, s.cwd, s.isDesktop) }

        let dot = DotView(status: s.status)

        let nameLine = NSMutableAttributedString()
        nameLine.append(NSAttributedString(string: s.folder, attributes: [.foregroundColor: theme.ink, .font: display(15, .medium)]))
        let prettyPath = (s.cwd as NSString).abbreviatingWithTildeInPath
        if !prettyPath.isEmpty {
            nameLine.append(NSAttributedString(string: "  \(prettyPath)", attributes: [.foregroundColor: theme.ink3, .font: mono(10)]))
        }
        let nameLabel = NSTextField(labelWithAttributedString: nameLine)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        // Yield horizontally so a long folder+path truncates (middle) instead of
        // wrapping to a second line and inflating the row height.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let (statusText, attn) = statusLine(for: s)
        let stLabel = label(statusText, ui(11), attn ? theme.accent : theme.ink2)

        let infoStack = NSStackView(views: [nameLabel, stLabel])
        infoStack.orientation = .vertical; infoStack.alignment = .leading; infoStack.spacing = 1
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        let tok = label(vm.tokens > 0 ? formatCount(vm.tokens) : "", mono(10), theme.ink3, .right)
        let rowStack = NSStackView(views: [dot, infoStack, NSView(), tok])
        rowStack.orientation = .horizontal; rowStack.alignment = .centerY; rowStack.spacing = 11
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            rowStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
            rowStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
        ])
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true

        // Approval panel for waiting sessions — jump to the terminal to respond.
        if s.status == .waiting {
            let panel = NSStackView()
            panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 7
            panel.translatesAutoresizingMaskIntoConstraints = false

            let q = NSMutableAttributedString()
            let (verb, toolLabel) = approvalPrompt(pendingTool: s.pendingTool)
            q.append(NSAttributedString(string: "\(verb) ", attributes: [.foregroundColor: theme.ink2, .font: ui(11)]))
            if let input = s.pendingInput, !input.isEmpty {
                q.append(NSAttributedString(string: "\(toolLabel) ", attributes: [.foregroundColor: theme.ink2, .font: ui(11)]))
                q.append(codePill(input, theme))
            } else {
                q.append(NSAttributedString(string: toolLabel, attributes: [.foregroundColor: theme.ink, .font: ui(11, .medium)]))
            }
            let qLabel = NSTextField(labelWithAttributedString: q)
            qLabel.lineBreakMode = .byTruncatingTail
            qLabel.translatesAutoresizingMaskIntoConstraints = false
            qLabel.widthAnchor.constraint(equalToConstant: W - 56).isActive = true
            panel.addArrangedSubview(qLabel)

            let jumpRow = HoverRow(theme: theme)
            jumpRow.onClick = { handlers.jump(s.pid, s.cwd, s.isDesktop) }
            let jumpLabel = label(s.isDesktop ? "→  Jump to Claude to respond" : "→  Jump to terminal to respond",
                                  ui(12, .medium), theme.ink)
            jumpRow.addSubview(jumpLabel)
            NSLayoutConstraint.activate([
                jumpLabel.topAnchor.constraint(equalTo: jumpRow.topAnchor, constant: 6),
                jumpLabel.bottomAnchor.constraint(equalTo: jumpRow.bottomAnchor, constant: -6),
                jumpLabel.leadingAnchor.constraint(equalTo: jumpRow.leadingAnchor, constant: 2),
                jumpLabel.trailingAnchor.constraint(equalTo: jumpRow.trailingAnchor, constant: -2),
            ])
            panel.addArrangedSubview(jumpRow)
            jumpRow.widthAnchor.constraint(equalToConstant: W - 56).isActive = true

            let box = pad(panel, 2, 28, 8, 14)
            list.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
    if sessions.count > visibleSessions.count {
        let more = label("+\(sessions.count - visibleSessions.count) more", ui(11), theme.ink3)
        list.addArrangedSubview(pad(more, 6, 12, 8, 12))
    }
    add(pad(list, 0, 8, 6, 8))

    add(divider())

    // ── 4) FOOTER MENU ──
    let footMenu = NSStackView()
    footMenu.orientation = .vertical; footMenu.alignment = .leading; footMenu.spacing = 1
    footMenu.translatesAutoresizingMaskIntoConstraints = false
    func footItem(_ icon: String, _ title: String, _ kbd: String, _ action: @escaping () -> Void) {
        let r = HoverRow(theme: theme)
        r.onClick = action
        let ic = label(icon, ui(13), theme.ink3); ic.alignment = .center
        ic.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let tl = label(title, ui(13.5), theme.ink2)
        let kb = label(kbd, mono(9.5), theme.ink3, .right)
        let hs = NSStackView(views: [ic, tl, NSView(), kb])
        hs.orientation = .horizontal; hs.alignment = .centerY; hs.spacing = 10
        hs.translatesAutoresizingMaskIntoConstraints = false
        r.addSubview(hs)
        NSLayoutConstraint.activate([
            hs.topAnchor.constraint(equalTo: r.topAnchor, constant: 8),
            hs.bottomAnchor.constraint(equalTo: r.bottomAnchor, constant: -8),
            hs.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 13),
            hs.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -13),
        ])
        footMenu.addArrangedSubview(r)
        r.widthAnchor.constraint(equalTo: footMenu.widthAnchor).isActive = true
    }
    footItem("✳", "New session", "⌘N", handlers.newSession)
    footItem("⊟", "View all logs", "", handlers.viewLogs)
    if let toggle = handlers.toggleIsland {
        footItem(handlers.islandEnabled ? "◉" : "○", "Dynamic Island", "", toggle)
    }
    footItem("⚙", "Preferences", "⌘,", handlers.preferences)
    footItem("⏻", "Quit", "⌘Q", handlers.quit)
    add(pad(footMenu, 5, 5, 5, 5))

    return root
}

// Section caption per DESIGN.md §3: 9px SF, uppercase, letter-spacing 1.5, ink-3.
func capLabel(_ s: String, _ theme: Theme, _ align: NSTextAlignment = .left) -> NSTextField {
    let a = NSAttributedString(string: s, attributes: [
        .font: ui(9, .semibold), .foregroundColor: theme.ink3, .kern: 1.5])
    let t = NSTextField(labelWithAttributedString: a)
    t.alignment = align
    t.lineBreakMode = .byClipping
    t.translatesAutoresizingMaskIntoConstraints = false
    return t
}

func footStat(_ label: String, _ value: String, _ theme: Theme) -> NSView {
    let a = NSMutableAttributedString()
    a.append(NSAttributedString(string: "\(label) ", attributes: [.foregroundColor: theme.ink3, .font: mono(10)]))
    a.append(NSAttributedString(string: value, attributes: [.foregroundColor: theme.ink2, .font: mono(10, .medium)]))
    let t = NSTextField(labelWithAttributedString: a)
    t.translatesAutoresizingMaskIntoConstraints = false
    return t
}

func codePill(_ text: String, _ theme: Theme) -> NSAttributedString {
    NSAttributedString(string: " \(text) ", attributes: [
        .foregroundColor: theme.ink, .font: mono(9.5),
        .backgroundColor: theme.codeBg,
    ])
}

func statusLine(for s: Session) -> (String, Bool) {
    switch s.status {
    case .waiting:
        let tool = s.pendingTool.map { " · \($0)" } ?? ""
        return ("Awaiting approval\(tool)", true)
    case .running:
        let ev = s.lastEvent.isEmpty ? "Working…" : s.lastEvent
        return (ev, false)
    case .error:
        return (s.lastError ?? s.lastEvent, false)
    case .idle:
        let ev = s.lastEvent.isEmpty ? "Idle" : s.lastEvent
        return ("\(ev) · \(relativeAge(s.updatedAt))", false)
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let nativeDir = NSString(string: "~/.claude/sessions").expandingTildeInPath
    let hookDir = NSString(string: "~/.claude/statusbar/sessions").expandingTildeInPath
    let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
    // Claude Desktop's own session registry (Cowork / agent mode). Private to the
    // desktop app and version-fragile — schema may change across Claude releases.
    let desktopDir = NSString(string: "~/Library/Application Support/Claude/claude-code-sessions").expandingTildeInPath
    // The activity window for Desktop sessions (excludes scheduled-task bots,
    // keeps ~24h of activity) lives in Model.swift as `desktopDoneWindow`, shared
    // with the testable `filterWelcomeSessions` rule loadDesktop applies below.
    // /status scraper (subscription limits) — script, output cache, scratch dir.
    let probeScript = NSString(string: "~/.claude/statusbar/cc_usage_probe.py").expandingTildeInPath
    let usagePath = NSString(string: "~/.claude/statusbar/usage.json").expandingTildeInPath
    let probeDir = NSString(string: "~/.claude/statusbar/probe").expandingTildeInPath
    var lastProbe: Double = 0
    // Heavy transcript parsing runs here (serial) — never on the main thread, so
    // clicking the icon shows the popover instantly. Caches below are read/written
    // ONLY on this queue (+ handed to main); main renders from cachedVMs/Stats.
    let dataQueue = DispatchQueue(label: "com.claudecode.statusbar.data", qos: .userInitiated)
    var cachedVMs: [SessionVM] = []
    var cachedStats = UsageStats()
    let menuBarIconSize: CGFloat = 18
    var timer: Timer?
    // Observes the menu-bar appearance so the glyph + an open popover follow a
    // live macOS Light/Dark switch immediately (DESIGN.md §13: follow system
    // appearance). Without this the icon only catches up on the next 1.5s tick
    // and an already-open popover keeps its stale theme until reopened.
    var appearanceObserver: NSKeyValueObservation?
    // KVO on effectiveAppearance fires once per view-layer during a switch (dozens
    // of times); this coalesces the burst into a single re-skin.
    var appearanceWork: DispatchWorkItem?
    let popover = NSPopover()
    // Stable content view — we swap its CHILDREN on re-render, never the view
    // object itself, so updating a shown transient popover doesn't dismiss it.
    let popoverHost = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: 200))
    var lastSignature = ""
    // Global mouse monitor that dismisses the popover on any click outside our
    // app (a reliable backstop to .transient for status-item popovers).
    var clickMonitor: Any?

    // Top-center floating "island" (DynamicIsland.swift). Coexists with the
    // menu-bar owl; default ON, persisted in UserDefaults. Fed from the same
    // cached vms/stats the popover already builds.
    let island = DynamicIslandController()

    // transcript token cache: sessionId -> (file offset already read, running total)
    var tokenOffset: [String: UInt64] = [:]
    var tokenTotal: [String: Int] = [:]
    var transcriptPath: [String: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if anotherInstanceRunning() { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.image = statusIcon(for: .idle, diameter: menuBarIconSize,
                                              appearance: statusItem.button?.effectiveAppearance)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = popoverHost
        island.onJump = { [weak self] pid, cwd, isDesktop in
            self?.jump(pid: pid, cwd: cwd, isDesktop: isDesktop)
        }
        island.onOpenPopover = { [weak self] in self?.togglePopover() }
        refresh()
        refreshPopoverData(loadSessions()) // warm the cache so the first click is instant
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        // Follow live system Light/Dark switches. Observe the APP's
        // effectiveAppearance (it tracks the system setting), not the status
        // button's (which tracks the menu bar and can be dark in Light mode).
        // KVO fires once AppKit has resolved the new appearance, so reading it
        // back in the handler is safe.
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self = self else { return }
            self.appearanceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.appearanceDidChange() }
            self.appearanceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    // Re-skin for the current system appearance: re-render the menu-bar glyph and
    // rebuild an open popover in the new theme (the data signature is unchanged
    // by a theme switch, so refresh() alone won't rebuild it). Uses cached data —
    // no disk I/O — since the sessions haven't changed, only the colors.
    func appearanceDidChange() {
        let agg = aggregateStatus(cachedVMs.map { $0.s })
        statusItem.button?.image = statusIcon(for: agg, diameter: menuBarIconSize,
                                              appearance: statusItem.button?.effectiveAppearance)
        if popover.isShown { renderPopover(vms: cachedVMs, stats: cachedStats) }
        island.update(sessions: cachedVMs, theme: Theme.current(NSApp.effectiveAppearance))
    }

    func anotherInstanceRunning() -> Bool {
        let me = NSRunningApplication.current
        let running = NSWorkspace.shared.runningApplications
        if let bid = me.bundleIdentifier {
            return running.contains { $0.bundleIdentifier == bid && $0.processIdentifier != me.processIdentifier }
        }
        return running.contains { $0.executableURL == me.executableURL && $0.processIdentifier != me.processIdentifier }
    }

    func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    func loadNative() -> [NativeSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: nativeDir) else { return [] }
        var result: [NativeSession] = []
        for file in files where file.hasSuffix(".json") {
            let path = (nativeDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let n = NativeSession(json: obj) else { continue }
            if !pidAlive(n.pid) { continue }
            if n.cwd == probeDir { continue } // our own /status probe — never show it
            result.append(n)
        }
        return result
    }

    func loadHookStates() -> [String: Session] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: hookDir) else { return [:] }
        var map: [String: Session] = [:]
        for file in files where file.hasSuffix(".json") {
            let path = (hookDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = Session(json: obj) else { continue }
            map[s.id] = s
        }
        return map
    }

    // Scan Claude Desktop's session registry (two levels: account/workspace).
    // A cheap transcript-mtime gate runs before the tail read; surviving sessions
    // get a status inferred from their transcript tail, and only non-idle ones are
    // kept (idle = nothing to show; merge would drop them anyway).
    // `liveDesktopIds`: cliSessionIds whose pid is alive in the native registry —
    // for those we bypass the mtime gate. The session can sit quietly on a
    // user-blocking question for hours; the gate would have dropped it.
    func loadDesktop(liveDesktopIds: Set<String> = []) -> [DesktopSession] {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        // Phase 1: parse every non-archived desktop session file.
        var parsed: [DesktopSession] = []
        guard let accounts = try? fm.contentsOfDirectory(atPath: desktopDir) else { return [] }
        for acct in accounts {
            let acctPath = (desktopDir as NSString).appendingPathComponent(acct)
            guard let workspaces = try? fm.contentsOfDirectory(atPath: acctPath) else { continue }
            for ws in workspaces {
                let wsPath = (acctPath as NSString).appendingPathComponent(ws)
                guard let files = try? fm.contentsOfDirectory(atPath: wsPath) else { continue }
                for file in files where file.hasPrefix("local_") && file.hasSuffix(".json") {
                    let path = (wsPath as NSString).appendingPathComponent(file)
                    guard let data = fm.contents(atPath: path),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let d = DesktopSession(json: obj) else { continue }
                    parsed.append(d)
                }
            }
        }
        // Phase 2: apply the welcome-page inclusion rule — drops scheduled-task
        // bot sessions outright and anything quiet beyond ~24h. Live (pid alive)
        // sessions bypass the age gate (they can sit on a blocking question for
        // hours, and that quiet IS the wait), but a live *scheduled* bot is still
        // excluded.
        var candidates = filterWelcomeSessions(parsed, now: now)
        let candidateIds = Set(candidates.map { $0.sessionId })
        for d in parsed where liveDesktopIds.contains(d.sessionId)
            && !d.isScheduled && !candidateIds.contains(d.sessionId) {
            candidates.append(d)
        }
        // Phase 3: judge each candidate's status from its transcript tail.
        var result: [DesktopSession] = []
        for d0 in candidates {
            var d = d0
            let isLive = liveDesktopIds.contains(d.sessionId)
            // Activity is judged by the TRANSCRIPT mtime, not the file's
            // lastActivityAt — the latter lags by minutes (it tracks UI focus,
            // not work). Stat is cheap; only read the tail within the window.
            guard let tpath = findTranscript(d.sessionId) else { continue }
            let mtime = ((try? fm.attributesOfItem(atPath: tpath))?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            // Dead sessions still respect the ~24h window on the transcript mtime
            // so the scanner stays cheap on long histories; live ones always read.
            if !isLive && now - mtime >= desktopDoneWindow { continue }
            let tail = transcriptTail(d.sessionId)
            d.updatedAt = mtime
            d.status = inferDesktopStatus(pendingTool: tail.pendingTool, mtime: mtime, now: now)
            if d.status != .idle { result.append(d) } // idle = nothing to surface
        }
        return result
    }

    func loadSessions() -> [Session] {
        let n = loadNative()
        var liveDesktopIds = Set<String>()
        for s in n where s.entrypoint == "claude-desktop" { liveDesktopIds.insert(s.sessionId) }
        return mergeSessions(native: n, hooks: loadHookStates(),
                             desktop: loadDesktop(liveDesktopIds: liveDesktopIds))
    }

    // Read the tail of a session's transcript (last ~64KB only, so huge files
    // stay cheap): returns the tool name it ends on with no answer (nil if none)
    // and the file's mtime — the two inputs to inferDesktopStatus.
    // 64KB was 16KB; a single tool_result with a long stdout dump can be ~30KB
    // and would shove the role markers we look for out of a 16KB window, so a
    // session that's actually mid-Bash would parse as "no pending" and decay
    // to idle. 64KB comfortably covers a few full turns.
    func transcriptTail(_ id: String) -> (pendingTool: String?, mtime: Double) {
        guard let path = findTranscript(id) else { return (nil, 0) }
        let fm = FileManager.default
        let mtime = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, mtime) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return (nil, mtime) }
        // If we seeked into the middle, drop the leading partial line.
        var slice = data
        if start > 0, let firstNL = data.firstIndex(of: 0x0A) {
            slice = data.subdata(in: (firstNL + 1)..<data.endIndex)
        }
        var lines: [[String: Any]] = []
        for raw in slice.split(separator: 0x0A) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] { lines.append(obj) }
        }
        return (transcriptPendingTool(lines), mtime)
    }

    // Locate a session's transcript .jsonl under ~/.claude/projects/*/.
    func findTranscript(_ id: String) -> String? {
        if let p = transcriptPath[id] { return p }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for d in dirs {
            let candidate = (projectsDir as NSString).appendingPathComponent(d) + "/\(id).jsonl"
            if fm.fileExists(atPath: candidate) { transcriptPath[id] = candidate; return candidate }
        }
        return nil
    }

    // Incrementally read a transcript and accumulate its token total. Transcripts
    // only append, so we remember the byte offset already parsed and read forward.
    func tokensFor(_ id: String) -> Int {
        guard let path = findTranscript(id) else { return tokenTotal[id] ?? 0 }
        guard let handle = FileHandle(forReadingAtPath: path) else { return tokenTotal[id] ?? 0 }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var offset = tokenOffset[id] ?? 0
        if size < offset { offset = 0; tokenTotal[id] = 0 } // file shrank/rotated -> reparse
        if size == offset { return tokenTotal[id] ?? 0 }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return tokenTotal[id] ?? 0 }
        // Only parse through the last newline; stash offset at that boundary.
        guard let lastNL = data.lastIndex(of: 0x0A) else { return tokenTotal[id] ?? 0 }
        let complete = data.subdata(in: data.startIndex..<(lastNL + 1))
        var lines: [[String: Any]] = []
        for raw in complete.split(separator: 0x0A) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] { lines.append(obj) }
        }
        let added = sessionTokenTotal(lines)
        tokenTotal[id] = (tokenTotal[id] ?? 0) + added
        tokenOffset[id] = offset + UInt64(complete.count)
        return tokenTotal[id] ?? 0
    }

    // Per-file usage cache, keyed by transcript path. Each file contributes its
    // tokens-by-UTC-date, plus today's message count and per-model breakdown.
    // (~/.claude/stats-cache.json is NOT used — it can lag by weeks, so usage is
    //  derived straight from the freshest source: the transcripts.)
    struct UsageFile { var mtime: Double; var todayTokens: Int; var todayMsgs: Int; var todayByModel: [String: Int] }
    var usageFileCache: [String: UsageFile] = [:]

    func loadTodayUsage() -> UsageStats {
        let fm = FileManager.default
        // Transcript timestamps are UTC ("…Z"); bucket dates in UTC to match.
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
        let today = df.string(from: Date())
        // Only files touched in the last ~26h can contain today's (UTC) lines —
        // skip everything older so we never re-read the big historical transcripts.
        let cutoff = Date().timeIntervalSince1970 - 26 * 3600

        var tokens = 0, msgs = 0, sessions = 0
        var byModel: [String: Int] = [:]
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return UsageStats() }
        for d in dirs {
            let dpath = (projectsDir as NSString).appendingPathComponent(d)
            guard let files = try? fm.contentsOfDirectory(atPath: dpath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = dpath + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      mtime >= cutoff else { continue }

                let rec: UsageFile
                if let c = usageFileCache[path], c.mtime == mtime {
                    rec = c // unchanged since last scan -> reuse
                } else {
                    var tToks = 0, tMsgs = 0; var tModel: [String: Int] = [:]
                    if let data = fm.contents(atPath: path), let str = String(data: data, encoding: .utf8) {
                        for line in str.split(separator: "\n") {
                            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                                  let ts = o["timestamp"] as? String, ts.hasPrefix(today),
                                  let m = o["message"] as? [String: Any],
                                  let usage = m["usage"] as? [String: Any] else { continue }
                            let t = sessionTokenTotal([["message": ["usage": usage]]], includeCacheRead: false)
                            tToks += t; tMsgs += 1
                            tModel[(m["model"] as? String) ?? "?", default: 0] += t
                        }
                    }
                    rec = UsageFile(mtime: mtime, todayTokens: tToks, todayMsgs: tMsgs, todayByModel: tModel)
                    usageFileCache[path] = rec
                }
                if rec.todayMsgs > 0 || rec.todayTokens > 0 {
                    tokens += rec.todayTokens; msgs += rec.todayMsgs; sessions += 1
                    for (k, v) in rec.todayByModel { byModel[k, default: 0] += v }
                }
            }
        }

        var st = UsageStats()
        st.todayTokens = tokens
        st.todayMessages = msgs; st.sessionsToday = sessions
        if let top = byModel.max(by: { $0.value < $1.value }), st.todayTokens > 0 {
            st.topModel = top.key.replacingOccurrences(of: "claude-", with: "")
            st.topModelShare = Double(top.value) / Double(st.todayTokens)
        }

        // Overlay subscription limits scraped by the /status probe (if fresh).
        if let data = fm.contents(atPath: usagePath),
           let u = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            st.weekPct = u["week_pct"] as? Int
            st.sessionPct = u["session_pct"] as? Int
            st.weekReset = u["week_reset"] as? String
            st.sessionReset = u["session_reset"] as? String
            st.highContextPct = u["high_context_pct"] as? Int
        }
        return st
    }

    // Spawn the /status probe in the background, at most every 10 min. Runs via a
    // login shell so `claude` is on PATH (LaunchAgent env is minimal). Fire and
    // forget — it writes usage.json which loadTodayUsage() picks up next refresh.
    func maybeProbe() {
        let now = Date().timeIntervalSince1970
        guard now - lastProbe > 600, FileManager.default.fileExists(atPath: probeScript) else { return }
        lastProbe = now
        let p = Process()
        p.launchPath = "/bin/zsh"
        p.arguments = ["-lc", "python3 '\(probeScript)' '\(usagePath)'"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run() // do NOT wait — it takes ~25s
    }

    func makeVMs(_ sessions: [Session]) -> [SessionVM] {
        sessions.map { SessionVM(s: $0, tokens: tokensFor($0.id)) }
    }

    func refresh() {
        maybeProbe()
        let sessions = loadSessions()
        let agg = aggregateStatus(sessions)
        // Same decayed-status rule as the popover and island (see effectiveStatus)
        // so the badge can't disagree with the owl glyph or the popover counts.
        let attention = sessions.filter { let e = effectiveStatus($0); return e == .error || e == .waiting }.count
        let running = statusCount(sessions, .running)
        statusItem.button?.image = statusIcon(for: agg, diameter: menuBarIconSize,
                                              appearance: statusItem.button?.effectiveAppearance)
        statusItem.button?.title = attention > 0 ? " \(attention)" : (running > 0 ? " \(running)" : "")

        // Push every tick to the Dynamic Island so its status dot/count stays
        // live without depending on the popover being open. Tokens aren't shown
        // in the island, so re-using cached values (else 0) avoids the heavy
        // transcript parse on the main thread.
        let cachedToks = Dictionary(uniqueKeysWithValues: cachedVMs.map { ($0.s.id, $0.tokens) })
        let fastVMs = sessions.map { SessionVM(s: $0, tokens: cachedToks[$0.id] ?? 0) }
        island.update(sessions: fastVMs, theme: Theme.current(NSApp.effectiveAppearance))

        // While open, refresh the popover's data in the background only when the
        // visible state actually changed (set lastSignature optimistically so we
        // don't re-kick every tick while the background task is in flight).
        if popover.isShown {
            let sig = signature(sessions)
            if sig != lastSignature { lastSignature = sig; refreshPopoverData(sessions) }
        }
    }

    // Identity of the visible popover content. Deliberately ORDER-INDEPENDENT
    // (sorted) and free of volatile fields like updatedAt: an active session's
    // transcript mtime ticks every poll and reorders the list, which would
    // otherwise rebuild the popover each tick and flicker it. Only a real change
    // (a session added/removed, a status change, a new pending input) rebuilds.
    func signature(_ sessions: [Session]) -> String {
        sessions.map { "\($0.id):\($0.status.rawValue):\($0.pendingInput ?? "")" }.sorted().joined(separator: "|")
    }

    // Parse transcripts + scrape usage off the main thread, then render on main.
    func refreshPopoverData(_ sessions: [Session]) {
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            let vms = self.makeVMs(sessions)
            let stats = self.loadTodayUsage()
            DispatchQueue.main.async {
                self.cachedVMs = vms
                self.cachedStats = stats
                if self.popover.isShown { self.renderPopover(vms: vms, stats: stats) }
                self.island.update(sessions: vms, theme: Theme.current(NSApp.effectiveAppearance))
            }
        }
    }

    // Build the popover's view tree from already-computed data. Main thread only
    // (AppKit), but cheap — no file parsing happens here.
    func renderPopover(vms: [SessionVM], stats: UsageStats) {
        // Use the APP appearance (follows the system Light/Dark setting), NOT the
        // status button's — the menu bar's appearance is often dark even in Light
        // mode (e.g. a dark wallpaper darkens the menu bar), which would pin the
        // popover to the dark theme forever. The glyph still uses the button
        // appearance so it contrasts the menu bar.
        let theme = Theme.current(NSApp.effectiveAppearance)
        let view = buildPopover(sessions: vms, stats: stats, theme: theme, handlers: handlers())
        // Replace only the host's children — keep the host (vc.view) identity so a
        // shown transient popover is not dismissed when content updates.
        popoverHost.wantsLayer = true
        popoverHost.subviews.forEach { $0.removeFromSuperview() }
        popoverHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: popoverHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: popoverHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: popoverHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: popoverHost.bottomAnchor),
        ])
        popoverHost.layoutSubtreeIfNeeded()
        popover.contentSize = view.fittingSize
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        let sessions = loadSessions()
        lastSignature = signature(sessions)
        // Show instantly from the cache (warmed at launch + kept fresh while open),
        // then update the content as soon as the background parse finishes.
        renderPopover(vms: cachedVMs, stats: cachedStats)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        // Backstop for outside-click dismissal: a click anywhere outside our app
        // closes the popover. (.transient alone is unreliable for status items.)
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
        refreshPopoverData(sessions)
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    func handlers() -> PopoverHandlers {
        var h = PopoverHandlers()
        h.jump = { [weak self] pid, cwd, isDesktop in self?.popover.performClose(nil); self?.jump(pid: pid, cwd: cwd, isDesktop: isDesktop) }
        h.newSession = { [weak self] in self?.popover.performClose(nil); self?.newSession() }
        h.viewLogs = { [weak self] in self?.popover.performClose(nil)
            NSWorkspace.shared.open(URL(fileURLWithPath: self?.projectsDir ?? "")) }
        h.preferences = { [weak self] in self?.popover.performClose(nil)
            NSWorkspace.shared.open(URL(fileURLWithPath: NSString(string: "~/.claude/settings.json").expandingTildeInPath)) }
        h.quit = { NSApp.terminate(nil) }
        h.islandEnabled = island.enabled
        h.toggleIsland = { [weak self] in
            guard let self = self else { return }
            self.island.enabled = !self.island.enabled
            // Re-render the popover so the footer item's icon flips immediately.
            if self.popover.isShown { self.renderPopover(vms: self.cachedVMs, stats: self.cachedStats) }
        }
        return h
    }

    func newSession() {
        let script = "tell application \"Terminal\"\n  do script \"claude\"\n  activate\nend tell"
        _ = runAppleScript(script)
    }

    // MARK: jump-to-session (reused by rows + approval panels)

    func jump(pid: Int32?, cwd: String, isDesktop: Bool = false) {
        // Desktop (Cowork / agent-mode) sessions can't be focused by tty and
        // can't be navigated to a specific conversation safely (the only
        // per-session deep link, claude://resume?session=, *imports* the CLI
        // session and forks a duplicate). The best we can safely do is bring the
        // desktop app forward. Its native pid (if any) just points back at
        // Claude.app, so skip the terminal probe entirely.
        if isDesktop {
            if activateClaudeDesktop() { return }
            if !cwd.isEmpty { openTerminalAt(cwd) }
            return
        }
        if let pid = pid, pid > 0 {
            if focusTerminalForPid(pid) { return }
            if let app = hostAppForPid(pid) { app.activate(options: [.activateIgnoringOtherApps]); return }
        }
        if !cwd.isEmpty { openTerminalAt(cwd) }
    }

    // Activate the Claude desktop app if it's running (regular GUI app whose
    // bundle id mentions "claude"; our own menu-bar app is .accessory, so it's
    // never matched here).
    func activateClaudeDesktop() -> Bool {
        let app = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular &&
            ($0.bundleIdentifier?.lowercased().contains("claude") ?? false)
        }
        app?.activate(options: [.activateIgnoringOtherApps])
        return app != nil
    }

    func ttyForPid(_ pid: Int32) -> String? {
        let proc = Process(); proc.launchPath = "/bin/ps"; proc.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard var t = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != "?", t != "??" else { return nil }
        if !t.hasPrefix("/dev/") { t = "/dev/" + t }
        return t
    }

    func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        return err == nil ? result.stringValue : nil
    }

    func focusTerminalForPid(_ pid: Int32) -> Bool {
        guard let tty = ttyForPid(pid) else { return false }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        if running.contains("com.apple.Terminal") {
            let script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    if tty of t is "\(tty)" then
                      set selected of t to true
                      try
                        set index of w to 1
                      end try
                      activate
                      return "1"
                    end if
                  end try
                end repeat
              end repeat
            end tell
            return "0"
            """
            if runAppleScript(script) == "1" { return true }
        }
        if running.contains("com.googlecode.iterm2") {
            let script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    try
                      if tty of s is "\(tty)" then
                        select w
                        select t
                        select s
                        activate
                        return "1"
                      end if
                    end try
                  end repeat
                end repeat
              end repeat
            end tell
            return "0"
            """
            if runAppleScript(script) == "1" { return true }
        }
        return false
    }

    func parentPid(of pid: Int32) -> Int32? {
        let proc = Process(); proc.launchPath = "/bin/ps"; proc.arguments = ["-o", "ppid=", "-p", "\(pid)"]
        let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.flatMap { Int32($0) }
    }

    func hostAppForPid(_ pid: Int32) -> NSRunningApplication? {
        var byPid: [Int32: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { byPid[app.processIdentifier] = app }
        var cur: Int32? = pid, hops = 0
        while let p = cur, p > 1, hops < 40 {
            if let app = byPid[p], app.activationPolicy == .regular { return app }
            cur = parentPid(of: p); hops += 1
        }
        return nil
    }

    func openTerminalAt(_ path: String) {
        let script = "tell application \"Terminal\" to do script \"cd \\\"\(path)\\\"\"\n" +
                     "tell application \"Terminal\" to activate"
        _ = runAppleScript(script)
    }
}

// MARK: - Snapshot mode (offscreen preview, no Screen Recording needed)

func demoData() -> ([SessionVM], UsageStats) {
    let now = Date().timeIntervalSince1970
    let sessions = [
        Session(id: "a", folder: "sample-api", cwd: "/Users/demo/work/sample-api", status: .waiting,
                lastEvent: "waiting · permission", updatedAt: now - 20, pid: 1,
                pendingTool: "Bash", pendingInput: "npm run build -- --dry-run"),
        Session(id: "b", folder: "ai-model-matrix", cwd: "/Users/x/dev/matrix", status: .waiting,
                lastEvent: "waiting · permission", updatedAt: now - 40, pid: 2,
                pendingTool: "WebFetch", pendingInput: "api.example.com/v1/status"),
        Session(id: "c", folder: "dashboard-app", cwd: "/Users/demo/work/dashboard", status: .running,
                lastEvent: "Running tests 14/38", updatedAt: now - 5, pid: 3),
        Session(id: "f", folder: "creator-dash", cwd: "/Users/demo/work/creator-dash", status: .running,
                lastEvent: "Desktop", updatedAt: now - 8, isDesktop: true),
        Session(id: "e", folder: "release-tools", cwd: "/Users/demo/work/release", status: .error,
                lastEvent: "error in Bash", lastError: "psql: connection refused", updatedAt: now - 60, pid: 5),
        Session(id: "d", folder: "benchmark-lab", cwd: "/Users/demo/work/bench", status: .idle,
                lastEvent: "Completed", updatedAt: now - 130, pid: 4),
    ]
    let toks = ["a": 8_200_000, "b": 21_700_000, "c": 15_900_000, "e": 3_100_000, "d": 22_400_000, "f": 6_500_000]
    let vms = sessions.map { SessionVM(s: $0, tokens: toks[$0.id] ?? 0) }
    var st = UsageStats()
    st.todayTokens = 12_400_000
    st.todayMessages = 342; st.sessionsToday = 5
    st.topModel = "opus-4-8"; st.topModelShare = 0.62
    st.weekPct = 68; st.sessionPct = 37
    st.weekReset = "Jun 3 at 2pm"; st.sessionReset = "1:40am"
    return (vms, st)
}

func renderSnapshot(to path: String) {
    let useReal = CommandLine.arguments.contains("--real")
    let (vms, stats): ([SessionVM], UsageStats)
    if useReal {
        let d = AppDelegate()
        let sessions = d.loadSessions()
        vms = d.makeVMs(sessions); stats = d.loadTodayUsage()
    } else {
        (vms, stats) = demoData()
    }
    func render(_ theme: Theme) -> NSBitmapImageRep {
        let view = buildPopover(sessions: vms, stats: stats, theme: theme, handlers: PopoverHandlers())
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 336, height: 100),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        win.setContentSize(size)
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    let lr = render(.light), dr = render(.dark)
    let gap: CGFloat = 28, pad: CGFloat = 28
    let w = lr.size.width + dr.size.width + gap + pad * 2
    let h = max(lr.size.height, dr.size.height) + pad * 2
    let out = NSImage(size: NSSize(width: w, height: h))
    out.lockFocus()
    NSColor(hex: "B8B0A0").setFill(); NSRect(x: 0, y: 0, width: w/2, height: h).fill()
    NSColor(hex: "0E0D0B").setFill(); NSRect(x: w/2, y: 0, width: w/2, height: h).fill()
    func place(_ rep: NSBitmapImageRep, _ x: CGFloat) {
        let y = h - pad - rep.size.height
        let r = NSRect(x: x, y: y, width: rep.size.width, height: rep.size.height)
        let clip = NSBezierPath(roundedRect: r, xRadius: R.card, yRadius: R.card)
        NSGraphicsContext.saveGraphicsState(); clip.addClip()
        rep.draw(in: r); NSGraphicsContext.restoreGraphicsState()
    }
    place(lr, pad)
    place(dr, pad + lr.size.width + gap)
    out.unlockFocus()
    let final = NSBitmapImageRep(data: out.tiffRepresentation!)!
    try? final.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  \(Int(w))x\(Int(h))  (left: light, right: dark)")
}

// Render the four menu-bar owl states as a labelled strip (for the README).
func renderOwls(to path: String) {
    let states: [(Status, String)] = [(.idle, "idle"), (.running, "running"), (.waiting, "needs input"), (.error, "error")]
    let d: CGFloat = 46, cellW: CGFloat = 132, rowH: CGFloat = 92, pad: CGFloat = 18
    let w = cellW * CGFloat(states.count) + pad * 2
    let h = rowH + pad * 2
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor(hex: "EFEAE0").setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    for (i, s) in states.enumerated() {
        let cx = pad + cellW * (CGFloat(i) + 0.5)
        statusIcon(for: s.0, diameter: d).draw(in: NSRect(x: cx - d/2, y: h - pad - d, width: d, height: d))
        let label = NSAttributedString(string: s.1, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(hex: "2B2A27")])
        let sz = label.size()
        label.draw(at: NSPoint(x: cx - sz.width/2, y: pad + 2))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  \(Int(w))x\(Int(h))")
}

// Offscreen preview of the Dynamic Island for visual review without TCC
// Screen Recording. Renders every layout × variant on a simulated desktop with
// a notch cutout, so the notch-wrapping look + content-below-notch positioning
// can be inspected from the resulting PNG. See issue #12.
func renderIslandSnapshot(to path: String) {
    let simulatedSafeTop: CGFloat = 37  // typical notch height on 14"/16" MBP
    // Simulated physical notch width: 205pt = 14" MBP Pro M-series.
    let notchWidth: CGFloat = 205
    let simulatedNotchCore: CGFloat = 205 + IslandGeom.coreSafetyMargin  // = 229
    // Simulated menu bar height & pill height — matches the 14"/16" MBP
    // (safeAreaInsets.top == menuBarHeight on notched Macs).
    let simulatedMenuBarH: CGFloat = 37
    let simulatedIslandH: CGFloat = simulatedMenuBarH - 2  // 35pt pill
    // Menu bar on notched MBPs is 32pt tall — same as the safe-area inset.
    // The island floats INSIDE this strip with 2pt air gaps top/bottom, so
    // it should sit fully within the menu bar visually.
    let menuBarH: CGFloat = 32

    func host(for vms: [SessionVM], layout: IslandLayout, variant: IslandCardVariant) -> (NSView, NSSize) {
        let size: NSSize
        switch layout {
        case .closed:
            let agg = aggregateStatus(vms.map { $0.s })
            let n = activeCount(vms.map { $0.s })
            size = IslandGeom.foldedSize(islandHeight: simulatedIslandH,
                                          notchCoreWidth: simulatedNotchCore,
                                          count: n, word: islandStatusWord(agg))
        case .opened:
            let n = activeCount(vms.map { $0.s })
            size = IslandGeom.expandedSize(islandHeight: simulatedIslandH,
                                            notchCoreWidth: simulatedNotchCore,
                                            variant: variant, rowCount: n)
        }
        let h = IslandHostView(frame: NSRect(origin: .zero, size: size))
        h.notchCoreWidth = simulatedNotchCore
        h.islandHeight = simulatedIslandH
        h.update(sessions: vms, layout: layout, variant: variant)
        h.layoutSubtreeIfNeeded()
        return (h, size)
    }

    // Use the real wall clock — the host view's IslandFoldedLabel /
    // aggregateStatus calls default to Date().timeIntervalSince1970, so a stale
    // fixed `now` would make every running session decay to idle in the
    // snapshot. Determinism isn't worth that.
    let now = Date().timeIntervalSince1970
    let pop0: [SessionVM] = []
    let popRun: [SessionVM] = [
        SessionVM(s: Session(id: "r1", folder: "refactor-status", cwd: "/x/refactor-status",
                             status: .running, title: "refactor-status",
                             lastEvent: "Bash · npm run build",
                             updatedAt: now, pid: 1), tokens: 47_000),
        SessionVM(s: Session(id: "r2", folder: "monorepo", cwd: "/x/monorepo",
                             status: .running, title: "monorepo",
                             lastEvent: "running tests 14/38",
                             updatedAt: now - 10, pid: 2), tokens: 182_000),
    ]
    let popWait: [SessionVM] = [
        SessionVM(s: Session(id: "w1", folder: "sample-api", cwd: "/x/sample-api",
                             status: .waiting, title: "sample-api",
                             lastEvent: "waiting · permission",
                             updatedAt: now, pid: 11,
                             pendingTool: "Bash", pendingInput: "npm test --watch"), tokens: 9_100),
    ]
    let popErr: [SessionVM] = [
        SessionVM(s: Session(id: "e1", folder: "release-tools", cwd: "/x/release-tools",
                             status: .error, title: "release-tools",
                             lastEvent: "Edit failed",
                             lastError: "settings.swift · permission denied",
                             errorAt: now - 5, updatedAt: now - 5, pid: 21,
                             pendingTool: "Edit"), tokens: 3_100),
    ]
    let popList: [SessionVM] = [
        SessionVM(s: Session(id: "L1", folder: "claudedot · refactor status bar", cwd: "/x/claudedot",
                             status: .waiting, title: "claudedot · refactor",
                             updatedAt: now, pid: 1,
                             pendingTool: "Bash", pendingInput: "npm test --watch"), tokens: 182_000),
        SessionVM(s: Session(id: "L2", folder: "monorepo · dependency upgrade", cwd: "/x/mono",
                             status: .running, title: "monorepo",
                             lastEvent: "24s ago", updatedAt: now - 24, pid: 2), tokens: 47_000),
        SessionVM(s: Session(id: "L3", folder: "notes-cli · prompt experiments", cwd: "/x/notes",
                             status: .error, title: "notes-cli",
                             lastError: "settings.swift",
                             errorAt: now - 10, updatedAt: now - 10, pid: 3,
                             pendingTool: "Edit"), tokens: 9_100),
    ]
    let popMany: [SessionVM] = (0..<7).map { i in
        SessionVM(s: Session(id: "m\(i)", folder: "proj-\(i)", cwd: "/x/proj-\(i)",
                             status: [.running, .waiting, .running, .error, .running, .running, .waiting][i],
                             title: "project \(i)",
                             lastEvent: "Working…", updatedAt: now, pid: Int32(100 + i),
                             pendingTool: "Bash"), tokens: 12_000 * (i + 1))
    }

    struct Cell { let label: String; let vms: [SessionVM]; let layout: IslandLayout; let variant: IslandCardVariant }
    let cells: [Cell] = [
        Cell(label: "Closed · idle (140pt)",       vms: pop0,    layout: .closed, variant: .sessionList),
        Cell(label: "Closed · running",            vms: popRun,  layout: .closed, variant: .sessionList),
        Cell(label: "Closed · waiting (accent)",   vms: popWait, layout: .closed, variant: .sessionList),
        Cell(label: "Closed · error",              vms: popErr,  layout: .closed, variant: .sessionList),
        Cell(label: "Opened · sessionList ×3",     vms: popList, layout: .opened, variant: .sessionList),
        Cell(label: "Opened · sessionList +more",  vms: popMany, layout: .opened, variant: .sessionList),
        Cell(label: "Opened · approvalCard",       vms: popWait, layout: .opened, variant: .approval(sessionId: "w1")),
        Cell(label: "Opened · completionCard",     vms: popRun,  layout: .opened, variant: .completion(sessionId: "r1")),
    ]

    // Each cell shows a simulated screen top-strip (menu bar + notch) with the
    // island composited at its real position. Cell width must accommodate the
    // expanded island plus padding.
    let cellW: CGFloat = 520
    let cellH: CGFloat = 320
    let cols = 2
    let rows = (cells.count + cols - 1) / cols
    let pad: CGFloat = 24
    let total = NSSize(width: pad + CGFloat(cols) * (cellW + pad),
                       height: pad + CGFloat(rows) * (cellH + pad))

    let img = NSImage(size: total)
    img.lockFocus()
    NSColor(hex: "1A1815").setFill()
    NSRect(origin: .zero, size: total).fill()

    for (idx, cell) in cells.enumerated() {
        let col = idx % cols, row = idx / cols
        let ox = pad + CGFloat(col) * (cellW + pad)
        let oy = total.height - pad - CGFloat(row + 1) * cellH - CGFloat(row) * pad

        // Simulated screen: cream desktop, dark menu bar across the top with
        // a centered black notch carved out so we can see the wrap effect.
        let bg = NSRect(x: ox, y: oy, width: cellW, height: cellH)
        NSColor(hex: "5A8FB5").setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()

        // Menu bar strip
        let menu = NSRect(x: bg.minX, y: bg.maxY - menuBarH, width: bg.width, height: menuBarH)
        NSColor.black.withAlphaComponent(0.35).setFill()
        menu.fill()

        // Notch: a black bump centered on the menu bar that intrudes downward.
        let notchH: CGFloat = simulatedSafeTop
        let notchRect = NSRect(x: bg.midX - notchWidth / 2,
                                y: bg.maxY - notchH,
                                width: notchWidth, height: notchH)
        NSColor.black.setFill()
        let notchPath = NSBezierPath()
        notchPath.move(to: NSPoint(x: notchRect.minX, y: notchRect.maxY))
        notchPath.line(to: NSPoint(x: notchRect.minX, y: notchRect.minY + 10))
        notchPath.curve(to: NSPoint(x: notchRect.minX + 10, y: notchRect.minY),
                        controlPoint1: NSPoint(x: notchRect.minX, y: notchRect.minY),
                        controlPoint2: NSPoint(x: notchRect.minX, y: notchRect.minY))
        notchPath.line(to: NSPoint(x: notchRect.maxX - 10, y: notchRect.minY))
        notchPath.curve(to: NSPoint(x: notchRect.maxX, y: notchRect.minY + 10),
                        controlPoint1: NSPoint(x: notchRect.maxX, y: notchRect.minY),
                        controlPoint2: NSPoint(x: notchRect.maxX, y: notchRect.minY))
        notchPath.line(to: NSPoint(x: notchRect.maxX, y: notchRect.maxY))
        notchPath.close()
        notchPath.fill()

        // Mirror IslandGeom.origin: simulated screen carries a notch, so the
        // pill sits flush against the top (no air gap) to wrap the notch.
        let (view, sz) = host(for: cell.vms, layout: cell.layout, variant: cell.variant)
        let islandX = bg.midX - sz.width / 2
        let islandY = bg.maxY - sz.height
        // Caching needs an explicit alpha-aware bitmap rep so the pill's rounded
        // corners come through as transparent. bitmapImageRepForCachingDisplay
        // (the default) produces an opaque bitmap → the 4 corner pixels outside
        // the rounded shape would render as white over the wallpaper.
        let pixW = Int(view.bounds.width * 2)
        let pixH = Int(view.bounds.height * 2)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixW, pixelsHigh: pixH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        rep.draw(in: NSRect(x: islandX, y: islandY, width: sz.width, height: sz.height))

        // Caption under the cell.
        let cap = NSAttributedString(string: cell.label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.8, alpha: 1)])
        let s = cap.size()
        cap.draw(at: NSPoint(x: bg.minX + 10, y: bg.minY + 8))
        // Note dimensions on the right.
        let dims = NSAttributedString(string: "\(Int(sz.width))×\(Int(sz.height))pt", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(white: 0.55, alpha: 1)])
        dims.draw(at: NSPoint(x: bg.maxX - dims.size().width - 10, y: bg.minY + 8))
        _ = s
    }

    img.unlockFocus()
    let final = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try? final.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  \(Int(total.width))x\(Int(total.height))")
}

func renderAppIcon(to path: String, size: CGFloat = 1024) {
    let img = appIconImage(diameter: size)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  \(Int(size))x\(Int(size))")
}

// MARK: - Entry point

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    renderSnapshot(to: CommandLine.arguments[i + 1])
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--owls"), i + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    renderOwls(to: CommandLine.arguments[i + 1])
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot-island"), i + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    renderIslandSnapshot(to: CommandLine.arguments[i + 1])
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--appicon"), i + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    renderAppIcon(to: CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
