import Foundation

enum Config {
    static var speakerLabelsEnabled = false
    static var meetingModeActive = false
    static var whisperLanguage = "en"
    static func effectiveCaptureLanguage(dictationLanguage: String) -> String { dictationLanguage }
}
enum Log { static func error(_ value: String) {} }
final class MeetingNotebookController {
    var begun: [UUID] = []
    var ended: [UUID] = []
    var finishing: [UUID] = []
    var lines: [String] = []
    var reports: [String] = []
    func beginMeeting() -> UUID { let id = UUID(); begun.append(id); return id }
    func append(text: String, speaker: String, at: Date, to: UUID) { lines.append(speaker + ": " + text) }
    func finishingMeeting(_ id: UUID) { finishing.append(id) }
    func endMeeting(_ id: UUID) { ended.append(id) }
    func report(message: String, for id: UUID) { reports.append(message) }
}
final class SystemAudioRecorder {
    static var last: SystemAudioRecorder!
    var onChunk: (([Float]) -> Void)?
    var stopCompletion: (([Float]?) -> Void)?
    init() { Self.last = self }
    func start(completion: @escaping (Bool) -> Void) { completion(true) }
    func stop(completion: @escaping ([Float]?) -> Void) { stopCompletion = completion }
    func finishStop(_ samples: [Float]?) { stopCompletion?(samples); stopCompletion = nil }
}
enum AudioRecorder {
    static func wavData(samples: [Float], sampleRate: Int) -> Data { Data() }
}
enum TranscriptionRouter {
    static var pending: [(Result<String, Error>) -> Void] = []
    static func transcribe(wav: Data, fieldContext: String?, languageOverride: String?, completion: @escaping (Result<String, Error>) -> Void) { pending.append(completion) }
    static func finish(_ result: Result<String, Error>) { pending.removeFirst()(result) }
}
enum Transcriber { static func looksLikeHallucination(_ text: String) -> Bool { text == "hallucination" } }
final class SpeakerDiarizer {
    static let shared = SpeakerDiarizer()
    var isReady = false
    var pending: (([Int]) -> Void)?
    var persistCount = 0
    func startSession() {}
    func persistSession() { persistCount += 1 }
    func diarize(samples: [Float], completion: @escaping ([Int]) -> Void) { pending = completion }
    static func dominantSpeaker(_ segments: [Int]) -> Int? { segments.first }
    func name(for id: Int) -> String { "Speaker \(id)" }
}

@main enum LifecycleSmoke {
    static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
    static func main() {
        let notebook = MeetingNotebookController()
        let session = MeetingSession(notebook: notebook)
        session.start()
        let micID = session.beginMicChunk()!
        session.stop()
        precondition(notebook.finishing == [micID] && session.isBusy && !session.isActive)
        SystemAudioRecorder.last.finishStop([1, 1])
        precondition(session.isBusy && notebook.ended.isEmpty, "Flushed system chunk must drain")
        session.start()
        precondition(notebook.begun.count == 1, "Restart must wait for previous meeting drain")
        session.completeMicChunk(text: "**Me:** final mic", chunkStartedAt: Date(), meetingID: micID)
        precondition(notebook.ended.isEmpty)
        TranscriptionRouter.finish(.success("final system"))
        pump()
        precondition(notebook.ended == [micID] && !session.isBusy)
        precondition(notebook.lines == ["Me: final mic", "Them: final system"])

        session.start()
        SystemAudioRecorder.last.onChunk?([1, 1])
        pump()
        session.stop()
        SystemAudioRecorder.last.finishStop(nil)
        precondition(session.isBusy)
        TranscriptionRouter.finish(.failure(NSError(domain: "smoke", code: 1)))
        pump()
        precondition(!session.isBusy && notebook.ended.count == 2 && notebook.reports.count == 1)

        Config.speakerLabelsEnabled = true
        SpeakerDiarizer.shared.isReady = true
        session.start()
        SystemAudioRecorder.last.onChunk?([1, 1])
        pump()
        TranscriptionRouter.finish(.success("speaker segment"))
        pump()
        session.stop()
        SystemAudioRecorder.last.finishStop(nil)
        precondition(session.isBusy && SpeakerDiarizer.shared.persistCount == 0)
        SpeakerDiarizer.shared.pending?([3])
        pump()
        precondition(!session.isBusy && SpeakerDiarizer.shared.persistCount == 1)
        precondition(notebook.lines.last == "Speaker 3: speaker segment")

        session.start()
        let silentMic = session.beginMicChunk()!
        session.stop()
        SystemAudioRecorder.last.finishStop(nil)
        precondition(session.isBusy)
        session.completeMicChunk(text: nil, chunkStartedAt: Date(), meetingID: silentMic)
        precondition(!session.isBusy && notebook.ended.count == 4)

        session.start()
        let continuousMic = session.beginMicChunk()!
        session.transcribeMicChunk([1, 1], chunkStartedAt: Date(), meetingID: continuousMic)
        session.transcribeMicChunk([1, 1], chunkStartedAt: Date(), meetingID: continuousMic)
        session.stop()
        SystemAudioRecorder.last.finishStop(nil)
        session.completeMicChunk(text: "tail", chunkStartedAt: Date(), meetingID: continuousMic)
        precondition(session.isBusy, "Stopping must wait for all continuous microphone chunks")
        TranscriptionRouter.finish(.success("first continuous chunk"))
        pump()
        precondition(session.isBusy)
        TranscriptionRouter.finish(.failure(NSError(domain: "smoke", code: 2)))
        pump()
        precondition(!session.isBusy && notebook.ended.count == 5)
        precondition(notebook.lines.contains("Me: first continuous chunk"))
        precondition(notebook.reports.last == "A microphone segment could not be transcribed.")
        print("Meeting lifecycle smoke passed: final mic/system drain, continuous mic drain, failure release, diarization drain, restart guard, silent mic release")
    }
}
