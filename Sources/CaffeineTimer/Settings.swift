import Foundation

/// Persistent user preferences (UserDefaults-backed), surfaced in the Settings window.
/// Launch-at-login is intentionally NOT stored here — its source of truth is the system
/// (`SMAppService.mainApp.status`), which `SettingsWindowController` reads/writes directly.
enum Settings {
    private static let d = UserDefaults.standard

    /// Keep only the *system* awake and let the display sleep (PreventUserIdleSystemSleep).
    /// Default false = keep the screen on too (PreventUserIdleDisplaySleep).
    static var allowDisplaySleep: Bool {
        get { d.bool(forKey: "AllowDisplaySleep") }
        set { d.set(newValue, forKey: "AllowDisplaySleep") }
    }

    /// Auto-stop the keep-awake when battery falls below `batteryThreshold` while on battery.
    static var batteryGuardEnabled: Bool {
        get { d.bool(forKey: "BatteryGuardEnabled") }
        set { d.set(newValue, forKey: "BatteryGuardEnabled") }
    }

    /// Battery percentage (10…90) below which the guard releases the keep-awake. Default 20.
    static var batteryThreshold: Int {
        get { (d.object(forKey: "BatteryThresholdPercent") as? Int) ?? 20 }
        set { d.set(min(90, max(10, newValue)), forKey: "BatteryThresholdPercent") }
    }

    /// Auto-stop the keep-awake when macOS Low Power Mode turns on.
    static var lowPowerModeGuardEnabled: Bool {
        get { d.bool(forKey: "LowPowerModeGuardEnabled") }
        set { d.set(newValue, forKey: "LowPowerModeGuardEnabled") }
    }
}
