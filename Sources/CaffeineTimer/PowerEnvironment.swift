import Foundation
import IOKit.ps

/// Read-only snapshots of the Mac's power state, used by the keep-awake guards
/// (see `Settings.batteryGuardEnabled` / `lowPowerModeGuardEnabled`).
enum PowerEnvironment {
    /// Internal-battery charge as a percentage (0…100), or nil on a desktop Mac (no battery)
    /// or if it can't be read.
    static func batteryPercent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = desc[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Int((Double(current) / Double(maximum) * 100).rounded())
        }
        return nil
    }

    /// True when the Mac is running on battery (not drawing from an adapter). False on a desktop
    /// Mac or when plugged in.
    static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey] as? String else { continue }
            return state == kIOPSBatteryPowerValue
        }
        return false
    }

    /// True when macOS Low Power Mode is enabled.
    static var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
