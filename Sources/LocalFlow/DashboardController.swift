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
    }

    private var window: NSWindow?
    private var contentContainer: NSView?
    private var sidebarButtons: [NSButton] = []
    private var selectedTab: Tab = .home

    private var parakeetLabel: NSTextField?
    private var whisperLabel: NSTextField?
    private var ollamaLabel: NSTextField?
    private var micLabel: NSTextField?
    private var cleanupLevelPopup: NSPopUpButton?
    private var languagePopup: NSPopUpButton?
    private var quietModeCheck: NSButton?
    private var launchCheck: NSButton?
    private var todayWordsLabel: NSTextField?
    private var weekWordsLabel: NSTextField?
    private var avgLatencyLabel: NSTextField?
    private var timeSavedLabel: NSTextField?
    private var p50LatencyLabel: NSTextField?
    private var p95LatencyLabel: NSTextField?

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "LocalFlow"
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
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)

        for tab in Tab.allCases {
            let button = NSButton(title: tab.title, target: self, action: #selector(sidebarTapped(_:)))
            button.tag = tab.rawValue
            button.bezelStyle = .rounded
            button.setButtonType(.pushOnPushOff)
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
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        stack.addArrangedSubview(header("Status"))
        let parakeet = statusRow("Parakeet")
        let whisper = statusRow("Whisper server")
        let ollama = statusRow("Ollama")
        let mic = statusRow("Microphone permission")
        parakeetLabel = parakeet.1
        whisperLabel = whisper.1
        ollamaLabel = ollama.1
        micLabel = mic.1
        [parakeet.0, whisper.0, ollama.0, mic.0].forEach { stack.addArrangedSubview($0) }

        stack.addArrangedSubview(header("Quick Settings"))
        stack.addArrangedSubview(buildQuickToggles())

        stack.addArrangedSubview(header("This Week"))
        stack.addArrangedSubview(buildStatsStrip())

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

    private func statusRow(_ title: String) -> (NSView, NSTextField) {
        let name = NSTextField(labelWithString: "\(title):")
        let value = NSTextField(labelWithString: "checking…")
        value.textColor = .secondaryLabelColor
        let row = NSStackView(views: [name, value])
        row.orientation = .horizontal
        row.spacing = 6
        return (row, value)
    }

    private func refreshStatus() {
        parakeetLabel?.stringValue = ParakeetTranscriber.shared.isReady ? "Ready" : "Not ready"

        WhisperServerManager().checkHealth { [weak self] alive in
            self?.whisperLabel?.stringValue = alive ? "Running" : "Not running"
        }

        checkOllamaReachable { [weak self] reachable in
            self?.ollamaLabel?.stringValue = reachable ? "Reachable" : "Unreachable"
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micLabel?.stringValue = micStatus == .authorized ? "Granted" : "Not granted"
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
        let today = statCard("today", &todayWordsLabel)
        let week = statCard("this week", &weekWordsLabel)
        let latency = statCard("avg latency", &avgLatencyLabel)
        let saved = statCard("time saved", &timeSavedLabel)
        let p50 = statCard("p50 latency", &p50LatencyLabel)
        let p95 = statCard("p95 latency", &p95LatencyLabel)
        let row = NSStackView(views: [today, week, latency, saved, p50, p95])
        row.orientation = .horizontal
        row.spacing = 16
        return row
    }

    private func statCard(_ label: String, _ target: inout NSTextField?) -> NSView {
        let value = NSTextField(labelWithString: "—")
        value.font = NSFont.boldSystemFont(ofSize: 18)
        target = value
        let caption = NSTextField(labelWithString: label)
        caption.font = NSFont.systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [value, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func refreshStats() {
        let records = VoiceProfileStore.loadAllRecords()
        let stats = computeDashboardStats(records: records, now: Date())
        todayWordsLabel?.stringValue = "\(stats.todayWords)"
        weekWordsLabel?.stringValue = "\(stats.weekWords)"
        avgLatencyLabel?.stringValue = String(format: "%.1fs", stats.avgLatencySec)
        timeSavedLabel?.stringValue = String(format: "%.0fm", stats.timeSavedMinutes)
        p50LatencyLabel?.stringValue = String(format: "%.1fs", stats.p50TakeLatencySec)
        p95LatencyLabel?.stringValue = String(format: "%.1fs", stats.p95TakeLatencySec)
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
