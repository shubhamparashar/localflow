import AppKit
import ApplicationServices
import ServiceManagement

/// Pure decision for what a finished take does with its transcript. Command
/// mode and the claude-pipe route both skip cleanup/injection, applying the
/// transcript elsewhere instead; a plain take runs the normal cleanup+inject
/// pipeline. Extracted so the precedence (`command` wins if both flags were
/// somehow set) is unit-testable without touching AppKit/AppDelegate state.
enum DictationRoute: Equatable {
    case command
    case claudePipe
    case capture
    case normal

    static func decide(isCommand: Bool, isClaudePipe: Bool, isCapture: Bool = false) -> DictationRoute {
        if isCommand { return .command }
        if isClaudePipe { return .claudePipe }
        if isCapture { return .capture }
        return .normal
    }

    /// Whether a finished capture chunk should chain into the next take:
    /// only while capture mode is still on and the finished take was itself
    /// a capture take (a hotkey dictation mid-capture must not fork a loop).
    static func shouldRestartCapture(captureActive: Bool, wasCapture: Bool) -> Bool {
        captureActive && wasCapture
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let partialCaptionRunner = PartialCaptionRunner()
    private let injector = TextInjector()
    private let server = WhisperServerManager()
    private let hud = OverlayHUD()
    private lazy var scratchpad = ScratchpadController()
    private lazy var speakersPanel = SpeakersPanel()
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

    private var whisperKeepAliveTimer: Timer?

    private var pressStartedAt: Date?
    private var dictationStartedAt: Date?
    private var handsFreeArmed = false
    private var sessionIsCommand = false
    private var sessionIsClaudePipe = false
    private var sessionIsCapture = false
    private var captureModeActive = false
    private var captureChunkCount = 0
    private var captureEmptyStreak = 0
    private lazy var meetingSession = MeetingSession(scratchpad: scratchpad)
    private var meetingModeActive = false
    private var captureChunkStartedAt = Date()
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
        maybeShowDashboardOnLaunch()
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
                if ready { ParakeetTranscriber.shared.preWarm() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            ParakeetTranscriber.shared.preWarm()
        }
        startWhisperKeepAliveTimer()

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
        hud.onSelectLanguage = { [weak self] code in self?.selectLanguageFromPill(code) }
        hud.moreLanguagesMenuProvider = { [weak self] in self?.buildMoreLanguagesMenu() ?? NSMenu() }
        hud.onDictateToClaude = { [weak self] in self?.startClaudePipeDictation() }
        hud.onToggleCapture = { [weak self] in self?.toggleCaptureMode() }
        hud.captureModeIsActive = { [weak self] in self?.captureModeActive ?? false }
        hud.onToggleMeeting = { [weak self] in self?.toggleMeetingMode() }
        hud.meetingModeIsActive = { [weak self] in self?.meetingModeActive ?? false }
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
        DashboardController.shared.settings.onChanged = settings.onChanged
        DashboardController.shared.settings.onCleanupEnabled = settings.onCleanupEnabled
        DashboardController.shared.settings.onLanguageChanged = settings.onLanguageChanged
        DashboardController.shared.settings.onLoginItemChanged = settings.onLoginItemChanged
        DashboardController.shared.onOpenScratchpad = { [weak self] in self?.scratchpad.show() }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onCommandPress = { [weak self] in self?.commandPressed() }
        hotkey.onCommandRelease = { [weak self] in self?.commandReleased() }
        hotkey.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    /// Pings whisper-server's health endpoint every 5 minutes so it stays
    /// resident (avoiding a cold model reload) whenever it's the active
    /// engine — i.e. whenever Parakeet isn't handling the configured language.
    private func startWhisperKeepAliveTimer() {
        whisperKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            let decision = TranscriptionRouter.route(
                language: Config.whisperLanguage,
                parakeetReady: ParakeetTranscriber.shared.isReady
            )
            guard decision.engine == .whisper else { return }
            self?.server.checkHealth { _ in }
        }
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
        if meetingModeActive {
            // The hotkey is the panic button while capturing — end the loop.
            stopMeetingMode()
            return
        }
        if captureModeActive {
            // The hotkey is the panic button while capturing — end the loop.
            setCaptureMode(false)
            return
        }
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
        applyPerAppLanguageMemory()
        sessionFieldContext = FieldContext.capture()
        partialCaptionRunner.cancel()
        OllamaCleaner.warmUp()
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

    /// When per-app language memory is on: switches to the frontmost app's
    /// remembered language (if different), then records whichever language
    /// ends up active back against that app for next time.
    private func applyPerAppLanguageMemory() {
        guard Config.perAppLanguageEnabled, let bundleId = AppContext.frontmostBundleId() else { return }
        if let remembered = Config.perAppLanguage(enabled: true, map: Config.perAppLanguageMap, bundleId: bundleId),
           remembered != Config.whisperLanguage {
            applyLanguageSelection(remembered)
        }
        var map = Config.perAppLanguageMap
        map[bundleId] = Config.whisperLanguage
        Config.perAppLanguageMap = map
    }

    private var stopScheduled = false

    private func endDictation() {
        guard state == .recording, !stopScheduled else { return }
        dictationStartedAt = Date()
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
        let isClaudePipe = sessionIsClaudePipe
        let isCapture = sessionIsCapture
        let mode = isCommand ? "command"
            : (isClaudePipe ? "claudePipe"
                : (isCapture ? "capture" : (handsFreeArmed ? "handsFree" : "hold")))
        handsFreeArmed = false
        sessionIsCommand = false
        sessionIsClaudePipe = false
        sessionIsCapture = false
        guard let wav else {
            state = .idle
            maybeRestartCapture(wasCapture: isCapture, producedText: false)
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
                self.transcribeAndRoute(wav, isCommand: true, isClaudePipe: false, isCapture: false, mode: mode)
            }
        } else {
            transcribeAndRoute(wav, isCommand: false, isClaudePipe: isClaudePipe, isCapture: isCapture, mode: mode)
        }
    }

