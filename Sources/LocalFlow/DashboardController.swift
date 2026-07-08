import AVFoundation
import AppKit
import WebKit

/// The "Open LocalFlow" landing window: a sidebar of tabs over content that
/// mostly re-embeds existing controllers/views rather than re-implementing
/// them. Singleton like `SettingsController` — closing the window just hides
/// it.
final class DashboardController: NSObject, NSWindowDelegate {

    static let shared = DashboardController()

    /// Wired by `AppDelegate` to open the app-wide Scratchpad window (the
    /// Scratchpad tab keeps a single shared note buffer rather than a second,
    /// diverging one, so it opens the existing window instead of embedding).
    var onOpenScratchpad: (() -> Void)?

    /// Dedicated instance for the embedded Settings tab, distinct from
    /// AppDelegate's standalone `SettingsController` so the two don't fight
    /// over the same control references when both are visible. `AppDelegate`
    /// forwards the same callbacks to both.
    let settings = SettingsController()

    private enum Tab: Int, CaseIterable {
        case home, settings, history, voiceProfile, scratchpad

        var title: String {
            switch self {
            case .home: return "Home"
            case .settings: return "Settings"
            case .history: return "History"
            case .voiceProfile: return "Voice Profile"
            case .scratchpad: return "Scratchpad"
            }
        }

        var symbolName: String {
            switch self {
            case .home: return "house"
            case .settings: return "gearshape"
            case .history: return "clock"
            case .voiceProfile: return "waveform"
            case .scratchpad: return "note.text"
            }
        }
    }

    private var window: NSWindow?
    private var contentContainer: NSView?
    private var sidebarButtons: [NSButton] = []
    private var selectedTab: Tab = .home

    private var parakeetLabel: NSTextField?
    private var whisperLabel: NSTextField?
    private var ollamaLabel: NSTextField?
    private var micLabel: NSTextField?
    private var parakeetDot: NSView?
    private var whisperDot: NSView?
    private var ollamaDot: NSView?
    private var micDot: NSView?
    private var cleanupLevelPopup: NSPopUpButton?
    private var languagePopup: NSPopUpButton?
    private var quietModeCheck: NSButton?
    private var launchCheck: NSButton?

    private let webView = WKWebView()

