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
        case timed(end: Date, minutes: Int)
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

    // MARK: Menu items

    private let headerItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private var durationItems: [NSMenuItem] = []
    private let indefiniteItem = NSMenuItem(title: "Indefinite", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
    private let enableNotifsItem = NSMenuItem(title: "Turn On Notifications…", action: nil, keyEquivalent: "")

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

    @objc private func stopTapped() {
        stop(notify: false) // user-initiated; the icon reverting is confirmation enough
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

    private func startTimed(minutes: Int) {
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        guard caffeine.start(reason: "CaffeineTimer: awake for \(minutes) minutes") else {
            reportFailure()
            return
        }
        session = .timed(end: end, minutes: minutes)
        startTicking()
        updateButton()
        NotificationManager.shared.notify(
            title: "Staying awake for \(humanDuration(minutes))",
            body: "Your Mac won’t sleep until \(Self.clockFormatter.string(from: end)).")
    }

    private func startIndefinite() {
        guard caffeine.start(reason: "CaffeineTimer: awake indefinitely") else {
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

    /// Manual stop (notify: false) or natural expiry (notify: true).
    private func stop(notify: Bool) {
        caffeine.stop()
        stopTicking()
        session = .idle
        updateButton()
        if notify {
            NotificationManager.shared.notify(
                title: "Caffeine ended",
                body: "Your Mac can sleep normally again.")
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
            stop(notify: true) // natural expiry
        } else {
            updateButtonTitle()
            updateHeaderTitle() // keep the header live if the menu is held open
        }
    }

    // MARK: Status-item button

    /// Color for the active state (cup glyph + countdown). `.systemRed` is dynamic,
    /// so it stays readable on light and dark menu bars. Swap here to restyle
    /// (e.g. `.systemOrange`, `.systemGreen`).
    private static let activeColor: NSColor = .systemRed

    private func updateButton() {
        guard let button = statusItem.button else { return }
        if let glyph = loadMenuGlyph() {
            if isActive {
                // The menu bar renders template images monochrome and ignores
                // contentTintColor, so use a solid-red (non-template) copy when active.
                button.image = Self.tinted(glyph, color: Self.activeColor)
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
            .foregroundColor: Self.activeColor,
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
            headerItem.title = "Idle · your Mac sleeps normally"
        case .indefinite:
            headerItem.title = "Awake · indefinitely"
        case let .timed(end, _):
            headerItem.title = "Awake · \(Self.preciseCountdown(end.timeIntervalSinceNow)) left"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateHeaderTitle()

        let activeMinutes: Int?
        if case let .timed(_, minutes) = session { activeMinutes = minutes } else { activeMinutes = nil }
        for item in durationItems {
            let minutes = item.representedObject as? Int
            item.state = (minutes != nil && minutes == activeMinutes) ? .on : .off
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

    private func humanDuration(_ minutes: Int) -> String {
        switch minutes {
        case 60: return "1 hour"
        case 120: return "2 hours"
        default: return "\(minutes) minutes"
        }
    }
}
