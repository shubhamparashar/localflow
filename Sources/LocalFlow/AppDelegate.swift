import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let partialCaptionRunner = PartialCaptionRunner()
    private let injector = TextInjector()
    private let server = WhisperServerManager()
    private let hud = OverlayHUD()
    private lazy var scratchpad = ScratchpadController()
    private let settings = SettingsController()
    private lazy var onboarding = OnboardingController()

    private enum State {
        case startingServer
        case serverFailed
        case idle
        case recording
        case transcribing
    }

    private var state: State = .startingServer {
        didSet { updateStatusIcon() }
    }

    private var pressStartedAt: Date?
    private var handsFreeArmed = false
    private var sessionIsCommand = false
    private var commandSelection: String?
    private var lastRawTranscript: String?
    private var sessionProfile: AppCategoryProfile?
    private var sessionFieldContext: String?

    private static let tapMaxDuration: TimeInterval = 0.35

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("LocalFlow launched")
        Glossary.ensureFileExists()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        setupStatusItem()
        ensurePermissions()
        maybeShowOnboarding()
        OllamaCleaner.warmUp()

        ModelDownloader.shared.onStatusChange = { [weak self] in
            self?.rebuildMenu()
        }
        ModelDownloader.shared.ensureModels { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.state = .serverFailed
                self.rebuildMenu()
                return
            }
            self.server.ensureRunning { [weak self] ok in
                guard let self else { return }
                self.state = ok ? .idle : .serverFailed
                self.rebuildMenu()
            }
        }
        if Config.whisperLanguage == "en" {
            ParakeetTranscriber.shared.prepare { [weak self] ready in
                Log.info("Parakeet engine ready: \(ready)")
                self?.rebuildMenu()
            }
        }

        recorder.onAutoStop = { [weak self] in
            guard let self, self.handsFreeArmed else { return }
            self.endDictation()
        }
        recorder.onLevel = { [weak self] dbfs in
            self?.hud.updateLevel(dbfs)
        }
        recorder.onPartialAudio = { [weak self] samples in
            self?.handlePartialAudio(samples)
        }
        recorder.isPartialInferenceBusy = { [weak self] in
            self?.partialCaptionRunner.isBusy ?? true
        }
        hud.onToggle = { [weak self] in self?.toggleDictationFromHUD() }
        hud.onHideForOneHour = { [weak self] in self?.hideHUDForOneHour() }
        hud.onQuit = { NSApp.terminate(nil) }
        settings.onChanged = { [weak self] in
            self?.rebuildMenu()
            self?.refreshIdleHUD()
        }
        settings.onCleanupEnabled = { enabled in
            if enabled { OllamaCleaner.warmUp() }
        }
        settings.onLanguageChanged = { [weak self] code in
            guard code == "en", !ParakeetTranscriber.shared.isReady else { return }
            ParakeetTranscriber.shared.prepare { ready in
                Log.info("Parakeet engine ready: \(ready)")
                self?.rebuildMenu()
            }
        }
        settings.onLoginItemChanged = { [weak self] enabled in
            self?.setLoginItem(enabled)
        }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onCommandPress = { [weak self] in self?.commandPressed() }
        hotkey.onCommandRelease = { [weak self] in self?.commandReleased() }
        hotkey.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    /// Fired when the user opens the app while it's already running — the
    /// usual "nothing happened, is it even launched?" confusion for a
    /// menu-bar-only app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "LocalFlow is already running"
        alert.informativeText = "Look for the mic icon in the right side of the menu bar. If you don't see it, it may be hidden under the notch — remove some other menu-bar icons (Cmd-drag them off) to make room.\n\nHold right-⌥ and speak to dictate."
        alert.alertStyle = .informational
        alert.runModal()
        return false
    }

    // MARK: - Dictation flow

    /// Hold = push-to-talk (release stops). Quick tap = hands-free: keep
    /// recording until VAD detects the utterance ended, or a second tap.
    private func hotkeyPressed() {
        if state == .recording && handsFreeArmed {
            endDictation()
            return
        }
        pressStartedAt = Date()
        handsFreeArmed = false
        beginDictation()
    }

    private func hotkeyReleased() {
        guard state == .recording, !handsFreeArmed else { return }
        let heldFor = Date().timeIntervalSince(pressStartedAt ?? .distantPast)
        if Config.handsFreeEnabled && !sessionIsCommand && heldFor < Self.tapMaxDuration {
            handsFreeArmed = true
            recorder.enableAutoStop()
            Log.info("Hands-free armed (tap), waiting for VAD auto-stop")
        } else {
            endDictation()
        }
    }

    /// Command mode (Shift + hotkey): capture the current selection, record
    /// a spoken instruction, apply it via the LLM, and paste the result over
    /// the still-active selection.
    private func commandPressed() {
        guard state == .idle || state == .transcribing else { return }
        sessionIsCommand = true
        commandSelection = nil
        pressStartedAt = Date()
        handsFreeArmed = false
        beginDictation()
    }

    private func commandReleased() {
        guard state == .recording, sessionIsCommand else { return }
        endDictation()
    }

    private func beginDictation() {
        guard state == .idle || state == .transcribing else { return }
        guard !improveInFlight else {
            Log.info("Dictation rejected: improve in flight")
            return
        }
        // The user is done editing the previous dictation by now — harvest
        // any respellings they made as glossary suggestions.
        CorrectionWatcher.shared.checkPending()
        // Captured at press time: the app the user is dictating into.
        sessionProfile = AppContext.currentProfile()
        sessionFieldContext = FieldContext.capture()
        partialCaptionRunner.cancel()
        do {
            try recorder.start()
            state = .recording
            if Config.playStartSound {
                NSSound(named: "Tink")?.play()
            }
        } catch {
            Log.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private var stopScheduled = false

    private func endDictation() {
        guard state == .recording, !stopScheduled else { return }
        stopScheduled = true
        partialCaptionRunner.cancel()
        // Wait for the speaker to actually pause (up to 1.5 s) so a key
        // released mid-word doesn't clip the utterance.
        recorder.stopAfterTrailingSilence { [weak self] wav in
            self?.processRecording(wav)
        }
    }

    /// Live caption for the Flow-Bar while recording — HUD-only, never part
    /// of the final transcript. Runs only when Parakeet is the active
    /// engine; whisper-server dictations skip partials entirely so the pill
    /// behaves exactly as before.
    private func handlePartialAudio(_ samples: [Float]) {
        guard Config.whisperLanguage == "en", ParakeetTranscriber.shared.isReady else { return }
        partialCaptionRunner.run(samples: samples) { [weak self] caption in
            guard let self, self.state == .recording else { return }
            Log.info("Partial caption (\(caption.count) chars)")
            self.hud.updateCaption(caption)
        }
    }

    private func processRecording(_ wav: Data?) {
        stopScheduled = false
        let isCommand = sessionIsCommand
        let mode = isCommand ? "command" : (handsFreeArmed ? "handsFree" : "hold")
        handsFreeArmed = false
        sessionIsCommand = false
        guard let wav else {
            state = .idle
            return
        }
        // Keep the most recent utterance on disk so transcription issues
        // can be reproduced offline against the same audio.
        let lastRecording = Log.dir.appendingPathComponent("last-recording.wav")
        try? wav.write(to: lastRecording)
        state = .transcribing
        if isCommand {
            // Selection is captured now — after key release — so the
            // synthetic Cmd+C isn't polluted by the physically-held
            // Shift+Option of the command gesture.
            injector.captureSelection { [weak self] selection in
                guard let self else { return }
                self.commandSelection = selection
                Log.info("Command mode: selection \(selection.map { "\($0.count) chars" } ?? "none")")
                self.transcribeAndRoute(wav, isCommand: true, mode: mode)
            }
        } else {
            transcribeAndRoute(wav, isCommand: false, mode: mode)
        }
    }

    private func transcribeAndRoute(_ wav: Data, isCommand: Bool, mode: String) {
        let sttStarted = Date()
        let profile = sessionProfile
        let fieldContext = sessionFieldContext
        TranscriptionRouter.transcribe(wav: wav, fieldContext: fieldContext) { [weak self] result in
            guard let self else { return }
            let sttSeconds = Date().timeIntervalSince(sttStarted)
            self.state = .idle
            switch result {
            case .success(let text):
                guard !text.isEmpty else {
                    Log.info("Empty transcript, nothing to inject")
                    return
                }
                if isCommand {
                    self.runCommand(instruction: text)
                } else {
                    self.lastRawTranscript = text
                    let willClean = Config.cleanupEnabled
                        && text.count >= OllamaCleaner.minimumLength
                        && (profile?.cleanupEnabled ?? true)
                    if willClean { self.hud.show(.cleaning) }
                    let cleanupStarted = Date()
                    if let profile, willClean {
                        Log.info("Cleanup context: \(profile.category)")
                    }
                    OllamaCleaner.clean(text, profile: profile, fieldContext: fieldContext) { cleaned in
                        if self.state != .recording { self.refreshIdleHUD() }
                        var final = cleaned
                        if profile?.stripTrailingPeriod == true,
                           final.hasSuffix("."),
                           !final.contains("\n") {
                            final = String(final.dropLast())
                        }
                        final = SnippetsEngine.apply(final)
                        self.injector.inject(final)
                        CorrectionWatcher.shared.recordInjection(final)
                        let record = DictationRecord(
                            ts: Date(),
                            durationSec: self.recorder.lastDurationSec,
                            rawWords: Self.wordCount(text),
                            finalWords: Self.wordCount(final),
                            mode: mode,
                            sttSeconds: sttSeconds,
                            cleanupSeconds: willClean ? Date().timeIntervalSince(cleanupStarted) : nil,
                            rawText: text,
                            finalText: final,
                            app: profile?.category
                        )
                        VoiceProfileStore.record(record)
                    }
                }
            case .failure:
                break
            }
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func runCommand(instruction: String) {
        guard let selection = commandSelection, !selection.isEmpty else {
            Log.info("Command mode: no selection captured, ignoring instruction")
            return
        }
        Log.info("Command mode: applying \"\(instruction.prefix(80))\" to \(selection.count) chars")
        OllamaCleaner.applyCommand(instruction: instruction, to: selection) { [weak self] result in
            switch result {
            case .success(let edited) where !edited.isEmpty:
                self?.injector.inject(edited)
            case .success:
                Log.error("Command mode: empty result, leaving selection untouched")
            case .failure(let error):
                Log.error("Command mode failed (is Ollama running?): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - URL scheme (localflow://start|stop|toggle|paste-last|paste-raw)

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        let command = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Log.info("URL trigger: \(command)")
        switch command {
        case "start":
            startHandsFreeDictation()
        case "stop":
            endDictation()
        case "toggle":
            if state == .recording {
                endDictation()
            } else {
                startHandsFreeDictation()
            }
        case "paste-last":
            injector.pasteLastTranscript()
        case "paste-raw":
            if let raw = lastRawTranscript { injector.inject(raw) }
        default:
            Log.error("Unknown URL command: \(command)")
        }
    }

    /// Starts a hands-free (VAD auto-stop) dictation, as used by URL triggers.
    private func startHandsFreeDictation() {
        guard state == .idle || state == .transcribing else { return }
        handsFreeArmed = false
        sessionIsCommand = false
        beginDictation()
        if state == .recording {
            handsFreeArmed = true
            recorder.enableAutoStop()
        }
    }

    // MARK: - Permissions

    private func ensurePermissions() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Log.info("Accessibility trusted: \(trusted)")

        AudioRecorder.requestPermission { granted in
            Log.info("Microphone permission granted: \(granted)")
        }
    }

    // MARK: - Status item / menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        rebuildMenu()
    }

    private func updateStatusIcon() {
        let symbolName: String
        switch state {
        case .startingServer: symbolName = "hourglass"
        case .serverFailed: symbolName = "mic.slash"
        case .idle: symbolName = "mic"
        case .recording: symbolName = "mic.fill"
        case .transcribing: symbolName = "waveform"
        }
        DispatchQueue.main.async {
            self.statusItem.button?.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: "LocalFlow"
            )
            switch self.state {
            case .recording:
                self.hud.show(.recording(handsFree: self.handsFreeArmed))
            case .transcribing:
                self.hud.show(.transcribing)
            case .idle:
                self.refreshIdleHUD()
            case .startingServer, .serverFailed:
                self.hud.hide()
            }
        }
    }

    /// Shows the always-on idle Flow-Bar when enabled and not snoozed; hides
    /// it otherwise. Only meaningful while idle — recording/transcribing drive
    /// their own HUD state.
    private func refreshIdleHUD() {
        guard state == .idle else { return }
        let snoozed = Date() < Config.hudHiddenUntil
        if Config.showIdleHUD && !snoozed {
            hud.show(.idle)
        } else {
            hud.hide()
        }
    }

    private func toggleDictationFromHUD() {
        if state == .recording {
            endDictation()
        } else {
            startHandsFreeDictation()
        }
    }

    private func hideHUDForOneHour() {
        Config.hudHiddenUntil = Date().addingTimeInterval(60 * 60)
        hud.hide()
        Log.info("Flow-Bar hidden for 1 hour")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let statusTitle: String
        if case .downloading(let name, let progress) = ModelDownloader.shared.status {
            statusTitle = "Downloading \(name) — \(Int(progress * 100))%"
        } else {
            switch state {
            case .startingServer: statusTitle = "Whisper: loading model…"
            case .serverFailed: statusTitle = "Whisper: failed — see logs"
            default: statusTitle = "Engine: \(TranscriptionRouter.activeEngineName)"
            }
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let welcomeItem = NSMenuItem(
            title: "Setup Guide…",
            action: #selector(showOnboarding),
            keyEquivalent: ""
        )
        welcomeItem.target = self
        menu.addItem(welcomeItem)
        menu.addItem(.separator())

        let pasteLast = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLastTranscript),
            keyEquivalent: "v"
        )
        pasteLast.target = self
        menu.addItem(pasteLast)

        if Config.cleanupEnabled, let raw = lastRawTranscript, raw != injector.lastTranscript {
            let pasteRaw = NSMenuItem(
                title: "Paste Raw (Uncleaned) Transcript",
                action: #selector(pasteRawTranscript),
                keyEquivalent: ""
            )
            pasteRaw.target = self
            menu.addItem(pasteRaw)
        }

        let improve = NSMenuItem(
            title: "Improve Selected Text",
            action: #selector(improveSelectedText),
            keyEquivalent: ""
        )
        improve.target = self
        menu.addItem(improve)

        let scratchpadItem = NSMenuItem(
            title: "Scratchpad…",
            action: #selector(showScratchpad),
            keyEquivalent: ""
        )
        scratchpadItem.target = self
        menu.addItem(scratchpadItem)
        menu.addItem(.separator())

        let cleanup = NSMenuItem(
            title: "AI Cleanup via Ollama (\(Config.ollamaModel))",
            action: #selector(toggleCleanup),
            keyEquivalent: ""
        )
        cleanup.target = self
        cleanup.state = Config.cleanupEnabled ? .on : .off
        menu.addItem(cleanup)

        let glossary = NSMenuItem(
            title: "Edit Glossary…",
            action: #selector(editGlossary),
            keyEquivalent: ""
        )
        glossary.target = self
        menu.addItem(glossary)

        let snippetCount = SnippetsEngine.count()
        let snippets = NSMenuItem(
            title: snippetCount > 0 ? "Edit Snippets… (\(snippetCount))" : "Edit Snippets…",
            action: #selector(editSnippets),
            keyEquivalent: ""
        )
        snippets.target = self
        menu.addItem(snippets)

        let categories = NSMenuItem(
            title: "Edit App Categories…",
            action: #selector(editAppCategories),
            keyEquivalent: ""
        )
        categories.target = self
        menu.addItem(categories)

        if FileManager.default.fileExists(atPath: CorrectionWatcher.suggestionsFile.path) {
            let suggestions = NSMenuItem(
                title: "Review Learned Words…",
                action: #selector(reviewLearnedWords),
                keyEquivalent: ""
            )
            suggestions.target = self
            menu.addItem(suggestions)
        }
        menu.addItem(.separator())

        let hotkeyMenu = NSMenu()
        for choice in HotkeyChoice.allCases {
            let item = NSMenuItem(
                title: choice.displayName,
                action: #selector(selectHotkey(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = choice.rawValue
            item.state = Config.hotkey == choice ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyRoot = NSMenuItem(title: "Push-to-Talk Key", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyRoot)
        menu.setSubmenu(hotkeyMenu, for: hotkeyRoot)

        let profile = NSMenuItem(
            title: "Voice Profile…",
            action: #selector(showVoiceProfile),
            keyEquivalent: ""
        )
        profile.target = self
        menu.addItem(profile)

        let history = NSMenuItem(
            title: "History…",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)

        let languageMenu = NSMenu()
        for (code, label) in [
            ("en", "English"),
            ("hinglish", "Hinglish (Roman mix)"),
            ("hi", "Hindi (हिन्दी)"),
            ("auto", "Auto-detect"),
        ] {
            let item = NSMenuItem(title: label, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = Config.whisperLanguage == code ? .on : .off
            languageMenu.addItem(item)
        }
        languageMenu.addItem(.separator())
        let moreMenu = NSMenu()
        for entry in Config.whisperLanguages where entry.code != "en" && entry.code != "hi" {
            let item = NSMenuItem(title: entry.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.code
            item.state = Config.whisperLanguage == entry.code ? .on : .off
            moreMenu.addItem(item)
        }
        let moreRoot = NSMenuItem(title: "More Languages", action: nil, keyEquivalent: "")
        languageMenu.addItem(moreRoot)
        languageMenu.setSubmenu(moreMenu, for: moreRoot)
        let languageRoot = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.addItem(languageRoot)
        menu.setSubmenu(languageMenu, for: languageRoot)

        let handsFree = NSMenuItem(
            title: "Tap for Hands-Free (VAD auto-stop)",
            action: #selector(toggleHandsFree),
            keyEquivalent: ""
        )
        handsFree.target = self
        handsFree.state = Config.handsFreeEnabled ? .on : .off
        menu.addItem(handsFree)

        let showHUD = NSMenuItem(
            title: "Show Flow-Bar",
            action: #selector(toggleShowHUD),
            keyEquivalent: ""
        )
        showHUD.target = self
        showHUD.state = Config.showIdleHUD ? .on : .off
        menu.addItem(showHUD)

        let startSound = NSMenuItem(
            title: "Start Sound",
            action: #selector(toggleStartSound),
            keyEquivalent: ""
        )
        startSound.target = self
        startSound.state = Config.playStartSound ? .on : .off
        menu.addItem(startSound)

        let quietMode = NSMenuItem(
            title: "Quiet Mode (boost quiet/whispered speech)",
            action: #selector(toggleQuietMode),
            keyEquivalent: ""
        )
        quietMode.target = self
        quietMode.state = Config.quietModeEnabled ? .on : .off
        menu.addItem(quietMode)

        let loginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let logsItem = NSMenuItem(
            title: "Open Logs Folder",
            action: #selector(openLogs),
            keyEquivalent: ""
        )
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func pasteLastTranscript() {
        injector.pasteLastTranscript()
    }

    @objc private func pasteRawTranscript() {
        guard let raw = lastRawTranscript else { return }
        injector.inject(raw)
    }

    @objc private func toggleCleanup() {
        Config.cleanupEnabled.toggle()
        Log.info("AI cleanup \(Config.cleanupEnabled ? "enabled" : "disabled")")
        OllamaCleaner.warmUp()
        rebuildMenu()
    }

    @objc private func editGlossary() {
        Glossary.ensureFileExists()
        NSWorkspace.shared.open(Glossary.fileURL)
    }

    @objc private func editSnippets() {
        SnippetsEngine.openInEditor()
    }

    @objc private func editAppCategories() {
        AppContext.openInEditor()
    }

    @objc private func reviewLearnedWords() {
        NSWorkspace.shared.open(CorrectionWatcher.suggestionsFile)
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = HotkeyChoice(rawValue: raw) else { return }
        Config.hotkey = choice
        Log.info("Hotkey changed to \(choice.rawValue)")
        rebuildMenu()
    }

    @objc private func toggleHandsFree() {
        Config.handsFreeEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleShowHUD() {
        Config.showIdleHUD.toggle()
        if Config.showIdleHUD {
            Config.hudHiddenUntil = Date(timeIntervalSince1970: 0)
        }
        refreshIdleHUD()
        rebuildMenu()
    }

    @objc private func toggleStartSound() {
        Config.playStartSound.toggle()
        rebuildMenu()
    }

    @objc private func toggleQuietMode() {
        Config.quietModeEnabled.toggle()
        rebuildMenu()
    }

    @objc private func showVoiceProfile() {
        VoiceProfileStore.present()
    }

    @objc private func showHistory() {
        HistoryView.present()
    }

    @objc private func showScratchpad() {
        scratchpad.show()
    }

    /// Rewrites the current selection in the focused app (grammar/clarity)
    /// without a spoken instruction — command mode with a fixed prompt.
    /// Holds the pipeline while an improve rewrite is running so a hotkey
    /// press can't interleave a second injection mid-improve.
    private var improveInFlight = false

    @objc private func improveSelectedText() {
        guard state == .idle, !improveInFlight else {
            Log.info("Improve: busy, ignoring")
            return
        }
        improveInFlight = true
        injector.captureSelection { [weak self] selection in
            guard let self else { return }
            guard let selection, !selection.isEmpty else {
                Log.info("Improve: no selection captured")
                self.improveInFlight = false
                return
            }
            OllamaCleaner.applyCommand(
                instruction: OllamaCleaner.improveInstruction,
                to: selection
            ) { [weak self] result in
                defer { self?.improveInFlight = false }
                switch result {
                case .success(let improved) where !improved.isEmpty:
                    self?.injector.inject(improved)
                case .success:
                    Log.error("Improve: empty result, leaving selection untouched")
                case .failure(let error):
                    Log.error("Improve failed (is Ollama running?): \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Config.whisperLanguage = code
        Log.info("Language set to \(code)")
        if code == "en", !ParakeetTranscriber.shared.isReady {
            ParakeetTranscriber.shared.prepare { [weak self] ready in
                Log.info("Parakeet engine ready: \(ready)")
                self?.rebuildMenu()
            }
        }
        rebuildMenu()
    }

    @objc private func toggleLoginItem() {
        setLoginItem(SMAppService.mainApp.status != .enabled)
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("Login item toggle failed: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func showSettings() {
        settings.show()
    }

    private func maybeShowOnboarding() {
        guard !Config.hasCompletedOnboarding else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.onboarding.show()
        }
    }

    @objc private func showOnboarding() {
        onboarding.show()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(Log.dir)
    }
}
