import AppKit
import ServiceManagement

/// Native Settings window that consolidates the preferences otherwise scattered
/// across the menu bar. Each control writes `Config` directly and, for the few
/// settings with active side effects (cleanup warm-up, Parakeet prep on English,
/// login item), calls back into the app. `onChanged` keeps the menu bar + idle
/// HUD in sync after any change.
final class SettingsController: NSObject {

    var onChanged: (() -> Void)?
    var onCleanupEnabled: ((Bool) -> Void)?
    var onLanguageChanged: ((String) -> Void)?
    var onLoginItemChanged: ((Bool) -> Void)?

    private static let languages: [(code: String, label: String)] = [
        ("en", "English"),
        ("hinglish", "Hinglish (Roman mix)"),
        ("hi", "Hindi (हिन्दी)"),
        ("auto", "Auto-detect"),
    ]

    private var window: NSWindow?
    private var hotkeyPopup: NSPopUpButton?
    private var languagePopup: NSPopUpButton?
    private var cleanupCheck: NSButton?
    private var handsFreeCheck: NSButton?
    private var smartSpacingCheck: NSButton?
    private var showFlowBarCheck: NSButton?
    private var startSoundCheck: NSButton?
    private var loginCheck: NSButton?

    func show() {
        if window == nil {
            build()
        }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(header("Dictation"))

        let hotkey = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in HotkeyChoice.allCases {
            hotkey.addItem(withTitle: choice.displayName)
            hotkey.lastItem?.representedObject = choice.rawValue
        }
        hotkey.target = self
        hotkey.action = #selector(hotkeyChanged)
        hotkeyPopup = hotkey
        stack.addArrangedSubview(labeled("Push-to-talk:", hotkey))

        let language = NSPopUpButton(frame: .zero, pullsDown: false)
        for entry in Self.languages {
            language.addItem(withTitle: entry.label)
            language.lastItem?.representedObject = entry.code
        }
        language.target = self
        language.action = #selector(languageChanged)
        languagePopup = language
        stack.addArrangedSubview(labeled("Language:", language))

        handsFreeCheck = checkbox("Tap for hands-free (VAD auto-stop)", #selector(handsFreeChanged))
        stack.addArrangedSubview(handsFreeCheck!)
        smartSpacingCheck = checkbox("Add a space after each dictation", #selector(smartSpacingChanged))
        stack.addArrangedSubview(smartSpacingCheck!)

        stack.addArrangedSubview(header("AI Cleanup"))
        cleanupCheck = checkbox("Clean up transcripts with Ollama", #selector(cleanupChanged))
        stack.addArrangedSubview(cleanupCheck!)
        stack.addArrangedSubview(note("Kept warm; roughly 1.5s per cleanup. Off = instant raw text."))

        stack.addArrangedSubview(header("Flow-Bar"))
        showFlowBarCheck = checkbox("Show the always-on Flow-Bar pill", #selector(showFlowBarChanged))
        stack.addArrangedSubview(showFlowBarCheck!)
        startSoundCheck = checkbox("Play a sound when recording starts", #selector(startSoundChanged))
        stack.addArrangedSubview(startSoundCheck!)

        stack.addArrangedSubview(header("System"))
        loginCheck = checkbox("Start LocalFlow at login", #selector(loginChanged))
        stack.addArrangedSubview(loginCheck!)

        stack.addArrangedSubview(header("Word lists"))
        let glossaryButton = NSButton(title: "Edit Glossary…", target: self, action: #selector(editGlossary))
        let snippetsButton = NSButton(title: "Edit Snippets…", target: self, action: #selector(editSnippets))
        let categoriesButton = NSButton(title: "Edit App Categories…", target: self, action: #selector(editCategories))
        [glossaryButton, snippetsButton, categoriesButton].forEach { $0.bezelStyle = .rounded }
        let fileRow = NSStackView(views: [glossaryButton, snippetsButton, categoriesButton])
        fileRow.orientation = .horizontal
        fileRow.spacing = 8
        stack.addArrangedSubview(fileRow)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let fitting = stack.fittingSize
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: fitting.width + 40, height: fitting.height + 40),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "LocalFlow Settings"
        win.isReleasedWhenClosed = false
        win.contentView = content
        win.center()
        window = win
    }

    private func header(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func checkbox(_ title: String, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func labeled(_ text: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // MARK: - Sync controls from Config

    private func refresh() {
        select(hotkeyPopup, value: Config.hotkey.rawValue)
        select(languagePopup, value: Config.whisperLanguage)
        cleanupCheck?.title = "Clean up transcripts with Ollama (\(Config.ollamaModel))"
        cleanupCheck?.state = Config.cleanupEnabled ? .on : .off
        handsFreeCheck?.state = Config.handsFreeEnabled ? .on : .off
        smartSpacingCheck?.state = Config.smartSpacing ? .on : .off
        showFlowBarCheck?.state = Config.showIdleHUD ? .on : .off
        startSoundCheck?.state = Config.playStartSound ? .on : .off
        loginCheck?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func select(_ popup: NSPopUpButton?, value: String) {
        guard let popup else { return }
        for item in popup.itemArray where (item.representedObject as? String) == value {
            popup.select(item)
            return
        }
    }

    // MARK: - Actions

    @objc private func hotkeyChanged() {
        guard let raw = hotkeyPopup?.selectedItem?.representedObject as? String,
              let choice = HotkeyChoice(rawValue: raw) else { return }
        Config.hotkey = choice
        onChanged?()
    }

    @objc private func languageChanged() {
        guard let code = languagePopup?.selectedItem?.representedObject as? String else { return }
        Config.whisperLanguage = code
        onLanguageChanged?(code)
        onChanged?()
    }

    @objc private func cleanupChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        Config.cleanupEnabled = enabled
        onCleanupEnabled?(enabled)
        onChanged?()
    }

    @objc private func handsFreeChanged(_ sender: NSButton) {
        Config.handsFreeEnabled = sender.state == .on
        onChanged?()
    }

    @objc private func smartSpacingChanged(_ sender: NSButton) {
        Config.smartSpacing = sender.state == .on
        onChanged?()
    }

    @objc private func showFlowBarChanged(_ sender: NSButton) {
        Config.showIdleHUD = sender.state == .on
        if Config.showIdleHUD {
            Config.hudHiddenUntil = Date(timeIntervalSince1970: 0)
        }
        onChanged?()
    }

    @objc private func startSoundChanged(_ sender: NSButton) {
        Config.playStartSound = sender.state == .on
        onChanged?()
    }

    @objc private func loginChanged(_ sender: NSButton) {
        onLoginItemChanged?(sender.state == .on)
    }

    @objc private func editGlossary() {
        Glossary.ensureFileExists()
        NSWorkspace.shared.open(Glossary.fileURL)
    }

    @objc private func editSnippets() {
        SnippetsEngine.openInEditor()
    }

    @objc private func editCategories() {
        AppContext.openInEditor()
    }
}
