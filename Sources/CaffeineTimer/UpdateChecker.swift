import AppKit

/// Lightweight "check for updates" — no Sparkle, no embedded framework (keeps the app tiny).
/// Asks the GitHub Releases API for the latest tag, compares it to the running version, and on a
/// user-initiated check shows a small alert that points to the download / Homebrew. The user does
/// the actual update (open the release, or `brew upgrade`); we just surface availability.
///
/// The app isn't sandboxed (Developer ID + hardened runtime), so outbound URLSession needs no
/// entitlement. (If this ever ships to the Mac App Store, add `com.apple.security.network.client`.)
enum UpdateChecker {
    static let repo = "marcvig/caffeine-timer"
    static let releasesPage = "https://github.com/marcvig/caffeine-timer/releases/latest"
    static let brewCommand = "brew upgrade --cask caffeine-timer"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// User-initiated check: fetch, then show an alert with the result.
    static func checkForUpdates() {
        fetchLatestVersion { result in
            switch result {
            case .failure: presentError()
            case .success(let latest):
                if isNewer(latest, than: currentVersion) { presentUpdateAvailable(latest: latest) }
                else { presentUpToDate() }
            }
        }
    }

    private static func fetchLatestVersion(_ completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(.failure(URLError(.badURL))); return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    completion(.failure(URLError(.cannotParseResponse))); return
                }
                completion(.success(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag))
            }
        }.resume()
    }

    /// Numeric dotted-version compare — true when `a` is strictly newer than `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func alert() -> NSAlert {
        NSApp.activate(ignoringOtherApps: true) // bring the dialog to front for a menu-bar app
        return NSAlert()
    }

    private static func presentUpToDate() {
        let a = alert()
        a.messageText = "You’re up to date"
        a.informativeText = "Caffeine Timer \(currentVersion) is the latest version."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private static func presentUpdateAvailable(latest: String) {
        let a = alert()
        a.messageText = "Update available"
        a.informativeText = "Caffeine Timer \(latest) is available — you have \(currentVersion).\n\nUpdate with Homebrew:\n\(brewCommand)"
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Copy brew command")
        a.addButton(withTitle: "Later")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: releasesPage) { NSWorkspace.shared.open(url) }
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(brewCommand, forType: .string)
        default:
            break
        }
    }

    private static func presentError() {
        let a = alert()
        a.messageText = "Couldn’t check for updates"
        a.informativeText = "Please check your connection and try again, or visit the releases page."
        a.addButton(withTitle: "View Releases")
        a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn, let url = URL(string: releasesPage) {
            NSWorkspace.shared.open(url)
        }
    }
}