    private func transcribeAndRoute(
        _ wav: Data,
        isCommand: Bool,
        isClaudePipe: Bool,
        isCapture: Bool = false,
        mode: String
    ) {
        let sttStarted = Date()
        let profile = sessionProfile
        let fieldContext = sessionFieldContext
        // Capture chunks route with their own language setting — a meeting's
        // language rarely matches the configured dictation language.
        let languageOverride: String? = isCapture
            ? Config.effectiveCaptureLanguage(dictationLanguage: Config.whisperLanguage)
            : nil
        TranscriptionRouter.transcribe(wav: wav, fieldContext: fieldContext, languageOverride: languageOverride) { [weak self] result in
            guard let self else { return }
            let sttSeconds = Date().timeIntervalSince(sttStarted)
            self.state = .idle
            switch result {
            case .success(let text):
                guard !text.isEmpty else {
                    Log.info("Empty transcript, nothing to inject")
                    self.maybeRestartCapture(wasCapture: isCapture, producedText: false)
                    return
                }
                switch DictationRoute.decide(isCommand: isCommand, isClaudePipe: isClaudePipe, isCapture: isCapture) {
                case .command:
                    self.runCommand(instruction: text)
                case .claudePipe:
                    self.runClaudePipe(transcript: text)
                case .capture:
                    self.captureChunkCount += 1
                    Log.info("Capture mode: chunk \(self.captureChunkCount) (\(text.count) chars)")
                    self.appendCaptureChunk(text: text, wav: wav)
                    self.maybeRestartCapture(wasCapture: true, producedText: true)
                case .normal:
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
                        // Snippet slots read the clipboard before inject()
                        // overwrites it with the transcript itself.
                        var cursorOffsetFromEnd: Int?
                        if final.contains("{") {
                            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
                            let filled = SnippetsEngine.fillSlots(expansion: final, clipboard: clipboard, date: Date())
                            final = filled.text
                            cursorOffsetFromEnd = filled.cursorOffsetFromEnd
                        }
                        if self.redactionBlocks(final, profile: profile) {
                            return
                        }
                        self.injector.inject(final)
                        if let offset = cursorOffsetFromEnd, offset > 0 {
                            let smartSpacePad = Config.smartSpacing && !final.hasSuffix(" ") ? 1 : 0
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.injector.moveCaretLeft(offset + smartSpacePad)
                            }
                        }
                        CorrectionWatcher.shared.recordInjection(final)
                        let cleanupSeconds: Double? = willClean ? Date().timeIntervalSince(cleanupStarted) : nil
                        let totalLatencySec: Double? = self.dictationStartedAt.map { Date().timeIntervalSince($0) }
                        if let totalLatencySec {
                            Log.info(
                                "Take latency: \(String(format: "%.2f", totalLatencySec))s " +
                                    "(stt \(String(format: "%.2f", sttSeconds))s, " +
                                    "cleanup \(String(format: "%.2f", cleanupSeconds ?? 0))s)"
                            )
                        }
                        let record = DictationRecord(
                            ts: Date(),
                            durationSec: self.recorder.lastDurationSec,
                            rawWords: Self.wordCount(text),
                            finalWords: Self.wordCount(final),
                            mode: mode,
                            sttSeconds: sttSeconds,
                            cleanupSeconds: cleanupSeconds,
                            rawText: text,
                            finalText: final,
                            app: profile?.category,
                            totalLatencySec: totalLatencySec
                        )
                        VoiceProfileStore.record(record)
                    }
                }
            case .failure(let error):
                Log.error("Transcription failed, take dropped: \(error.localizedDescription)")
                self.hud.show(.warning("Transcription failed — take lost"))
                self.maybeRestartCapture(wasCapture: isCapture, producedText: false)
            }
        }
    }

    /// Appends one capture chunk's transcript to the Scratchpad, prefixed
    /// with "**Speaker N:**" when speaker labeling is on and the diarizer is
    /// ready. Chunk-level labeling only — the whole chunk gets one label
    /// (its dominant speaker by spoken duration), not per-word attribution.
    private func appendCaptureChunk(text: String, wav: Data) {
        if meetingModeActive {
            // The mic is always the user — no diarization needed for this side.
            meetingSession.appendMicChunk(text: text, chunkStartedAt: captureChunkStartedAt)
            return
        }
        guard Config.speakerLabelsEnabled, SpeakerDiarizer.shared.isReady else {
            scratchpad.append(text + "\n\n")
            return
        }
        let samples = ParakeetTranscriber.floatSamples(fromWav: wav)
        SpeakerDiarizer.shared.diarize(samples: samples) { [weak self] segments in
            guard let self else { return }
            guard let speakerId = SpeakerDiarizer.dominantSpeaker(segments) else {
                self.scratchpad.append(text + "\n\n")
                return
            }
            let name = SpeakerDiarizer.shared.name(for: speakerId)
            self.scratchpad.append("**\(name):** " + text + "\n\n")
        }
    }

    // MARK: - Capture mode (long-form notes into the Scratchpad)

    /// Chains the next capture take while capture mode stays on. Three
    /// consecutive fruitless takes (dead mic, silence) end the loop rather
    /// than recording forever.
    private func maybeRestartCapture(wasCapture: Bool, producedText: Bool) {
        guard DictationRoute.shouldRestartCapture(captureActive: captureModeActive, wasCapture: wasCapture) else { return }
        if producedText {
            captureEmptyStreak = 0
        } else {
            captureEmptyStreak += 1
            if captureEmptyStreak >= 3 {
                Log.info("Capture mode: 3 empty takes in a row, stopping")
                setCaptureMode(false)
                return
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.startCaptureTake()
        }
    }

    private func startCaptureTake() {
        guard captureModeActive, state == .idle || state == .transcribing else { return }
        captureChunkStartedAt = Date()
        handsFreeArmed = false
        sessionIsCommand = false
        sessionIsClaudePipe = false
        sessionIsCapture = true
        beginDictation()
        if state == .recording {
            handsFreeArmed = true
            recorder.enableAutoStop()
        } else {
            sessionIsCapture = false
        }
    }

    private func setCaptureMode(_ on: Bool) {
        guard !meetingModeActive else { return }
        guard captureModeActive != on else { return }
        captureModeActive = on
        if on {
            captureChunkCount = 0
            captureEmptyStreak = 0
            let time = Date().formatted(date: .omitted, time: .shortened)
            scratchpad.append("— \(time) —\n")
            scratchpad.show()
            Log.info("Capture mode: started")
            if Config.speakerLabelsEnabled && SpeakerDiarizer.shared.isReady {
                SpeakerDiarizer.shared.startSession()
            }
            startCaptureTake()
        } else {
            Log.info("Capture mode: stopped after \(captureChunkCount) chunks")
            if Config.speakerLabelsEnabled && SpeakerDiarizer.shared.isReady {
                SpeakerDiarizer.shared.persistSession()
            }
            if state == .recording, sessionIsCapture || handsFreeArmed {
                endDictation()
            }
        }
        rebuildMenu()
    }

    // MARK: - Meeting Mode (mic + system audio notes into the Scratchpad)

    /// Meeting Mode reuses the Capture Mode mic loop verbatim (chunk timing,
    /// hands-free VAD, the 3-empty-takes stop) and layers a
    /// `MeetingSession` on top for the system-audio half and the
    /// meeting-specific Scratchpad framing.
    private func startMeetingMode() {
        guard !meetingModeActive, !captureModeActive else { return }
        meetingModeActive = true
        captureModeActive = true
        captureChunkCount = 0
        captureEmptyStreak = 0
        Log.info("Meeting mode: started")
        meetingSession.start()
        startCaptureTake()
        rebuildMenu()
    }

    private func stopMeetingMode() {
        guard meetingModeActive else { return }
        meetingModeActive = false
        captureModeActive = false
        Log.info("Meeting mode: stopped after \(captureChunkCount) mic chunks")
        if state == .recording, sessionIsCapture || handsFreeArmed {
            endDictation()
        }
        meetingSession.stop()
        rebuildMenu()
    }

    @objc private func toggleMeetingMode() {
        if meetingModeActive {
            stopMeetingMode()
        } else {
            startMeetingMode()
        }
    }

    @objc private func selectCaptureLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Config.captureLanguage = code
        Log.info("Capture language set to \(code)")
        rebuildMenu()
    }

    @objc private func toggleCaptureMode() {
        setCaptureMode(!captureModeActive)
    }

    /// Redaction guard: if the final dictation looks like it contains a
    /// credential and the frontmost app isn't a code editor/terminal, skip
    /// injection, leave the text on the clipboard, and warn via the HUD.
    /// Returns true when injection was blocked.
    private func redactionBlocks(_ text: String, profile: AppCategoryProfile?) -> Bool {
        guard Config.redactionGuardEnabled, profile?.category != "code" else { return false }
        let secrets = RedactionGuard.findSecrets(in: text)
        guard !secrets.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        hud.show(.warning("⚠︎ Looks like a secret — Cmd+V to paste anyway"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.refreshIdleHUD()
        }
        let kinds = Set(secrets.map(\.kind)).sorted().joined(separator: ", ")
        Log.info("Redaction guard: blocked injection (kinds: \(kinds)) — text left on clipboard")
        return true
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

    /// Runs the raw transcript through `Config.claudePipeCommand` and appends
    /// the exchange to the Scratchpad. Skips cleanup/injection entirely — the
    /// transcript is the prompt, not text meant for the focused app.
    private func runClaudePipe(transcript: String) {
        guard Config.claudePipeEnabled else { return }
        Log.info("Claude pipe: dispatching transcript (\(transcript.count) chars)")
        hud.show(.cleaning)
        ClaudePipe.run(command: Config.claudePipeCommand, transcript: transcript) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.state != .recording { self.refreshIdleHUD() }
                switch result {
                case .success(let output):
                    Log.info("Claude pipe: response received (\(output.count) chars)")
                    self.scratchpad.append("You: \(transcript)\n\nClaude: \(output)\n\n")
                case .failure(let error):
                    Log.error("Claude pipe failed: \(error.message)")
                    self.scratchpad.append("You: \(transcript)\n\nClaude error: \(error.message)\n\n")
                }
                self.scratchpad.show()
            }
        }
    }

    /// Arms the next take as a claude-pipe take and starts it hands-free
    /// (mirrors `startHandsFreeDictation`), triggered from the pill's
    /// right-click menu or the status-bar menu.
    private func startClaudePipeDictation() {
        guard Config.claudePipeEnabled else { return }
        guard state == .idle || state == .transcribing else { return }
        handsFreeArmed = false
        sessionIsCommand = false
        sessionIsClaudePipe = true
        beginDictation()
        if state == .recording {
            handsFreeArmed = true
            recorder.enableAutoStop()
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
        case "snap":
            snapWindows()
        case "paste-raw":
            if let raw = lastRawTranscript { injector.inject(raw) }
        default:
            Log.error("Unknown URL command: \(command)")
        }
    }

    /// Debug aid: renders every app window (dashboard, pill, settings…) to
    /// PNGs in /tmp/localflow-snaps — screen-capture tools can't see an
    /// LSUIElement app's windows, but the app can draw its own.
    private func snapWindows() {
        let dir = URL(fileURLWithPath: "/tmp/localflow-snaps")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            // Capture real on-screen pixels — offscreen cacheDisplay drops
            // vibrant text inside visual-effect hierarchies.
            let windowID = CGWindowID(window.windowNumber)
            guard let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            ) else { continue }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let name = (window.title.isEmpty ? "window\(index)" : window.title.replacingOccurrences(of: " ", with: "-")).lowercased()
            try? data.write(to: dir.appendingPathComponent("\(name)-\(index).png"))
        }
        Log.info("Snapped \(NSApp.windows.filter(\.isVisible).count) windows to /tmp/localflow-snaps")
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

        let dashboardItem = NSMenuItem(
            title: "Open LocalFlow…",
            action: #selector(showDashboard),
            keyEquivalent: ""
        )
        dashboardItem.target = self
        menu.addItem(dashboardItem)
        menu.addItem(.separator())

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

        if Config.claudePipeEnabled {
            let dictateToClaude = NSMenuItem(
                title: "Dictate to Claude",
                action: #selector(startClaudePipeDictationFromMenu),
                keyEquivalent: ""
            )
            dictateToClaude.target = self
            menu.addItem(dictateToClaude)
        }
        let captureItem = NSMenuItem(
            title: "Capture Mode (notes into Scratchpad)",
            action: #selector(toggleCaptureMode),
            keyEquivalent: ""
        )
        captureItem.target = self
        captureItem.state = captureModeActive ? .on : .off
        menu.addItem(captureItem)

        let meetingItem = NSMenuItem(
            title: "Meeting Notes (mic + system audio)",
            action: #selector(toggleMeetingMode),
            keyEquivalent: ""
        )
        meetingItem.target = self
        meetingItem.state = meetingModeActive ? .on : .off
        menu.addItem(meetingItem)

        let captureLangRoot = NSMenuItem(title: "Capture Language", action: nil, keyEquivalent: "")
        let captureLangMenu = NSMenu()
        let captureChoices: [(String, String)] = [
            ("auto", "Auto-detect"),
            ("same", "Same as Dictation"),
            ("hinglish", "Hinglish"),
        ]
        for (code, title) in captureChoices {
            let item = NSMenuItem(title: title, action: #selector(selectCaptureLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = Config.captureLanguage == code ? .on : .off
            captureLangMenu.addItem(item)
        }
        menu.addItem(captureLangRoot)
        menu.setSubmenu(captureLangMenu, for: captureLangRoot)

        let claudePipeToggle = NSMenuItem(
            title: "Enable Claude Pipe",
            action: #selector(toggleClaudePipe),
            keyEquivalent: ""
        )
        claudePipeToggle.target = self
        claudePipeToggle.state = Config.claudePipeEnabled ? .on : .off
        menu.addItem(claudePipeToggle)

        let speakerLabels = NSMenuItem(
            title: "Label Speakers (capture)",
            action: #selector(toggleSpeakerLabels),
            keyEquivalent: ""
        )
        speakerLabels.target = self
        speakerLabels.state = Config.speakerLabelsEnabled ? .on : .off
        menu.addItem(speakerLabels)

        if Config.speakerLabelsEnabled {
            let speakersItem = NSMenuItem(
                title: "Speakers…",
                action: #selector(showSpeakersPanel),
                keyEquivalent: ""
            )
            speakersItem.target = self
            menu.addItem(speakersItem)
        }
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
        let moreRoot = NSMenuItem(title: "More Languages", action: nil, keyEquivalent: "")
        languageMenu.addItem(moreRoot)
        languageMenu.setSubmenu(buildMoreLanguagesMenu(), for: moreRoot)
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

        let perAppLanguage = NSMenuItem(
            title: "Remember Language per App",
            action: #selector(togglePerAppLanguage),
            keyEquivalent: ""
        )
        perAppLanguage.target = self
        perAppLanguage.state = Config.perAppLanguageEnabled ? .on : .off
        menu.addItem(perAppLanguage)

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

        let redactionGuard = NSMenuItem(
            title: "Redaction Guard",
            action: #selector(toggleRedactionGuard),
            keyEquivalent: ""
        )
        redactionGuard.target = self
        redactionGuard.state = Config.redactionGuardEnabled ? .on : .off
        menu.addItem(redactionGuard)

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

    @objc private func toggleSpeakerLabels() {
        Config.speakerLabelsEnabled.toggle()
        Log.info("Speaker labels \(Config.speakerLabelsEnabled ? "enabled" : "disabled")")
        if Config.speakerLabelsEnabled {
            SpeakerDiarizer.shared.prepare { ready in
                Log.info("Diarizer engine ready: \(ready)")
            }
        }
        rebuildMenu()
    }

    @objc private func showSpeakersPanel() {
        speakersPanel.show()
    }

    @objc private func toggleRedactionGuard() {
        Config.redactionGuardEnabled.toggle()
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

    @objc private func toggleClaudePipe() {
        Config.claudePipeEnabled.toggle()
        Log.info("Claude pipe \(Config.claudePipeEnabled ? "enabled" : "disabled")")
        rebuildMenu()
    }

    @objc private func startClaudePipeDictationFromMenu() {
        startClaudePipeDictation()
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
        applyLanguageSelection(code)
        Log.info("Language set to \(code)")
    }

    /// The Flow-Bar pill's Language submenu and badge-cycling route here
    /// instead of duplicating the status-bar menu's selection logic.
    private func selectLanguageFromPill(_ code: String) {
        applyLanguageSelection(code)
        Log.info("Language switched to \(code) (via pill)")
    }

    private func applyLanguageSelection(_ code: String) {
        Config.setLanguage(code)
        if code == "en", !ParakeetTranscriber.shared.isReady {
            ParakeetTranscriber.shared.prepare { [weak self] ready in
                Log.info("Parakeet engine ready: \(ready)")
                self?.rebuildMenu()
            }
        }
        rebuildMenu()
        refreshIdleHUD()
    }

    @objc private func togglePerAppLanguage() {
        Config.perAppLanguageEnabled.toggle()
        rebuildMenu()
    }

    /// "More Languages" submenu shared by the status-bar menu and the
    /// Flow-Bar pill's context menu.
    private func buildMoreLanguagesMenu() -> NSMenu {
        let moreMenu = NSMenu()
        for entry in Config.whisperLanguages where entry.code != "en" && entry.code != "hi" {
            let item = NSMenuItem(title: entry.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.code
            item.state = Config.whisperLanguage == entry.code ? .on : .off
            moreMenu.addItem(item)
        }
        return moreMenu
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

    private func maybeShowDashboardOnLaunch() {
        guard Config.openDashboardOnLaunch else { return }
        DashboardController.shared.show()
    }

    @objc private func showDashboard() {
        DashboardController.shared.show()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(Log.dir)
    }
}
