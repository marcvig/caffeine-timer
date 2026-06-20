import AppKit

/// A small custom About window (replaces the standard About panel) so it can host a
/// "Check for Updates…" button alongside the app icon, version, tagline, and links.
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true) // bring it to front for a menu-bar app
        if let window {
            window.center(); window.makeKeyAndOrderFront(nil); return
        }
        let content = makeContent()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "About Caffeine Timer"
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.setContentSize(content.fittingSize)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func checkTapped() { UpdateChecker.checkForUpdates() }

    private func makeContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 30, bottom: 22, right: 30)

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(10, after: icon)

        let name = textLabel("Caffeine Timer", font: .systemFont(ofSize: 17, weight: .semibold), color: .labelColor)
        stack.addArrangedSubview(name)

        let version = textLabel("Version \(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))",
                                font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        stack.addArrangedSubview(version)
        stack.setCustomSpacing(12, after: version)

        let tagline = textLabel("Keep your Mac awake for a set duration.",
                                font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        tagline.lineBreakMode = .byWordWrapping
        tagline.preferredMaxLayoutWidth = 250
        stack.addArrangedSubview(tagline)
        stack.setCustomSpacing(16, after: tagline)

        let button = NSButton(title: "Check for Updates…", target: self, action: #selector(checkTapped))
        button.bezelStyle = .rounded
        stack.addArrangedSubview(button)
        stack.setCustomSpacing(16, after: button)

        let links = NSTextField(labelWithAttributedString: creditsLinks())
        links.isSelectable = true
        links.allowsEditingTextAttributes = true
        links.alignment = .center
        stack.addArrangedSubview(links)
        stack.setCustomSpacing(12, after: links)

        let brew = NSTextField(labelWithString: UpdateChecker.brewCommand)
        brew.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        brew.textColor = .tertiaryLabelColor
        brew.isSelectable = true
        stack.addArrangedSubview(brew)

        return stack
    }

    private func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }

    private func textLabel(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font; t.textColor = color; t.alignment = .center
        return t
    }

    /// Centered "Made by Vigod Labs / Source on GitHub · Support" with clickable links.
    private func creditsLinks() -> NSAttributedString {
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = 3
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        let s = NSMutableAttributedString()
        func text(_ t: String) { s.append(NSAttributedString(string: t, attributes: base)) }
        func link(_ label: String, _ url: String) {
            var a = base; a[.link] = URL(string: url); a[.foregroundColor] = NSColor.linkColor
            s.append(NSAttributedString(string: label, attributes: a))
        }
        text("Made by "); link("Vigod Labs", "https://vigodlabs.com"); text("\n")
        link("Source on GitHub", "https://github.com/marcvig/caffeine-timer"); text("    ")
        link("Support", "https://vigodlabs.com/support")
        return s
    }
}
