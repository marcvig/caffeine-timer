import AppKit

/// A full-screen, transparent overlay for setting a custom timer duration by "stretching"
/// a rubber band from the menu-bar icon: the band is anchored at the status item, follows
/// the cursor live, and the distance pulled sets the time (snapped to 1-minute steps). The
/// live value shows in a pill beside the cursor. Click to start, Esc / right-click to cancel.
///
/// (A menu can't host this: an open `NSMenu` owns event tracking, so the menu is dismissed
/// first and this key window takes over.)
final class DurationDragOverlay {
    private var window: NSWindow?
    private var completion: ((Int?) -> Void)?

    /// Show the overlay. `anchorScreen` is the menu-bar icon's position (screen coords) the
    /// band stretches from; nil falls back to top-center. `completion` is called once with the
    /// chosen duration in seconds, or nil if cancelled (Esc, right-click, or a ~zero-length click).
    func present(anchorScreen: CGPoint?, completion: @escaping (Int?) -> Void) {
        self.completion = completion
        guard let screen = NSScreen.main else { completion(nil); return }

        let win = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .popUpMenu // above ordinary windows for the duration of the drag
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.hasShadow = false
        win.acceptsMouseMovedEvents = true // track the cursor live, before any click

        let view = DragView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        let fallback = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 2)
        let a = anchorScreen ?? fallback
        view.anchor = NSPoint(x: a.x - screen.frame.minX, y: a.y - screen.frame.minY)
        let mouse = NSEvent.mouseLocation
        view.current = NSPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        view.onFinish = { [weak self] minutes in self?.dismiss(minutes) }
        win.contentView = view

        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
    }

    private func dismiss(_ minutes: Int?) {
        window?.orderOut(nil)
        window = nil
        let done = completion
        completion = nil
        done?(minutes)
    }
}

