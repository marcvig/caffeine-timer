import AppKit
import UserNotifications
import os

/// Posts local notifications to confirm timer actions.
///
/// Requires the app to run from a real `.app` bundle with a `CFBundleIdentifier`
/// — `UNUserNotificationCenter.current()` traps otherwise. If the user has turned
/// notifications off (denied), macOS will not re-prompt; `isDenied` lets the menu
/// surface a shortcut to System Settings instead. Falls back to a system beep when
/// not authorized (the red menu-bar state is the primary visual confirm regardless).
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let log = Logger(subsystem: "com.vigod.caffeinetimer", category: "notifications")
    private var center: UNUserNotificationCenter { .current() }

    /// True when the user has explicitly turned notifications OFF. Drives the
    /// "Turn On Notifications…" menu item. Main-thread only.
    private(set) var isDenied = false

    /// Call once at launch. Sets the delegate (so banners present for an agent app)
    /// and makes the initial authorization request.
    func configure() {
        center.delegate = self
        refreshAuthorization()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                self?.log.notice("launch auth error: \(error.localizedDescription, privacy: .public)")
            } else {
                self?.log.notice("launch auth granted = \(granted, privacy: .public)")
            }
            self?.refreshAuthorization()
        }
    }

    /// Re-read the current authorization status into `isDenied` (for the menu).
    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            self.log.notice("auth status = \(settings.authorizationStatus.rawValue, privacy: .public)")
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async { self.isDenied = denied }
        }
    }

    /// Deliver a notification now; ask for permission on first use; beep if denied.
    func notify(title: String, body: String) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            DispatchQueue.main.async { self.isDenied = settings.authorizationStatus == .denied }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.deliver(title: title, body: body)
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                    guard let self else { return }
                    self.refreshAuthorization()
                    if granted {
                        self.deliver(title: title, body: body)
                    } else {
                        DispatchQueue.main.async { NSSound.beep() }
                    }
                }
            default: // denied / restricted — can't re-prompt; menu offers the Settings shortcut
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil) // nil == deliver now; timeInterval:0 would throw
        center.add(request) { [weak self] error in
            if let error {
                self?.log.error("deliver error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Opens System Settings ▸ Notifications so the user can switch the app on.
    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // Without this, macOS suppresses the banner while our agent app is the active
    // context — the notification would land silently in Notification Center only.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound]) // .alert is deprecated on macOS 11+
    }
}
