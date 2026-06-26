import AppKit
import ServiceManagement

/// A small custom Settings window. CaffeineTimer is a menu-bar agent (`LSUIElement`) with no
/// standard Preferences menu, so this is its home for launch-at-login and keep-awake options.
/// Mirrors `AboutWindowController` (shared, lazily built, reused).
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    /// Invoked when "Allow display to sleep" changes, so a live session can re-acquire its
    /// assertion under the new preference immediately.
    var onDisplaySleepChanged: (() -> Void)?

    private var launchToggle: NSButton?
    private var displaySleepToggle: NSButton?
    private var batteryToggle: NSButton?
    private var batterySlider: NSSlider?
    private var batteryValue: NSTextField?
    private var lowPowerToggle: NSButton?

    func show() {
        NSApp.activate(ignoringOtherApps: true) // bring it to front for a menu-bar app
        if let window {
            refresh(); window.center(); window.makeKeyAndOrderFront(nil); return
        }
        let content = makeContent()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Caffeine Timer Settings"
        w.isReleasedWhenClosed = false
        w.contentView = content
        var size = content.fittingSize
        size.width = max(size.width, 400)
        w.setContentSize(size)
        w.center()
        window = w
        refresh()
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: - Build

    private func makeContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)

        // Startup
        stack.addArrangedSubview(sectionLabel("Startup"))
        let launch = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(toggleLaunch(_:)))
        launchToggle = launch
        stack.addArrangedSubview(launch)
        stack.setCustomSpacing(18, after: launch)

        // Keep awake
        stack.addArrangedSubview(sectionLabel("Keep awake"))
        let ds = NSButton(checkboxWithTitle: "Allow display to sleep", target: self, action: #selector(toggleDisplaySleep(_:)))
        displaySleepToggle = ds
        stack.addArrangedSubview(ds)
        let dsHint = hint("Keeps the system awake but lets the screen sleep normally.")
        stack.addArrangedSubview(dsHint)
        stack.setCustomSpacing(18, after: dsHint)

        // Battery
        stack.addArrangedSubview(sectionLabel("Battery"))
        let bat = NSButton(checkboxWithTitle: "Deactivate when battery is below", target: self, action: #selector(toggleBattery(_:)))
        batteryToggle = bat
        stack.addArrangedSubview(bat)

        let slider = NSSlider(value: Double(Settings.batteryThreshold), minValue: 10, maxValue: 90,
                              target: self, action: #selector(batteryThresholdChanged(_:)))
        slider.numberOfTickMarks = 9            // 10, 20, … 90
        slider.allowsTickMarkValuesOnly = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        batterySlider = slider
        let value = NSTextField(labelWithString: "\(Settings.batteryThreshold)%")
        value.font = .systemFont(ofSize: 11, weight: .medium)
        batteryValue = value
        let batRow = NSStackView(views: [slider, value])
        batRow.orientation = .horizontal
        batRow.spacing = 10
        stack.addArrangedSubview(batRow)
        let batHint = hint("Ignored if you start a timer when already below this level.")
        stack.addArrangedSubview(batHint)
        stack.setCustomSpacing(18, after: batHint)

        // Low Power Mode
        stack.addArrangedSubview(sectionLabel("Low Power Mode"))
        let lpm = NSButton(checkboxWithTitle: "Deactivate when Low Power Mode is enabled", target: self, action: #selector(toggleLowPower(_:)))
        lowPowerToggle = lpm
        stack.addArrangedSubview(lpm)
        stack.addArrangedSubview(hint("Low Power Mode is set in System Settings ▸ Battery."))

        return stack
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func hint(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .tertiaryLabelColor
        return t
    }

    // MARK: - State

    /// Sync every control to its current source of truth (on show and after each change).
    private func refresh() {
        launchToggle?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        displaySleepToggle?.state = Settings.allowDisplaySleep ? .on : .off
        batteryToggle?.state = Settings.batteryGuardEnabled ? .on : .off
        batterySlider?.integerValue = Settings.batteryThreshold
        batterySlider?.isEnabled = Settings.batteryGuardEnabled
        batteryValue?.stringValue = "\(Settings.batteryThreshold)%"
        batteryValue?.textColor = Settings.batteryGuardEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        lowPowerToggle?.state = Settings.lowPowerModeGuardEnabled ? .on : .off
    }

    @objc private func toggleLaunch(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { showLoginApprovalGuidance() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn’t change Launch at Login"
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: "OK")
            a.runModal()
        }
        refresh() // reflect the real system state
    }

    /// `register()` can succeed yet leave status at `.requiresApproval` (macOS makes the user enable
    /// the item in System Settings). The checkbox then correctly reads off, so point the user there.
    private func showLoginApprovalGuidance() {
        let a = NSAlert()
        a.messageText = "Approve Caffeine Timer in Login Items"
        a.informativeText = "macOS needs your approval before Caffeine Timer can launch at login. Open System Settings ▸ General ▸ Login Items and turn it on."
        a.addButton(withTitle: "Open Login Items")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleDisplaySleep(_ sender: NSButton) {
        Settings.allowDisplaySleep = (sender.state == .on)
        onDisplaySleepChanged?()
    }

    @objc private func toggleBattery(_ sender: NSButton) {
        Settings.batteryGuardEnabled = (sender.state == .on)
        refresh()
    }

    @objc private func batteryThresholdChanged(_ sender: NSSlider) {
        Settings.batteryThreshold = sender.integerValue
        batteryValue?.stringValue = "\(Settings.batteryThreshold)%"
    }

    @objc private func toggleLowPower(_ sender: NSButton) {
        Settings.lowPowerModeGuardEnabled = (sender.state == .on)
    }
}
