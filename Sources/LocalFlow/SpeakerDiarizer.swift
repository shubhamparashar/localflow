import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// One speaker segment from a diarized chunk, decoupled from FluidAudio's
/// own segment type so the dominant-speaker logic below can be unit tested
/// without a loaded model.
struct SpeakerSegment {
    let speakerId: String
    let start: Double
    let end: Double
    var duration: Double { end - start }
}

/// A named voice-print persisted to disk so a speaker recognized in one
/// capture session keeps their name in the next one.
struct SavedSpeaker: Codable, Equatable {
    let id: String
    var name: String
    var embedding: [Float]
}

/// Reads/writes the persistent voice-print roster (`speakers.json`). Mirrors
/// `Glossary`'s settable `fileURL` so tests can point it at a temp directory.
enum SpeakerStore {
    static var fileURL: URL = Log.dir.appendingPathComponent("speakers.json")

    static func load() -> [SavedSpeaker] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SavedSpeaker].self, from: data)) ?? []
    }

    static func save(_ speakers: [SavedSpeaker]) {
        guard let data = try? JSONEncoder().encode(speakers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// On-device speaker diarization via FluidAudio's `DiarizerManager`, wrapped
/// with the same lazy async model-download/initialize pattern as
/// `ParakeetTranscriber`. Speaker identity is tracked by the underlying
/// `SpeakerManager` for the lifetime of one capture session (`startSession`
/// through `persistSession`); across sessions, identity survives via
/// `speakers.json`.
///
/// Off by default: `prepare` is only called once the user turns on
/// `Config.speakerLabelsEnabled`, so the diarization models are never
/// downloaded for users who don't opt in.
final class SpeakerDiarizer {
    static let shared = SpeakerDiarizer()

    /// True once models are downloaded and loaded. Main-thread access only.
    private(set) var isReady: Bool = false

    private var isPreparing: Bool = false
    private var pendingCompletions: [(Bool) -> Void] = []
    /// The FluidAudio `DiarizerManager`, stored type-erased so this class
    /// compiles on deployment targets older than the engine supports.
    private var manager: AnyObject?

    private init() {}

    /// Kick off async model download+load; safe to call repeatedly. The
    /// completion (and any queued while a load is in flight) is called on
    /// the main queue.
    func prepare(completion: ((Bool) -> Void)?) {
        DispatchQueue.main.async {
            if self.isReady {
                completion?(true)
                return
            }
            if let completion {
                self.pendingCompletions.append(completion)
            }
            if self.isPreparing {
                return
            }
            self.isPreparing = true
            self.loadEngine()
        }
    }

    /// Call once at the start of a capture session: loads persisted named
    /// voice-prints so recurring speakers are recognized by name from their
    /// very first chunk.
    func startSession() {
        #if canImport(FluidAudio)
        if #available(macOS 14.0, *), isReady, let manager = manager as? DiarizerManager {
            let known = SpeakerStore.load().map {
                Speaker(id: $0.id, name: $0.name, currentEmbedding: $0.embedding, isPermanent: true)
            }
            guard !known.isEmpty else { return }
            manager.initializeKnownSpeakers(known)
            Log.info("Diarizer: session started with \(known.count) known speaker(s)")
        }
        #endif
    }

    /// Diarizes one chunk of 16kHz mono Float samples against the running
    /// session (same speaker identities carry across chunks). Runs off the
    /// main thread; completion is called on the main queue.
    func diarize(samples: [Float], completion: @escaping ([SpeakerSegment]) -> Void) {
        #if canImport(FluidAudio)
        if #available(macOS 14.0, *), isReady, let manager = manager as? DiarizerManager {
            Task.detached(priority: .userInitiated) {
                do {
                    let result = try manager.performCompleteDiarization(samples)
                    let segments = result.segments.map {
                        SpeakerSegment(
                            speakerId: $0.speakerId,
                            start: Double($0.startTimeSeconds),
                            end: Double($0.endTimeSeconds))
                    }
                    DispatchQueue.main.async { completion(segments) }
                } catch {
                    Log.error("Diarizer: chunk diarization failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { completion([]) }
                }
            }
            return
        }
        #endif
        completion([])
    }

    /// The current session name for a speaker id (persisted name once
    /// recognized, otherwise the library's own "Speaker N" placeholder).
    func name(for speakerId: String) -> String {
        #if canImport(FluidAudio)
        if #available(macOS 14.0, *), let manager = manager as? DiarizerManager,
           let speaker = manager.speakerManager.getSpeaker(for: speakerId) {
            return speaker.name
        }
        #endif
        return speakerId
    }

    /// All speakers known to the running session (persisted + newly
    /// discovered), for the "Speakers…" naming panel.
    func sessionSpeakers() -> [SavedSpeaker] {
        #if canImport(FluidAudio)
        if #available(macOS 14.0, *), let manager = manager as? DiarizerManager {
            return manager.speakerManager.getSpeakerList().map {
                SavedSpeaker(id: $0.id, name: $0.name, embedding: $0.currentEmbedding)
            }
        }
        #endif
        return []
    }

    /// Call once at the end of a capture session: writes every speaker the
    /// session learned about (renamed or still provisional) back to
    /// `speakers.json` so they're recognized next time.
    func persistSession() {
        #if canImport(FluidAudio)
        if #available(macOS 14.0, *), let manager = manager as? DiarizerManager {
            let speakers = manager.speakerManager.getSpeakerList().map {
                SavedSpeaker(id: $0.id, name: $0.name, embedding: $0.currentEmbedding)
            }
            SpeakerStore.save(speakers)
            Log.info("Diarizer: persisted \(speakers.count) speaker(s)")
        }
        #endif
    }

    // MARK: - Pure logic (testable without a loaded model)

    /// The speaker who spoke the most within a chunk, by total segment
    /// duration. Used to pick a single "**Speaker N:**" label per chunk —
    /// per-word attribution is out of scope for v1.
    static func dominantSpeaker(_ segments: [SpeakerSegment]) -> String? {
        var totals: [String: Double] = [:]
        for segment in segments {
            totals[segment.speakerId, default: 0] += segment.duration
        }
        return totals.max(by: { $0.value < $1.value })?.key
    }

    /// The next unused "Speaker N" placeholder, skipping names already
    /// taken (e.g. by a previously renamed speaker literally called
    /// "Speaker 2"). Used when the naming panel needs a display default that
    /// doesn't collide with an existing name in the same list.
    static func nextProvisionalName(taken: Set<String>) -> String {
        var n = 1
        while taken.contains("Speaker \(n)") {
            n += 1
        }
        return "Speaker \(n)"
    }

    // MARK: - Engine

    private func loadEngine() {
        #if canImport(FluidAudio)
        if #available(macOS 14.0, *) {
            Log.info("Diarizer: preparing models")
            let started = Date()
            Task.detached(priority: .userInitiated) {
                do {
                    let models = try await DiarizerModels.downloadIfNeeded()
                    let manager = DiarizerManager()
                    manager.initialize(models: models)
                    let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                    Log.info("Diarizer: models ready in \(elapsed)s")
                    DispatchQueue.main.async {
                        self.finishPrepare(success: true, manager: manager)
                    }
                } catch {
                    Log.error("Diarizer: model download/load failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.finishPrepare(success: false, manager: nil)
                    }
                }
            }
            return
        }
        #endif
        Log.error("Diarizer: engine unavailable (requires macOS 14+ and the FluidAudio package)")
        finishPrepare(success: false, manager: nil)
    }

    private func finishPrepare(success: Bool, manager: AnyObject?) {
        self.manager = manager
        isReady = success
        isPreparing = false
        let completions = pendingCompletions
        pendingCompletions = []
        for completion in completions {
            completion(success)
        }
    }
}
