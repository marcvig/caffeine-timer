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
        var size = content.fittingSize
        size.width = max(size.width, 400) // roomier than the tight fit-to-content width
        w.setContentSize(size)
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
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 36, bottom: 26, right: 36)

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
        tagline.preferredMaxLayoutWidth = 320
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

        stack.addArrangedSubview(makeBrewBox())

        return stack
    }

    /// A monospace "code box" for the Homebrew command with a copy-to-clipboard button beside it.
    private func makeBrewBox() -> NSView {
        let code = NSTextField(labelWithString: UpdateChecker.brewCommand)
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.textColor = .labelColor
        code.isSelectable = true
        code.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.addSubview(code)
        NSLayoutConstraint.activate([
            code.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            code.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            code.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            code.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])

        let copy = NSButton(title: "", target: self, action: #selector(copyBrewTapped(_:)))
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copy.imagePosition = .imageOnly
        copy.bezelStyle = .texturedRounded
        copy.toolTip = "Copy to clipboard"

        let row = NSStackView(views: [box, copy])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    @objc private func copyBrewTapped(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateChecker.brewCommand, forType: .string)
        // Brief confirmation: swap to a green checkmark, then revert.
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        sender.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            sender?.contentTintColor = nil
        }
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
