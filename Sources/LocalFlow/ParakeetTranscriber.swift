import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// On-device English transcription using NVIDIA Parakeet TDT 0.6B v3
/// (CoreML) via the FluidAudio package.
///
/// Models (~480 MB) are downloaded once from HuggingFace
/// (FluidInference/parakeet-tdt-0.6b-v3-coreml) into
/// ~/Library/Application Support/FluidAudio/Models/ and loaded from cache
/// on subsequent launches.
///
/// FluidAudio requires macOS 14+. On older systems (or when the package is
/// not present) `isReady` stays false and `transcribe` fails fast.
final class ParakeetTranscriber {
    static let shared = ParakeetTranscriber()

    /// True once models are downloaded and loaded. Main-thread access only.
    private(set) var isReady: Bool = false

    private var isPreparing: Bool = false
    private var pendingCompletions: [(Bool) -> Void] = []
    /// The FluidAudio `AsrManager` actor, stored type-erased so this class
    /// compiles on deployment targets older than the engine supports.
    private var engine: AnyObject?

    private static let wavHeaderSize: Int = 44
    /// Parakeet rejects clips shorter than 300ms of 16kHz audio
    /// (FluidAudio's ASRConstants.minimumAudioDurationSeconds); such taps
    /// are treated as silence rather than surfaced as errors.
    private static let minimumSamples: Int = 4_800

    private init() {}

    /// Kick off async model download+load; safe to call repeatedly.
    /// The completion (and any queued while a load is in flight) is called
    /// on the main queue.
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

    /// wav = 16-bit PCM mono 16kHz WAV data (44-byte header + samples).
    /// The completion is called on the main queue.
    func transcribe(wav: Data, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async {
            self.startTranscription(samples: Self.floatSamples(fromWav: wav), completion: completion)
        }
    }

    /// Same as `transcribe(wav:)` but takes normalized 16kHz mono Float
    /// samples directly, skipping the WAV encode/decode round trip. Used for
    /// rolling partial-caption snapshots where the caller already holds the
    /// samples in memory.
    func transcribe(samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async {
            self.startTranscription(samples: samples, completion: completion)
        }
    }

    /// ~0.5s of silence at 16kHz — enough to push a real inference through
    /// the model so CoreML's slow first-inference cost lands here instead of
    /// on the user's first take.
    private static let preWarmSamples = 8_000

    /// Runs a throwaway inference through the loaded model. Safe to call
    /// repeatedly (e.g. after every wake); a no-op until `isReady`.
    func preWarm() {
        guard isReady else { return }
        let silence = [Float](repeating: 0, count: Self.preWarmSamples)
        let started = Date()
        transcribe(samples: silence) { _ in
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            Log.info("Parakeet pre-warmed in \(elapsed)s")
        }
    }

    // MARK: - Engine

    private func loadEngine() {
        #if canImport(FluidAudio)
        if #available(macOS 14.0, *) {
            let cacheDir = AsrModels.defaultCacheDirectory()
            Log.info("Parakeet: preparing models (cache: \(cacheDir.path))")
            let started = Date()
            Task.detached(priority: .userInitiated) {
                do {
                    let models = try await AsrModels.downloadAndLoad()
                    let manager = AsrManager(config: .default)
                    try await manager.loadModels(models)
                    let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                    Log.info("Parakeet: models ready in \(elapsed)s")
                    DispatchQueue.main.async {
                        self.finishPrepare(success: true, engine: manager)
                    }
                } catch {
                    Log.error("Parakeet: model download/load failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.finishPrepare(success: false, engine: nil)
                    }
                }
            }
            return
        }
        #endif
        Log.error("Parakeet: engine unavailable (requires macOS 14+ and the FluidAudio package)")
        finishPrepare(success: false, engine: nil)
    }

    private func finishPrepare(success: Bool, engine: AnyObject?) {
        self.engine = engine
        isReady = success
        isPreparing = false
        let completions = pendingCompletions
        pendingCompletions = []
        for completion in completions {
            completion(success)
        }
    }

    // MARK: - Transcription

    private func startTranscription(samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        #if canImport(FluidAudio)
        if #available(macOS 14.0, *) {
            guard isReady, let manager = engine as? AsrManager else {
                let err = Self.error(code: 3, "Parakeet engine is not ready — call prepare() first")
                completion(.failure(err))
                return
            }
            guard samples.count >= Self.minimumSamples else {
                Log.info("Parakeet: clip too short (\(samples.count) samples), returning empty transcript")
                completion(.success(""))
                return
            }
            let started = Date()
            Task.detached(priority: .userInitiated) {
                do {
                    let decoderLayers = await manager.decoderLayerCount
                    var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
                    let result = try await manager.transcribe(
                        samples, decoderState: &decoderState, language: .english)
                    let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.info("Parakeet: transcribed in \(elapsed)s: \"\(text)\"")
                    DispatchQueue.main.async { completion(.success(text)) }
                } catch {
                    Log.error("Parakeet: transcription failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
            return
        }
        #endif
        let err = Self.error(code: 4, "Parakeet requires macOS 14+ and the FluidAudio package")
        completion(.failure(err))
    }

    // MARK: - WAV parsing

    /// Converts 16-bit PCM mono 16kHz WAV data into normalized Float
    /// samples, skipping the 44-byte canonical RIFF header.
    private static func floatSamples(fromWav wav: Data) -> [Float] {
        guard wav.count > wavHeaderSize else { return [] }
        let sampleCount = (wav.count - wavHeaderSize) / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: sampleCount)
        wav.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<sampleCount {
                let byteOffset = wavHeaderSize + index * MemoryLayout<Int16>.size
                let rawSample = raw.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
                let sample = Int16(littleEndian: rawSample)
                samples[index] = Float(sample) / 32_768.0
            }
        }
        return samples
    }

    private static func error(code: Int, _ message: String) -> NSError {
        return NSError(domain: "LocalFlow", code: code, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
