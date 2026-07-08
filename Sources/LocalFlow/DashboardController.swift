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
    private var todayWordsLabel: NSTextField?
    private var weekWordsLabel: NSTextField?
    private var timeSavedLabel: NSTextField?
    private var timeSavedSubLabel: NSTextField?
    private var p50LatencyLabel: NSTextField?
    private var latencySubLabel: NSTextField?

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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "LocalFlow"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.minSize = NSSize(width: 620, height: 420)
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
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 28, bottom: 28, right: 28)

        stack.addArrangedSubview(buildStatsStrip())
        stack.addArrangedSubview(header("Status"))
        stack.addArrangedSubview(buildStatusCard())
        stack.addArrangedSubview(header("Quick Settings"))
        stack.addArrangedSubview(card(buildQuickToggles()))

        refreshStatus()
        refreshStats()
        return stack
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

    private func buildStatusCard() -> NSView {
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

        let grid = NSGridView(views: [[parakeet.0, ollama.0], [whisper.0, mic.0]])
        grid.rowSpacing = 10
        grid.columnSpacing = 24
        return card(grid)
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

    private func buildStatsStrip() -> NSView {
        let today = heroStatCard("today", &todayWordsLabel)
        let week = heroStatCard("this week", &weekWordsLabel)
        let saved = heroStatCard("time saved", &timeSavedLabel, sub: &timeSavedSubLabel)
        let p50 = heroStatCard("p50 latency", &p50LatencyLabel, sub: &latencySubLabel)
        let row = NSStackView(views: [today, week, saved, p50])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 14
        return row
    }

    /// Big bold number + small caption, optionally with a secondary detail
    /// line underneath (e.g. "≈3.2x faster than typing").
    private func heroStatCard(
        _ label: String,
        _ target: inout NSTextField?,
        sub subTarget: inout NSTextField?
    ) -> NSView {
        let value = NSTextField(labelWithString: "—")
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        target = value
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        let sub = NSTextField(labelWithString: "")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .tertiaryLabelColor
        subTarget = sub
        let stack = NSStackView(views: [value, caption, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return card(stack, padding: 16)
    }

    private func heroStatCard(_ label: String, _ target: inout NSTextField?) -> NSView {
        var noSub: NSTextField?
        return heroStatCard(label, &target, sub: &noSub)
    }

    private func refreshStats() {
        let records = VoiceProfileStore.loadAllRecords()
        let stats = computeDashboardStats(records: records, now: Date())
        todayWordsLabel?.stringValue = "\(stats.todayWords)"
        weekWordsLabel?.stringValue = "\(stats.weekWords)"
        timeSavedLabel?.stringValue = String(format: "%.0fm", stats.timeSavedMinutes)
        p50LatencyLabel?.stringValue = String(format: "%.1fs", stats.p50TakeLatencySec)
        latencySubLabel?.stringValue = String(format: "avg %.1fs · p95 %.1fs", stats.avgLatencySec, stats.p95TakeLatencySec)

        let speedup = speedupMultiplier(words: stats.weekWords, speakingMinutes: stats.speakingMinutes)
        timeSavedSubLabel?.stringValue = speedup > 0 ? String(format: "≈%.1fx faster than typing", speedup) : ""
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
