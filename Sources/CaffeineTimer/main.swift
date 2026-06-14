import AppKit

// Menu-bar–only agent: no Dock icon, no app menu bar. Two things matter here:
//   1. setActivationPolicy(.accessory) makes it a menu-bar agent at runtime
//      (LSUIElement in Info.plist does the same declaratively).
//   2. NSApplication.delegate is a *weak* property, so the delegate must be
//      held by a strong binding that lives for the whole process — hence the
//      top-level `let delegate`.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
