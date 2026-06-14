// swift-tools-version:5.9
import PackageDescription

// Swift 5 language mode keeps strict-concurrency checking off, which is the
// right fit for a single-threaded AppKit menu-bar app (everything runs on the
// main run loop). AppKit / UserNotifications / IOKit auto-link from `import`.
let package = Package(
    name: "CaffeineTimer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CaffeineTimer",
            path: "Sources/CaffeineTimer"
        )
    ]
)