/// Borderless windows can't become key by default; we need key status to receive Esc.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class DragView: NSView {
    var onFinish: ((Int?) -> Void)?
    var anchor: NSPoint = .zero   // menu-bar icon, in view coords
    var current: NSPoint = .zero  // cursor, in view coords

    private var confirming = false
    private var confirmProgress: CGFloat = 0
    private var confirmStart: Date?
    private var animPhase: CGFloat = 0  // scrolls the prismatic gradient along the band
    private var frameTimer: Timer?      // one ~60fps loop: rainbow flow + retract + physics
    private let ropeCount = 14          // segments of the springy band
    private var ropePoints: [NSPoint] = []
    private var ropeVel: [NSPoint] = []
    private var chosenSeconds = 0
    private var chosenLabel = ""

    private var modifiers: NSEvent.ModifierFlags = []
    private let confirmDuration = 0.32 // seconds; time-based retract so the motion is fluid

    /// Drag modes selected by held modifier keys: ⌥ = a seconds range, ⇧ = long minutes,
    /// otherwise the default minute range. `maxNative` is the value a full-height pull reaches,
    /// in the mode's native unit (seconds for .seconds, minutes otherwise).
    private enum Mode { case seconds, minutes, longMinutes }
    private var mode: Mode {
        if modifiers.contains(.option) { return .seconds }
        if modifiers.contains(.shift) { return .longMinutes }
        return .minutes
    }
    private var maxNative: Double {
        switch mode { case .seconds: return 60; case .minutes: return 120; case .longMinutes: return 720 }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// Distance pulled from the anchor → minutes, scaled so a full-height pull ≈ maxMinutes.
    private func dist() -> CGFloat { hypot(current.x - anchor.x, current.y - anchor.y) }

    /// The value in the mode's native unit (seconds or minutes) for a pull distance.
    private func nativeValue(forDistance distance: CGFloat) -> Int {
        let reference = max(bounds.height, 1)
        let raw = Double(distance) * (maxNative / Double(reference))
        switch mode {
        case .seconds:     return min(60, max(0, Int(raw.rounded())))            // 1-second steps
        case .minutes:     return min(120, max(0, Int(raw.rounded())))           // 1-minute steps
        case .longMinutes: let step = 5.0; return min(720, max(0, Int((raw / step).rounded() * step)))
        }
    }

    /// Total timer length in seconds for a pull (native minutes are ×60).
    private func totalSeconds(forDistance distance: CGFloat) -> Int {
        let value = nativeValue(forDistance: distance)
        return mode == .seconds ? value : value * 60
    }

    private func label(forDistance distance: CGFloat) -> String {
        let value = nativeValue(forDistance: distance)
        if mode == .seconds { return "\(value) s" }
        let h = value / 60, m = value % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(value) min"
    }

    private func track(with event: NSEvent) {
        guard !confirming else { return }
        modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func flagsChanged(with event: NSEvent) { // ⇧/⌥ pressed or released without moving
        modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !confirming { needsDisplay = true }
    }
    override func mouseMoved(with event: NSEvent) { track(with: event) }
    override func mouseDragged(with event: NSEvent) { track(with: event) }
    override func mouseDown(with event: NSEvent) { track(with: event) }

    override func mouseUp(with event: NSEvent) {
        guard !confirming else { return }
        modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        current = convert(event.locationInWindow, from: nil)
        let seconds = totalSeconds(forDistance: dist())
        guard seconds >= 1 else { onFinish?(nil); return } // clicked at ~zero length = cancel
        chosenSeconds = seconds
        chosenLabel = label(forDistance: dist())
        startConfirm()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) } // 53 = Esc
    }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    /// Confirm flourish: retract the band to the anchor (eased) while the readout blinks.
    /// The frame loop below advances the progress and fires onFinish at the end.
    private func startConfirm() {
        confirming = true
        confirmProgress = 0
        confirmStart = Date()
    }

    /// One ~60fps loop runs the whole time the overlay is on screen: it scrolls the rainbow
    /// and, while confirming, advances the eased retract and finishes when done. Self-cleans
    /// when the view leaves its window (and via deinit), and uses [weak self] to avoid a cycle.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameTimer?.invalidate(); frameTimer = nil
        guard window != nil else { return }
        resetRope(tip: current)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            animPhase = (animPhase + 0.006).truncatingRemainder(dividingBy: 1.0)
            if confirming {
                let elapsed = -(confirmStart?.timeIntervalSinceNow ?? confirmDuration)
                confirmProgress = CGFloat(min(1.0, elapsed / confirmDuration))
                if confirmProgress >= 1.0 {
                    timer.invalidate(); frameTimer = nil
                    onFinish?(chosenSeconds)
                    return
                }
            }
            stepPhysics(tip: easedTip())
            needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    deinit { frameTimer?.invalidate() }

    /// The cursor end of the band — eased toward the anchor during the confirm retract.
    private func easedTip() -> NSPoint {
        let raw = confirming ? Double(confirmProgress) : 0.0
        let e = 1 - pow(1 - raw, 3)
        return NSPoint(x: current.x + (anchor.x - current.x) * CGFloat(e),
                       y: current.y + (anchor.y - current.y) * CGFloat(e))
    }

    /// Reset the springy band to a straight, at-rest line from the anchor to `tip`.
    private func resetRope(tip: NSPoint) {
        ropePoints = (0...ropeCount).map { i in
            let t = CGFloat(i) / CGFloat(ropeCount)
            return NSPoint(x: anchor.x + (tip.x - anchor.x) * t, y: anchor.y + (tip.y - anchor.y) * t)
        }
        ropeVel = Array(repeating: .zero, count: ropeCount + 1)
    }

    /// One step of a simple spring chain: endpoints pin to the anchor + tip, while interior
    /// points are pulled toward the straight line (and their neighbors) with inertia + damping —
    /// so the band lags, bows, and wobbles as the cursor moves, then settles straight. No gravity.
    private func stepPhysics(tip: NSPoint) {
        guard ropePoints.count == ropeCount + 1 else { resetRope(tip: tip); return }
        ropePoints[0] = anchor
        ropePoints[ropeCount] = tip
        let restK: CGFloat = 0.12, neighborK: CGFloat = 0.25, damping: CGFloat = 0.82
        for i in 1..<ropeCount {
            let t = CGFloat(i) / CGFloat(ropeCount)
            let rest = NSPoint(x: anchor.x + (tip.x - anchor.x) * t, y: anchor.y + (tip.y - anchor.y) * t)
            let prev = ropePoints[i - 1], next = ropePoints[i + 1]
            let ax = (rest.x - ropePoints[i].x) * restK + ((prev.x + next.x) / 2 - ropePoints[i].x) * neighborK
            let ay = (rest.y - ropePoints[i].y) * restK + ((prev.y + next.y) / 2 - ropePoints[i].y) * neighborK
            ropeVel[i].x = (ropeVel[i].x + ax) * damping
            ropeVel[i].y = (ropeVel[i].y + ay) * damping
            ropePoints[i].x += ropeVel[i].x
            ropePoints[i].y += ropeVel[i].y
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill() // light scrim; the pill carries legibility
        bounds.fill()

        let raw = confirming ? Double(confirmProgress) : 0.0
        let tip = easedTip()
        // Rubber band: a soft, scrolling prismatic glow with springy physics; white handle dots.
        drawRainbowBand(from: anchor, to: tip, phase: animPhase)
        NSColor.white.withAlphaComponent(0.5).setFill(); dot(at: anchor, radius: 5)
        if !confirming { NSColor.white.setFill(); dot(at: tip, radius: 7) }

        let text = confirming ? chosenLabel : label(forDistance: dist())
        let pill = pillRect(forText: text, tip: tip)
        let blinkVisible = !confirming || (Int(raw * 4) % 2 == 0) // ~2 blinks over the retract
        if blinkVisible { drawPill(text, in: pill, color: .white) }
        if !confirming { drawShortcutHints(below: pill) }
    }

    private func dot(at p: NSPoint, radius r: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
    }

    /// A flowing prismatic band: a few low-alpha wide passes (soft diffuse glow) plus a crisp
    /// core, each a full-spectrum gradient that scrolls along the line as `phase` advances.
    private func drawRainbowBand(from a: NSPoint, to b: NSPoint, phase: CGFloat) {
        guard hypot(b.x - a.x, b.y - a.y) > 0.5, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let core = smoothPath(ropePoints.count == ropeCount + 1 ? ropePoints : [a, b])
        let gradient = Self.rainbowGradient(phase: phase)
        let layers: [(width: CGFloat, alpha: CGFloat)] = [(24, 0.10), (16, 0.16), (9, 0.30), (4, 1.0)]
        for layer in layers {
            let outline = core.copy(strokingWithWidth: layer.width, lineCap: .round, lineJoin: .round, miterLimit: 1)
            ctx.saveGState()
            ctx.addPath(outline); ctx.clip()
            ctx.setAlpha(layer.alpha)
            gradient.draw(from: a, to: b, options: []) // color axis stays anchor→tip
            ctx.restoreGState()
        }
    }

    /// A smooth Catmull-Rom curve through the springy rope points, as a CGPath.
    private func smoothPath(_ pts: [NSPoint]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count > 1 else { return path }
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// Seamless full-spectrum gradient (first stop == last) offset by `phase` so it scrolls.
    private static func rainbowGradient(phase: CGFloat) -> NSGradient {
        let stops = 7
        let colors: [NSColor] = (0...stops).map { i in
            var hue = (CGFloat(i) / CGFloat(stops) + phase).truncatingRemainder(dividingBy: 1.0)
            if hue < 0 { hue += 1 }
            return NSColor(hue: hue, saturation: 0.62, brightness: 1.0, alpha: 1.0)
        }
        return NSGradient(colors: colors) ?? NSGradient(starting: .white, ending: .white)!
    }

    private static let pillFont = NSFont.systemFont(ofSize: 34, weight: .semibold)
    private let pillPadH: CGFloat = 22, pillPadV: CGFloat = 14

    /// Placement of the time capsule beside the cursor (left of it, flipping right if cramped).
    private func pillRect(forText s: String, tip: NSPoint) -> NSRect {
        let size = (s as NSString).size(withAttributes: [.font: Self.pillFont])
        let w = size.width + pillPadH * 2, h = size.height + pillPadV * 2
        let gap: CGFloat = 26
        var x = tip.x - gap - w
        if x < 12 { x = tip.x + gap }
        x = min(max(12, x), bounds.width - w - 12)
        let y = min(max(12, tip.y - h / 2), bounds.height - h - 12)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func drawPill(_ s: String, in rect: NSRect, color: NSColor) {
        NSColor(white: 0.18, alpha: 1.0).setFill() // fully opaque so nothing shows through
        NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
        (s as NSString).draw(at: NSPoint(x: rect.minX + pillPadH, y: rect.minY + pillPadV),
                             withAttributes: [.font: Self.pillFont, .foregroundColor: color])
    }

    /// A small tooltip under the time capsule: the modifier shortcuts (the active one
    /// highlighted, so it doubles as a live mode indicator) plus how to commit/cancel — placed
    /// by the cursor so the guidance is where the eye already is.
    private func drawShortcutHints(below pill: NSRect) {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let activeFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let dim = NSColor.white.withAlphaComponent(0.8), bright = NSColor.white
        let shift = modifiers.contains(.shift), option = modifiers.contains(.option)

        let line1 = NSMutableAttributedString()
        line1.append(NSAttributedString(string: "⇧ hours",
            attributes: [.font: shift ? activeFont : font, .foregroundColor: shift ? bright : dim]))
        line1.append(NSAttributedString(string: "       ", attributes: [.font: font]))
        line1.append(NSAttributedString(string: "⌥ seconds",
            attributes: [.font: option ? activeFont : font, .foregroundColor: option ? bright : dim]))
        let line2 = NSAttributedString(string: "click to start  ·  esc to cancel",
            attributes: [.font: font, .foregroundColor: dim])

        let s1 = line1.size(), s2 = line2.size()
        let padH: CGFloat = 14, padV: CGFloat = 9, lineGap: CGFloat = 3
        let w = max(s1.width, s2.width) + padH * 2
        let h = s1.height + s2.height + lineGap + padV * 2
        let gap: CGFloat = 10
        var x = pill.midX - w / 2
        x = min(max(12, x), bounds.width - w - 12)
        var y = pill.minY - gap - h        // below the pill (lower y in non-flipped coords)
        if y < 12 { y = pill.maxY + gap }  // flip above if there's no room below
        let rect = NSRect(x: x, y: y, width: w, height: h)

        NSColor(white: 0.18, alpha: 1.0).setFill() // fully opaque so nothing shows through
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        line2.draw(at: NSPoint(x: rect.midX - s2.width / 2, y: rect.minY + padV))
        line1.draw(at: NSPoint(x: rect.midX - s1.width / 2, y: rect.minY + padV + s2.height + lineGap))
    }
}
