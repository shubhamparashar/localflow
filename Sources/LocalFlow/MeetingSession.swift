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

/// Keeps a meeting open until both audio streams and their transcriptions drain.
final class MeetingSession {
    private let notebook: MeetingNotebookController
    private let systemAudio = SystemAudioRecorder()
    private var meetingID: UUID?
    private var pendingChunks = 0
    private var systemStopped = false
    private(set) var isActive = false
    var isBusy: Bool { meetingID != nil }
    var onFinished: (() -> Void)?

    init(notebook: MeetingNotebookController) {
        self.notebook = notebook
    }

    func start() {
        guard !isBusy else { return }
        let id = notebook.beginMeeting()
        meetingID = id
        isActive = true
        systemStopped = false
        pendingChunks = 0
        if Config.speakerLabelsEnabled, SpeakerDiarizer.shared.isReady {
            SpeakerDiarizer.shared.startSession()
        }
        Config.meetingModeActive = true
        systemAudio.onChunk = { [weak self] samples in
            let startedAt = Date().addingTimeInterval(-Double(samples.count) / 16000)
            DispatchQueue.main.async {
                self?.handleSystemChunk(samples, chunkStartedAt: startedAt, meetingID: id)
            }
        }
        systemAudio.start { [weak self] ok in
            guard let self, self.meetingID == id else { return }
            if !ok {
                self.notebook.report(message: "System audio unavailable. Recording microphone only.", for: id)
                Log.error("Meeting mode: system audio unavailable, continuing with mic-only notes")
            }
        }
    }

    func microphoneUnavailable() {
        guard let id = meetingID else { return }
        notebook.report(message: "Microphone unavailable. Recording system audio only.", for: id)
    }

    /// Reserve the mic chunk before its delayed stop and transcription begin.
    func beginMicChunk() -> UUID? {
        guard isActive, let id = meetingID else { return nil }
        pendingChunks += 1
        return id
    }

    func completeMicChunk(text: String?, chunkStartedAt: Date, meetingID id: UUID) {
        guard meetingID == id else { return }
        if let text, !text.isEmpty {
            append(text: text, speaker: "Me", chunkStartedAt: chunkStartedAt, meetingID: id)
        }
        completeChunk(meetingID: id)
    }

    func stop() {
        guard isActive, let id = meetingID else { return }
        isActive = false
        notebook.finishingMeeting(id)
        systemAudio.stop { [weak self] flushed in
            guard let self, self.meetingID == id else { return }
            if let flushed {
                let startedAt = Date().addingTimeInterval(-Double(flushed.count) / 16000)
                self.handleSystemChunk(flushed, chunkStartedAt: startedAt, meetingID: id)
            }
            self.systemStopped = true
            self.finishIfDrained()
        }
    }

    private func completeChunk(meetingID id: UUID) {
        guard meetingID == id else { return }
        pendingChunks -= 1
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard !isActive, systemStopped, pendingChunks == 0, let id = meetingID else { return }
        Config.meetingModeActive = false
        if Config.speakerLabelsEnabled, SpeakerDiarizer.shared.isReady {
            SpeakerDiarizer.shared.persistSession()
        }
        meetingID = nil
        notebook.endMeeting(id)
        onFinished?()
    }

    private func handleSystemChunk(_ samples: [Float], chunkStartedAt: Date, meetingID id: UUID) {
        guard meetingID == id, !samples.isEmpty else { return }
        pendingChunks += 1
        let wav = AudioRecorder.wavData(samples: samples, sampleRate: 16000)
        let language = Config.effectiveCaptureLanguage(dictationLanguage: Config.whisperLanguage)
        TranscriptionRouter.transcribe(wav: wav, fieldContext: nil, languageOverride: language) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.meetingID == id else { return }
                guard case .success(let text) = result, !text.isEmpty,
                      !Transcriber.looksLikeHallucination(text) else {
                    if case .failure(let error) = result {
                        Log.error("Meeting mode: system-audio transcription failed (\(error.localizedDescription))")
                        self.notebook.report(message: "A system-audio segment could not be transcribed.", for: id)
                    }
                    self.completeChunk(meetingID: id)
                    return
                }
                self.labelAndAppend(text: text, samples: samples, chunkStartedAt: chunkStartedAt, meetingID: id)
            }
        }
    }

    private func labelAndAppend(text: String, samples: [Float], chunkStartedAt: Date, meetingID id: UUID) {
        guard Config.speakerLabelsEnabled, SpeakerDiarizer.shared.isReady else {
            append(text: text, speaker: "Them", chunkStartedAt: chunkStartedAt, meetingID: id)
            completeChunk(meetingID: id)
            return
        }
        SpeakerDiarizer.shared.diarize(samples: samples) { [weak self] segments in
            DispatchQueue.main.async {
                guard let self, self.meetingID == id else { return }
                let speakerId = SpeakerDiarizer.dominantSpeaker(segments)
                let name = speakerId.map { SpeakerDiarizer.shared.name(for: $0) }
                let label = MeetingFormatting.speakerLabel(
                    isMic: false,
                    speakerLabelsEnabled: true,
                    diarizerReady: true,
                    dominantSpeakerName: name
                )
                self.append(text: text, speaker: label, chunkStartedAt: chunkStartedAt, meetingID: id)
                self.completeChunk(meetingID: id)
            }
        }
    }

    private func append(text: String, speaker: String, chunkStartedAt: Date, meetingID id: UUID) {
        guard meetingID == id else { return }
        let cleaned = MeetingFormatting.strippingLeadingLabels(text)
        guard !cleaned.isEmpty else { return }
        notebook.append(text: cleaned, speaker: speaker, at: chunkStartedAt, to: id)
    }
}