    func show() {
        if window == nil {
            build()
        }
        selectTab(.home)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "LocalFlow"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.minSize = NSSize(width: 800, height: 520)
        win.center()

        let sidebar = buildSidebar()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: win.contentLayoutRect)
        root.addSubview(sidebar)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 160),

            container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        win.contentView = root
        window = win
        contentContainer = container
    }

    private func buildSidebar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Extra top inset clears the transparent titlebar's traffic-light buttons.
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 10, bottom: 16, right: 10)

        let logo = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: "LocalFlow")!)
        logo.contentTintColor = .controlAccentColor
        let wordmark = NSTextField(labelWithString: "LocalFlow")
        wordmark.font = .boldSystemFont(ofSize: 15)
        let brand = NSStackView(views: [logo, wordmark])
        brand.orientation = .horizontal
        brand.spacing = 6
        brand.alignment = .centerY
        brand.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 10, right: 0)
        stack.addArrangedSubview(brand)

        for tab in Tab.allCases {
            let button = NSButton(title: " \(tab.title)", target: self, action: #selector(sidebarTapped(_:)))
            button.tag = tab.rawValue
            button.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            button.imagePosition = .imageLeading
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            button.isBordered = true
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 140).isActive = true
            stack.addArrangedSubview(button)
            sidebarButtons.append(button)
        }
        return stack
    }

    @objc private func sidebarTapped(_ sender: NSButton) {
        guard let tab = Tab(rawValue: sender.tag) else { return }
        selectTab(tab)
    }

    private func selectTab(_ tab: Tab) {
        selectedTab = tab
        for button in sidebarButtons {
            button.state = button.tag == tab.rawValue ? .on : .off
        }
        guard let container = contentContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = contentView(for: tab)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func contentView(for tab: Tab) -> NSView {
        switch tab {
        case .home: return buildHomeTab()
        case .settings:
            return wrapped(settings.embeddableContentView())
        case .history:
            webView.loadHTMLString(HistoryView.html(), baseURL: nil)
            return webView
        case .voiceProfile:
            webView.loadHTMLString(VoiceProfileStore.html(), baseURL: nil)
            return webView
        case .scratchpad:
            return buildScratchpadTab()
        }
    }

    private func wrapped(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
        ])
        return container
    }

    // MARK: - Home tab

    private func buildHomeTab() -> NSView {
        let records = VoiceProfileStore.loadAllRecords()

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 24
        root.translatesAutoresizingMaskIntoConstraints = false
        root.edgeInsets = NSEdgeInsets(top: 36, left: 28, bottom: 28, right: 28)

        root.addArrangedSubview(buildGreeting())

        let timeline = buildTimeline(records: records)
        let rail = buildRightRail(records: records)
        let columns = NSStackView(views: [timeline, rail])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 24
        rail.widthAnchor.constraint(equalToConstant: 260).isActive = true
        root.addArrangedSubview(columns)
        columns.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true
        columns.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -140).isActive = true

        refreshStatus()
        return root
    }

    /// Short hotkey label for the greeting chip / empty state, e.g. "right ⌥".
    private var hotkeyShortName: String {
        switch Config.hotkey {
        case .rightOption: return "right ⌥"
        case .fn: return "fn 🌐"
        }
    }

    private func buildGreeting() -> NSView {
        let firstName = NSFullUserName().components(separatedBy: " ").first ?? "there"
        let greeting = NSTextField(labelWithString: "Hey \(firstName), get back into the flow with")
        greeting.font = .systemFont(ofSize: 23, weight: .semibold)

        let chip = NSTextField(labelWithString: " \(hotkeyShortName) ")
        chip.font = .systemFont(ofSize: 15, weight: .semibold)
        chip.textColor = .controlAccentColor
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        chip.layer?.cornerRadius = 6

        let row = NSStackView(views: [greeting, chip])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // MARK: - Timeline (left column)

    private func buildTimeline(records: [DictationRecord]) -> NSView {
        let recent = records.sorted { $0.ts > $1.ts }.prefix(25)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        if recent.isEmpty {
            let empty = NSTextField(
                wrappingLabelWithString: "Your dictations will appear here — hold \(hotkeyShortName) and speak."
            )
            empty.font = .systemFont(ofSize: 14)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            let container = NSView()
            empty.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                empty.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            ])
            return container
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMMM d, yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        var currentDay: DateComponents?
        let calendar = Calendar.current
        for record in recent {
            let day = calendar.dateComponents([.era, .year, .month, .day], from: record.ts)
            if day != currentDay {
                currentDay = day
                let headerLabel = NSTextField(labelWithString: dayFormatter.string(from: record.ts).uppercased())
                headerLabel.font = .boldSystemFont(ofSize: 11)
                headerLabel.textColor = .secondaryLabelColor
                let headerBox = NSView()
                headerLabel.translatesAutoresizingMaskIntoConstraints = false
                headerBox.addSubview(headerLabel)
                NSLayoutConstraint.activate([
                    headerLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
                    headerLabel.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 16),
                    headerLabel.bottomAnchor.constraint(equalTo: headerBox.bottomAnchor, constant: -6),
                ])
                stack.addArrangedSubview(headerBox)
            }
            let row = timelineRow(record: record, timeString: timeFormatter.string(from: record.ts).lowercased())
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let clipDoc = FlippedView()
        clipDoc.translatesAutoresizingMaskIntoConstraints = false
        clipDoc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipDoc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipDoc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipDoc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: clipDoc.bottomAnchor),
        ])
        scroll.documentView = clipDoc
        clipDoc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func timelineRow(record: DictationRecord, timeString: String) -> NSView {
        let time = NSTextField(labelWithString: timeString)
        time.font = .systemFont(ofSize: 12)
        time.textColor = .secondaryLabelColor
        time.translatesAutoresizingMaskIntoConstraints = false
        time.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let textValue = record.finalText ?? record.rawText
        let text = NSTextField(wrappingLabelWithString: textValue)
        text.font = .systemFont(ofSize: 13)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 3
        text.cell?.truncatesLastVisibleLine = true

        let row = HoverRowView(copyText: textValue)
        let content = NSStackView(views: [time, text, row.copyButton])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
        ])

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        return row
    }

    // MARK: - Right rail

    private func buildRightRail(records: [DictationRecord]) -> NSView {
        let total = totalWords(records: records)
        let wordsPerMinute = wpm(records: records)
        let streak = dayStreak(records: records, now: Date())

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let statsStack = NSStackView(views: [
            railStat(value: "\(total)", caption: "total words"),
            railStat(value: "\(Int(wordsPerMinute.rounded()))", caption: "wpm"),
            railStat(value: "\(streak)", caption: "day streak"),
        ])
        statsStack.orientation = .vertical
        statsStack.alignment = .leading
        statsStack.spacing = 12
        let statsCard = card(statsStack)
        stack.addArrangedSubview(statsCard)
        statsCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let profileCard = buildVoiceProfileCard(totalWords: total)
        stack.addArrangedSubview(profileCard)
        profileCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let statusCard = buildCompactStatusCard()
        stack.addArrangedSubview(statusCard)
        statusCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    /// Big serif number over a small caption — the Wispr-style rail stat.
    private func railStat(value: String, caption: String) -> NSView {
        let number = NSTextField(labelWithString: value)
        number.font = serifFont(ofSize: 30, weight: .semibold)
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [number, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    private func serifFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: descriptor, size: size) else { return base }
        return serif
    }

    private func buildVoiceProfileCard(totalWords total: Int) -> NSView {
        let title = NSTextField(labelWithString: "Your Voice Profile")
        title.font = .boldSystemFont(ofSize: 13)

        let remaining = wordsToNextMilestone(totalWords: total)
        let progress = Double(1000 - remaining) / 1000.0

        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        track.layer?.cornerRadius = 2
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 4).isActive = true
        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.layer?.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.01, progress)),
        ])

        let caption = NSTextField(labelWithString: "Unlocks in \(remaining) words")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, track, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        track.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let container = card(stack)
        let click = NSClickGestureRecognizer(target: self, action: #selector(voiceProfileCardTapped))
        container.addGestureRecognizer(click)
        return container
    }

    @objc private func voiceProfileCardTapped() {
        selectTab(.voiceProfile)
    }

    private func buildCompactStatusCard() -> NSView {
        let parakeet = statusRow("Parakeet")
        let whisper = statusRow("Whisper server")
        let ollama = statusRow("Ollama")
        let mic = statusRow("Microphone")
        parakeetLabel = parakeet.1
        whisperLabel = whisper.1
        ollamaLabel = ollama.1
        micLabel = mic.1
        parakeetDot = parakeet.2
        whisperDot = whisper.2
        ollamaDot = ollama.2
        micDot = mic.2

        let stack = NSStackView(views: [parakeet.0, whisper.0, ollama.0, mic.0, buildQuickToggles()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return card(stack, padding: 12)
    }

    private func header(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Rounded, bordered card container — the shared "premium" surface for
    /// grouping related content on the Home tab.
    private func card(_ content: NSView, padding: CGFloat = 16) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        ])
        return container
    }

    private func statusDot() -> NSView {
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        return dot
    }

    private func statusRow(_ title: String) -> (NSView, NSTextField, NSView) {
        let dot = statusDot()
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        let value = NSTextField(labelWithString: "checking…")
        value.font = .systemFont(ofSize: 12)
        value.textColor = .secondaryLabelColor
        let row = NSStackView(views: [dot, name, value])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return (row, value, dot)
    }

    private func setStatus(dot: NSView?, label: NSTextField?, ok: Bool, okText: String, badText: String) {
        label?.stringValue = ok ? okText : badText
        dot?.layer?.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemRed).cgColor
    }

    private func refreshStatus() {
        setStatus(dot: parakeetDot, label: parakeetLabel, ok: ParakeetTranscriber.shared.isReady, okText: "Ready", badText: "Not ready")

        WhisperServerManager().checkHealth { [weak self] alive in
            guard let self else { return }
            self.setStatus(dot: self.whisperDot, label: self.whisperLabel, ok: alive, okText: "Running", badText: "Not running")
        }

        checkOllamaReachable { [weak self] reachable in
            guard let self else { return }
            self.setStatus(dot: self.ollamaDot, label: self.ollamaLabel, ok: reachable, okText: "Reachable", badText: "Unreachable")
        }

        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        setStatus(dot: micDot, label: micLabel, ok: micGranted, okText: "Granted", badText: "Not granted")
    }

    /// Short-timeout reachability probe against Ollama's tags endpoint —
    /// just "is something listening", not a real API call.
    private func checkOllamaReachable(_ completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(OllamaCleaner.baseURL)/api/tags") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let reachable = response is HTTPURLResponse
            DispatchQueue.main.async { completion(reachable) }
        }.resume()
    }

    private func buildQuickToggles() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let level = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in CleanupLevel.allCases {
            level.addItem(withTitle: choice.displayName)
            level.lastItem?.representedObject = choice.rawValue
        }
        level.target = self
        level.action = #selector(cleanupLevelChanged)
        for item in level.itemArray where (item.representedObject as? String) == Config.cleanupLevel.rawValue {
            level.select(item)
        }
        cleanupLevelPopup = level
        stack.addArrangedSubview(labeled("Cleanup level:", level))

        let language = NSPopUpButton(frame: .zero, pullsDown: false)
        for entry in SettingsController.languages {
            language.addItem(withTitle: entry.label)
            language.lastItem?.representedObject = entry.code
        }
        language.target = self
        language.action = #selector(languageChanged)
        for item in language.itemArray where (item.representedObject as? String) == Config.whisperLanguage {
            language.select(item)
        }
        languagePopup = language
        stack.addArrangedSubview(labeled("Language:", language))

        let quiet = NSButton(checkboxWithTitle: "Quiet mode", target: self, action: #selector(quietModeChanged))
        quiet.state = Config.quietModeEnabled ? .on : .off
        quietModeCheck = quiet
        stack.addArrangedSubview(quiet)

        let launch = NSButton(
            checkboxWithTitle: "Open this dashboard on launch",
            target: self,
            action: #selector(launchToggleChanged)
        )
        launch.state = Config.openDashboardOnLaunch ? .on : .off
        launchCheck = launch
        stack.addArrangedSubview(launch)

        return stack
    }

    private func labeled(_ text: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    @objc private func cleanupLevelChanged() {
        guard let raw = cleanupLevelPopup?.selectedItem?.representedObject as? String,
              let level = CleanupLevel(rawValue: raw) else { return }
        Config.cleanupLevel = level
    }

    @objc private func languageChanged() {
        guard let code = languagePopup?.selectedItem?.representedObject as? String else { return }
        Config.whisperLanguage = code
    }

    @objc private func quietModeChanged(_ sender: NSButton) {
        Config.quietModeEnabled = sender.state == .on
    }

    @objc private func launchToggleChanged(_ sender: NSButton) {
        Config.openDashboardOnLaunch = sender.state == .on
    }

    // MARK: - Scratchpad tab (fallback: opens the shared window)

    private func buildScratchpadTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let note = NSTextField(labelWithString: "Scratchpad keeps a single shared note, so it opens in its own window.")
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        let open = NSButton(title: "Open Scratchpad…", target: self, action: #selector(openScratchpadTapped))
        open.bezelStyle = .rounded
        stack.addArrangedSubview(open)
        return stack
    }

    @objc private func openScratchpadTapped() {
        onOpenScratchpad?()
    }
}

/// Scroll document view that lays out top-down so the timeline starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Timeline row that shows a copy button only while hovered.
private final class HoverRowView: NSView {
    let copyButton: NSButton
    private let copyText: String

    init(copyText: String) {
        self.copyText = copyText
        let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        copyButton.isHidden = true
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        copyButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        copyButton.isHidden = true
    }
}
