import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up notifications first so the delegate is in place before we post.
        NotificationManager.shared.configure()
        menuBar = MenuBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the Mac awake after we quit: release the power assertion.
        menuBar?.shutDown()
    }
}
