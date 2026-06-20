import Foundation
import IOKit.pwr_mgt

/// Wraps a single IOKit power assertion that keeps the Mac awake while the user is
/// idle — either the display + system (default) or the system only, letting the
/// display sleep (see `start(reason:keepDisplayAwake:)`). Same mechanism the
/// `caffeinate` CLI uses. Only ever touched from the main thread.
///
/// Note: this is a *user-idle* assertion. It deliberately does NOT block the user
/// manually sleeping (Apple menu ▸ Sleep), closing the lid, low battery, or a
/// thermal event — that is correct, well-behaved caffeinate semantics.
final class CaffeineController {
    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    var isActive: Bool { assertionID != IOPMAssertionID(kIOPMNullAssertionID) }

    /// Acquire (or re-acquire) the keep-awake assertion. Safe to call while one is
    /// already held: the new assertion is created *first*, and the previous one is
    /// released only after the new one succeeds. So a failed (re)acquire is a true
    /// no-op — any existing assertion stays held — rather than silently dropping the
    /// keep-awake and letting the Mac sleep while the UI still thinks it's active.
    ///
    /// `keepDisplayAwake` chooses the assertion type: true keeps the *display* on
    /// (PreventUserIdleDisplaySleep, like `caffeinate -d`); false keeps only the
    /// *system* awake and lets the display sleep normally (PreventUserIdleSystemSleep,
    /// like `caffeinate -i`).
    @discardableResult
    func start(reason: String, keepDisplayAwake: Bool) -> Bool {
        let previousID = assertionID
        var newID = IOPMAssertionID(kIOPMNullAssertionID)
        let assertionType = keepDisplayAwake
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep   // screen stays on (system awake too)
            : kIOPMAssertionTypePreventUserIdleSystemSleep    // system awake, display may sleep
        let result = IOPMAssertionCreateWithName(
            assertionType as CFString,                                 // #define → CFSTR, cast required
            IOPMAssertionLevel(kIOPMAssertionLevelOn),                 // == 255, not 1
            reason as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else {
            return false // create failed: keep the previous assertion (if any) held
        }
        assertionID = newID
        if previousID != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(previousID) // release the old one only after success
        }
        return true
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    }

    deinit { stop() }
}
