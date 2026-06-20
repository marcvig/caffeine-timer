import AppKit

/// Owns the status-item UI, the single active caffeine session, the countdown
/// timer, and the dropdown menu.
///
/// Single-active-timer model: there is only ever one running session. Selecting
/// any duration *replaces* a running one — the old power assertion is released
/// and a fresh one acquired, and the countdown resets.
final class MenuBarController: NSObject, NSMenuDelegate {

    // MARK: Session model

    private enum Session {
        case idle
        case timed(end: Date, totalSeconds: Int)
        case indefinite
    }

    private var session: Session = .idle
    private var isActive: Bool {
        if case .idle = session { return false }
        return true
    }

    // MARK: Collaborators

    private let caffeine = CaffeineController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var tickTimer: Timer?
    private lazy var baseGlyph: NSImage? = loadMenuGlyph() // cached; re-tinted per tick when active

    // MARK: Menu items

    private let headerItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let progressItem = NSMenuItem() // hosts the "time used" bar below the header
    private let progressBar = BarView(frame: NSRect(x: 0, y: 0, width: 220, height: 14))
    private var durationItems: [NSMenuItem] = []
    private let indefiniteItem = NSMenuItem(title: "Indefinite", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
    private let enableNotifsItem = NSMenuItem(title: "Turn On Notifications…", action: nil, keyEquivalent: "")
    private let customItem = NSMenuItem(title: "Custom…", action: nil, keyEquivalent: "")
    private let allowSleepItem = NSMenuItem(title: "Allow display to sleep", action: nil, keyEquivalent: "")
    private var dragOverlay: DurationDragOverlay?

    /// When true, keep only the system awake and let the display sleep normally
    /// (PreventUserIdleSystemSleep). Default false = keep the screen on too. Persisted.
    private var allowDisplaySleep = UserDefaults.standard.bool(forKey: "AllowDisplaySleep")

    /// (menu label, minutes) for the timed options.
    private let timedOptions: [(label: String, minutes: Int)] = [
        ("15 minutes", 15),
        ("30 minutes", 30),
        ("1 hour", 60),
        ("2 hours", 120),
    ]

    // MARK: Lifecycle

    override init() {
        super.init()
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "CaffeineTimer"
        updateButton()
    }

    /// Called from AppDelegate.applicationWillTerminate.
    func shutDown() {
        caffeine.stop()
        stopTicking()
    }

    // MARK: Menu construction

    private func buildMenu() {
        menu.autoenablesItems = false // we manage every item's enabled state ourselves

        let about = NSMenuItem(title: "About CaffeineTimer",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self // status-item menus aren't in the responder chain
        menu.addItem(about)
        menu.addItem(.separator())

        headerItem.isEnabled = false
        menu.addItem(headerItem)

        progressItem.view = progressBar
        progressItem.isHidden = true // shown only during a timed session
        menu.addItem(progressItem)

        menu.addItem(.separator())

        for option in timedOptions {
            let item = NSMenuItem(title: option.label,
                                  action: #selector(selectTimed(_:)),
                                  keyEquivalent: "")
            item.target = self // status-item menus aren't in the responder chain
            item.representedObject = option.minutes
            menu.addItem(item)
            durationItems.append(item)
        }

        indefiniteItem.action = #selector(selectIndefinite)
        indefiniteItem.target = self
        menu.addItem(indefiniteItem)

        customItem.action = #selector(selectCustom)
        customItem.target = self
        menu.addItem(customItem)

        menu.addItem(.separator())

        allowSleepItem.action = #selector(toggleAllowDisplaySleep)
        allowSleepItem.target = self
        allowSleepItem.state = allowDisplaySleep ? .on : .off
        menu.addItem(allowSleepItem)

        menu.addItem(.separator())

        stopItem.action = #selector(stopTapped)
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        // Shown only when notifications are off (see menuWillOpen) — jumps to Settings.
        enableNotifsItem.action = #selector(openNotificationSettings)
        enableNotifsItem.target = self
        enableNotifsItem.isHidden = true
        menu.addItem(enableNotifsItem)

        let quit = NSMenuItem(title: "Quit CaffeineTimer",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        // terminate: is resolved via the responder chain (NSApp), so no target needed.
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func selectTimed(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        startTimed(minutes: minutes)
    }

    @objc private func selectIndefinite() {
        startIndefinite()
    }

    /// "Custom…": dismiss the menu, then stretch a duration out from the menu-bar icon.
    @objc private func selectCustom() {
        let anchor = statusItemAnchorScreenPoint() // pin the rubber band to the cup icon
        menu.cancelTracking() // close the menu before putting up the key overlay window
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let overlay = DurationDragOverlay()
            self.dragOverlay = overlay // retain while presented
            overlay.present(anchorScreen: anchor) { [weak self] seconds in
                self?.dragOverlay = nil
                if let seconds, seconds > 0 { self?.startTimed(seconds: seconds) }
            }
        }
    }

    /// Bottom-center of the menu-bar status item in screen coordinates, so the drag overlay
    /// can stretch its rubber band from the icon. nil if the button/window isn't available.
    private func statusItemAnchorScreenPoint() -> CGPoint? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let inScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        return CGPoint(x: inScreen.midX, y: inScreen.minY)
    }

    @objc private func toggleAllowDisplaySleep() {
        allowDisplaySleep.toggle()
        UserDefaults.standard.set(allowDisplaySleep, forKey: "AllowDisplaySleep")
        allowSleepItem.state = allowDisplaySleep ? .on : .off
        reacquireIfActive() // swap the live assertion so the change applies immediately
    }

    @objc private func stopTapped() {
        stop(notification: (title: "Caffeine stopped",
                            body: "Your Mac is no longer set to stay awake."))
    }

    @objc private func openNotificationSettings() {
        NotificationManager.shared.openSystemNotificationSettings()
    }

    /// Standard macOS About panel: shows the app icon + version automatically, plus a maker
    /// link, source repo, support link, and Homebrew update instructions in the credits.
    @objc private func showAbout() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        let credits = NSMutableAttributedString()
        func text(_ s: String) { credits.append(NSAttributedString(string: s, attributes: base)) }
        func link(_ label: String, _ url: String) {
            var a = base; a[.link] = URL(string: url); a[.foregroundColor] = NSColor.linkColor
            credits.append(NSAttributedString(string: label, attributes: a))
        }
        text("Keep your Mac awake for a set duration.\n\n")
        text("Made by ");  link("Vigod Labs", "https://vigodlabs.com");  text("\n")
        link("Source on GitHub", "https://github.com/marcvig/caffeine-timer");  text("\n")
        link("Support", "https://vigodlabs.com/support");  text("\n\n")
        text("Update with Homebrew:\nbrew upgrade --cask caffeine-timer")

        NSApp.activate(ignoringOtherApps: true) // bring the panel to front for an agent app
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Session control

    private func startTimed(minutes: Int) { startTimed(seconds: minutes * 60) }

    private func startTimed(seconds: Int) {
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        guard caffeine.start(reason: "CaffeineTimer: awake for \(humanDuration(seconds: seconds))",
                             keepDisplayAwake: !allowDisplaySleep) else {
            reportFailure()
            return
        }
        session = .timed(end: end, totalSeconds: seconds)
        startTicking()
        updateButton()
        NotificationManager.shared.notify(
            title: "Staying awake for \(humanDuration(seconds: seconds))",
            body: "Your Mac won’t sleep until \(Self.clockFormatter.string(from: end)).")
    }

    private func startIndefinite() {
        guard caffeine.start(reason: "CaffeineTimer: awake indefinitely",
                             keepDisplayAwake: !allowDisplaySleep) else {
            reportFailure()
            return
        }
        session = .indefinite
        stopTicking() // nothing to count down
        updateButton()
        NotificationManager.shared.notify(
            title: "Staying awake indefinitely",
            body: "Your Mac won’t sleep until you stop CaffeineTimer.")
    }

    /// Re-acquire the keep-awake assertion for the current session under the current
    /// display-sleep preference. Called when the user flips the toggle mid-session so it
    /// takes effect at once. A failed re-acquire keeps the existing assertion held.
    private func reacquireIfActive() {
        switch session {
        case .idle:
            break
        case let .timed(_, totalSeconds):
            caffeine.start(reason: "CaffeineTimer: awake for \(humanDuration(seconds: totalSeconds))",
                           keepDisplayAwake: !allowDisplaySleep)
        case .indefinite:
            caffeine.start(reason: "CaffeineTimer: awake indefinitely",
                           keepDisplayAwake: !allowDisplaySleep)
        }
    }

    /// Manual stop (notify: false) or natural expiry (notify: true).
    private func stop(notification: (title: String, body: String)?) {
        caffeine.stop()
        stopTicking()
        session = .idle
        updateButton()
        if let notification {
            NotificationManager.shared.notify(title: notification.title, body: notification.body)
        }
    }

    private func reportFailure() {
        NotificationManager.shared.notify(
            title: "Couldn’t stay awake",
            body: "macOS refused the keep-awake request. Please try again.")
    }

    // MARK: Countdown timer

    private func startTicking() {
        stopTicking()
        // Built manually and added in .common mode so it keeps firing while the
        // menu is open (a plain scheduledTimer stops during menu tracking).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard case let .timed(end, _) = session else { return }
        if Date() >= end {
            stop(notification: (title: "Caffeine ended", // natural expiry
                                body: "Your Mac can sleep normally again."))
        } else {
            updateButton()      // re-tint icon + countdown to the current green→red ramp color
            updateHeaderTitle() // keep the header live if the menu is held open
        }
    }

    // MARK: Status-item button

    /// Fallback active color (used for an indefinite session, which has no progress to ramp).
    /// `.systemRed` is dynamic, so it stays readable on light and dark menu bars.
    private static let activeColor: NSColor = .systemRed

    /// Current status-item tint: shifts green→red across a timed session to match the menu's
    /// progress bar and header countdown; steady `activeColor` for an indefinite session.
    private var activeTint: NSColor {
        if case let .timed(end, totalSeconds) = session { return BarView.color(at: Self.usedFraction(end: end, totalSeconds: totalSeconds)) }
        return Self.activeColor
    }

    /// Fraction of a timed session that has elapsed (0…1), shared by the header, progress bar,
    /// and status-item tint so they stay in lockstep.
    private static func usedFraction(end: Date, totalSeconds: Int) -> CGFloat {
        let total = Double(totalSeconds)
        let remaining = max(0, end.timeIntervalSinceNow)
        return CGFloat(total > 0 ? min(max((total - remaining) / total, 0), 1) : 0)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        if let glyph = baseGlyph {
            if isActive {
                // The menu bar renders template images monochrome and ignores contentTintColor,
                // so use a solid-color (non-template) copy when active. The tint shifts green→red
                // across a timed session (see activeTint).
                glyph.isTemplate = false
                button.image = Self.tinted(glyph, color: activeTint)
            } else {
                glyph.isTemplate = true // adaptive white/black to match the menu bar
                button.image = glyph
            }
        } else {
            button.image = nil // no glyph available — updateButtonTitle() shows an emoji fallback
        }
        button.contentTintColor = nil // color comes from the image + attributed title
        updateButtonTitle()
    }

    /// Loads the bundled custom cup glyph (vector PDF) at menu-bar size, falling back
    /// to an SF Symbol. Returns nil only if BOTH are unavailable, so the caller can
    /// render a text/emoji fallback rather than a blank status item.
    private func loadMenuGlyph() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "pdf"),
           let img = NSImage(contentsOf: url) {
            img.size = size
            return img
        }
        return NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "CaffeineTimer")
    }

    /// A solid single-color (non-template) version of a glyph, resolution-independent.
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    private func updateButtonTitle() {
        guard let button = statusItem.button else { return }
        switch session {
        case .idle:
            button.title = button.image == nil ? "☕︎" : "" // plain; emoji fallback if symbol failed
            button.imagePosition = .imageOnly
        case .indefinite:
            setActiveTitle("∞", on: button)
        case let .timed(end, _):
            setActiveTitle(Self.compactCountdown(end.timeIntervalSinceNow), on: button)
        }
    }

    /// Colored countdown/∞ title beside the icon. An *attributed* title is required
    /// because the menu bar won't apply our color to a plain `title`.
    private func setActiveTitle(_ text: String, on button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: activeTint,
            .font: NSFont.menuBarFont(ofSize: 0),
        ])
        button.imagePosition = .imageLeading // icon, then countdown text
    }

    // MARK: Menu refresh (NSMenuDelegate)

    /// Sets the disabled header item's text from the current session. Called on
    /// menu open and on every tick, so the header stays live while the menu is held
    /// open (the menu-bar button alone updates otherwise).
    private func updateHeaderTitle() {
        switch session {
        case .idle:
            headerItem.attributedTitle = nil
            headerItem.title = "Idle · your Mac sleeps normally"
            progressItem.isHidden = true
        case .indefinite:
            headerItem.attributedTitle = Self.activeHeader(
                value: "indefinitely", valueColor: Self.activeColor, suffix: "", percent: nil)
            progressItem.isHidden = true
        case let .timed(end, totalSeconds):
            let used = Self.usedFraction(end: end, totalSeconds: totalSeconds)
            headerItem.attributedTitle = Self.activeHeader(
                value: Self.preciseCountdown(end.timeIntervalSinceNow), valueColor: BarView.color(at: used),
                suffix: " left", percent: Int((used * 100).rounded()))
            progressBar.fraction = used
            progressItem.isHidden = false
        }
    }

    /// "Awake · <value><suffix> · <percent>%" with the live countdown <value> in bold, tinted by
    /// `valueColor` (the progress-bar color at the current fraction), and the framing in fully-
    /// opaque primary label color, so the header pops instead of the dim/translucent gray a
    /// disabled menu item renders by default. (Disabled items dim a plain `title`, but honor an
    /// attributed title's colors — same trick the status bar uses.)
    private static func activeHeader(value: String, valueColor: NSColor, suffix: String, percent: Int?) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let framing: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .font: font]
        let s = NSMutableAttributedString(string: "Awake · ", attributes: framing)
        s.append(NSAttributedString(string: value, attributes: [.foregroundColor: valueColor, .font: bold]))
        if !suffix.isEmpty { s.append(NSAttributedString(string: suffix, attributes: framing)) }
        if let percent { s.append(NSAttributedString(string: " · \(percent)%", attributes: framing)) }
        return s
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateHeaderTitle()

        let activeSeconds: Int?
        if case let .timed(_, totalSeconds) = session { activeSeconds = totalSeconds } else { activeSeconds = nil }
        for item in durationItems {
            let seconds = (item.representedObject as? Int).map { $0 * 60 }
            item.state = (seconds != nil && seconds == activeSeconds) ? .on : .off
        }
        if case .indefinite = session { indefiniteItem.state = .on } else { indefiniteItem.state = .off }

        stopItem.isEnabled = isActive

        // Offer a Settings shortcut only when the user has notifications turned off.
        enableNotifsItem.isHidden = !NotificationManager.shared.isDenied
        NotificationManager.shared.refreshAuthorization() // refresh cache for next open
    }

    // MARK: Formatting

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Compact, for the menu-bar title: "M:SS" under an hour, "H:MM:SS" otherwise.
    private static func compactCountdown(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up))) // ceil: show 15:00 at start, 0:01 through the last second
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// Verbose, for the menu header: "1h 59m 32s" / "12m 04s" / "44s".
    private static func preciseCountdown(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up))) // ceil: show 15:00 at start, 0:01 through the last second
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }

    /// Friendly phrasing for a duration in seconds (preserves the presets' wording:
    /// "15 minutes", "1 hour", "2 hours"; also handles sub-minute and hour+minute customs).
    private func humanDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) second\(seconds == 1 ? "" : "s")" }
        let minutes = seconds / 60, secs = seconds % 60
        if minutes < 60 {
            if secs == 0 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
            return "\(minutes) min \(secs) s"
        }
        let hours = minutes / 60, mins = minutes % 60
        if mins == 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(hours)h \(mins)m"
    }
}

