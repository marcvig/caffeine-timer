import Foundation
import IOKit.pwr_mgt

/// Wraps a single IOKit power assertion that keeps the display — and, implicitly,
/// the system — awake while the user is idle. This is the same mechanism the
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
    @discardableResult
    func start(reason: String) -> Bool {
        let previousID = assertionID
        var newID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, // #define → CFSTR, cast required
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
