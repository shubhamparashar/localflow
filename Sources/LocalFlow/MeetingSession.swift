import Foundation

/// Pure formatting/decision helpers for Meeting Mode, kept separate from the
/// orchestration below so they're unit-testable without a running session.
enum MeetingFormatting {
    /// "[12:14] **Me:** hello" — the wall clock is captured at chunk start so
    /// read-order stays sensible even though the two streams (mic, system
    /// audio) finish transcribing out of order.
    static func prefixedLine(at date: Date, speaker: String, text: String) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return "[\(time)] **\(speaker):** \(text)"
    }

    /// Which label a chunk gets: the mic is always the user; a system-audio
    /// chunk gets the diarized dominant speaker's name when labeling is on
    /// and the diarizer is ready, otherwise the generic "Them".
    /// Transcripts occasionally arrive already carrying a bold label (echo
    /// of our own formatting picked up from screen-shared notes, or model
    /// artifacts) — strip any leading "**X:**" tokens so lines never render
    /// with doubled labels.
    static func strippingLeadingLabels(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        while let range = result.range(of: #"^\*\*[^*]{1,20}:\*\*\s*"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result
    }

    static func speakerLabel(
        isMic: Bool,
        speakerLabelsEnabled: Bool,
        diarizerReady: Bool,
        dominantSpeakerName: String?
    ) -> String {
        if isMic { return "Me" }
        guard speakerLabelsEnabled, diarizerReady, let dominantSpeakerName else { return "Them" }
        return dominantSpeakerName
    }
}

/// Orchestrates one Meeting Mode session: the existing mic capture-mode loop
/// (chunks always labeled "Me") plus a `SystemAudioRecorder` loop for the
/// other side of the call, both landing in the Scratchpad with a wall-clock
/// prefix. Kept out of `AppDelegate` so meeting-specific state doesn't bloat
/// the god object further.
final class MeetingSession {
    private let scratchpad: ScratchpadController
    private let systemAudio = SystemAudioRecorder()
    private var startedAt: Date = .distantPast
    private(set) var isActive = false
    /// Set false at finish() so transcriptions still in flight when the
    /// meeting ends are dropped instead of appearing after the closing line.
    private var acceptingAppends = false

    init(scratchpad: ScratchpadController) {
        self.scratchpad = scratchpad
    }

    /// Appends the session header, starts the system-audio loop, and starts
    /// the diarizer session once (not per chunk). The mic side is driven by
    /// AppDelegate's existing capture-mode loop — this call only arms the
    /// system-audio half and the Scratchpad framing.
    func start() {
        guard !isActive else { return }
        isActive = true
        acceptingAppends = true
        startedAt = Date()
        let time = startedAt.formatted(date: .omitted, time: .shortened)
        scratchpad.append("— Meeting \(time) —\n")
        scratchpad.show()
        if Config.speakerLabelsEnabled, SpeakerDiarizer.shared.isReady {
            SpeakerDiarizer.shared.startSession()
        }
        Config.meetingModeActive = true
        systemAudio.onChunk = { [weak self] samples in
            self?.handleSystemChunk(samples, chunkStartedAt: Date())
        }
        systemAudio.start { ok in
            if !ok {
                Log.error("Meeting mode: system audio unavailable, continuing with mic-only notes")
            }
        }
    }

    /// Stops the system-audio loop (flushing any in-flight chunk first),
    /// persists the diarizer session once, and appends the closing line.
    func stop() {
        guard isActive else { return }
        isActive = false
        systemAudio.stop { [weak self] flushed in
            guard let self else { return }
            if let flushed {
                self.handleSystemChunk(flushed, chunkStartedAt: Date())
            }
            self.finish()
        }
    }

    private func finish() {
        acceptingAppends = false
        Config.meetingModeActive = false
        if Config.speakerLabelsEnabled, SpeakerDiarizer.shared.isReady {
            SpeakerDiarizer.shared.persistSession()
        }
        let minutes = max(1, Int(Date().timeIntervalSince(startedAt) / 60))
        scratchpad.append("— Meeting ended, \(minutes) min —\n\n")
    }

    /// One mic chunk finished transcribing — append it labeled "Me", using
    /// the wall clock captured at chunk start (passed in by the caller).
    func appendMicChunk(text: String, chunkStartedAt: Date) {
        guard !text.isEmpty, acceptingAppends else { return }
        let cleaned = MeetingFormatting.strippingLeadingLabels(text)
        let line = MeetingFormatting.prefixedLine(at: chunkStartedAt, speaker: "Me", text: cleaned)
        scratchpad.append(line + "\n\n")
    }

    private func handleSystemChunk(_ samples: [Float], chunkStartedAt: Date) {
        guard !samples.isEmpty else { return }
        let wav = AudioRecorder.wavData(samples: samples, sampleRate: 16000)
        let language = Config.effectiveCaptureLanguage(dictationLanguage: Config.whisperLanguage)
        TranscriptionRouter.transcribe(wav: wav, fieldContext: nil, languageOverride: language) { [weak self] result in
            guard let self, case .success(let text) = result, !text.isEmpty else {
                if case .failure(let error) = result {
                    Log.error("Meeting mode: system-audio transcription failed (\(error.localizedDescription))")
                }
                return
            }
            if Transcriber.looksLikeHallucination(text) {
                Log.info("Meeting mode: dropped hallucinated system chunk (\(text.count) chars)")
                return
            }
            self.labelAndAppend(text: text, samples: samples, chunkStartedAt: chunkStartedAt)
        }
    }

    private func labelAndAppend(text: String, samples: [Float], chunkStartedAt: Date) {
        guard Config.speakerLabelsEnabled, SpeakerDiarizer.shared.isReady else {
            append(text: text, speaker: "Them", chunkStartedAt: chunkStartedAt)
            return
        }
        SpeakerDiarizer.shared.diarize(samples: samples) { [weak self] segments in
            guard let self else { return }
            let speakerId = SpeakerDiarizer.dominantSpeaker(segments)
            let name = speakerId.map { SpeakerDiarizer.shared.name(for: $0) }
            let label = MeetingFormatting.speakerLabel(
                isMic: false,
                speakerLabelsEnabled: true,
                diarizerReady: true,
                dominantSpeakerName: name
            )
            self.append(text: text, speaker: label, chunkStartedAt: chunkStartedAt)
        }
    }

    private func append(text: String, speaker: String, chunkStartedAt: Date) {
        guard acceptingAppends else {
            Log.info("Meeting mode: dropped late chunk (\(text.count) chars, meeting already ended)")
            return
        }
        let cleaned = MeetingFormatting.strippingLeadingLabels(text)
        let line = MeetingFormatting.prefixedLine(at: chunkStartedAt, speaker: speaker, text: cleaned)
        scratchpad.append(line + "\n\n")
    }
}