/// Slim determinate "time used" bar hosted in a menu item: a subtle rounded track with a
/// `fillColor` fill proportional to `fraction` (0…1). Autoresizes to the menu's width and
/// insets to align with the menu's text margin.
final class BarView: NSView {
    /// Progress gradient stops, left→right: plenty of time left (green) → almost out (red).
    /// Single source of truth — the header countdown and the custom-duration drag overlay are
    /// tinted from the same ramp via color(at:).
    static let gradientStops: [NSColor] = [.systemGreen, .systemOrange, .systemRed]

    /// The gradient color at position `f` (0…1), so the header countdown can match the bar's
    /// fill color at the same fraction.
    static func color(at f: CGFloat) -> NSColor {
        let stops = gradientStops
        let scaled = min(max(f, 0), 1) * CGFloat(stops.count - 1)
        let i = min(Int(scaled), stops.count - 2)
        return stops[i].blended(withFraction: scaled - CGFloat(i), of: stops[i + 1]) ?? stops[i]
    }

    var fraction: CGFloat = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width] // span the menu's content width
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 21, barHeight: CGFloat = 4
        let track = NSRect(x: inset, y: (bounds.height - barHeight) / 2,
                           width: max(0, bounds.width - inset * 2), height: barHeight)
        guard track.width > 0 else { return }
        let radius = barHeight / 2

        // Subtle track behind the fill.
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return }
        // Green→orange→red gradient anchored to the FULL track and revealed left-to-right as
        // time is used: the color at any point is fixed by its position on the bar (green while
        // plenty of time remains, red as it runs out) and blends gently between, rather than the
        // whole fill shifting color with the current fraction.
        let fillWidth = max(barHeight, track.width * f) // keep a rounded nub at very small %
        let fillRect = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: barHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).addClip()
        NSGradient(colors: Self.gradientStops)?.draw(in: track, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}
