import AVFoundation

/// Decides whether a rolling ~1s audio tick should trigger a new
/// partial-caption inference: enough new audio has accumulated since the
/// last tick, and no previous partial inference is still running (ticks are
/// dropped rather than queued, so the Flow-Bar caption never falls behind).
enum PartialCaptionScheduler {
    static func shouldRunTick(elapsedSamples: Int, samplesPerTick: Int, inFlight: Bool) -> Bool {
        guard elapsedSamples >= samplesPerTick else { return false }
        return !inFlight
    }
}

/// Captures microphone audio and accumulates it as 16 kHz mono Float32
/// samples, the input format whisper.cpp expects.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let sampleQueue = DispatchQueue(label: "localflow.audio.samples")
    private(set) var isRecording = false

    /// Fired once per recording (on the main queue) when hands-free
    /// endpointing decides the utterance is over.
    var onAutoStop: (() -> Void)?

    /// Fired per audio chunk (~10 Hz, main queue) with the level in dBFS.
    var onLevel: ((Float) -> Void)?

    /// Fired roughly once per second of recorded audio (background queue)
    /// with a snapshot of all samples accumulated so far. HUD-only: the
    /// snapshot is for live captions, never for the final injected
    /// transcript.
    var onPartialAudio: (([Float]) -> Void)?

    /// Polled once per tick to decide whether to fire `onPartialAudio` —
    /// return true while a previous partial inference is still running so
    /// this tick gets skipped instead of queued.
    var isPartialInferenceBusy: (() -> Bool)?

    private var samplesSinceLastPartialTick = 0
    private static let partialTickSamples = Int(targetSampleRate) // ~1s

    /// Speaking duration of the most recently stopped recording.
    private(set) var lastDurationSec: Double = 0

    private var autoStopEnabled = false
    private var autoStopFired = false
    private var speechDetected = false
    private var lastSpeechAt = Date.distantPast
    private var armedAt = Date.distantPast
    private var recordingStartedAt = Date.distantPast
    private var noiseFloorDb: Float = -70

    private static let silenceWindow: TimeInterval = 0.9
    /// Long-form dictation pauses to think: once the speaker has been going
    /// past `longFormAfter`, a ~1s gap is a pause, not the end — require a
    /// longer silence before auto-stopping.
    private static let longFormSilenceWindow: TimeInterval = 2.5
    private static let longFormAfter: TimeInterval = 12
    private static let noSpeechTimeout: TimeInterval = 10
    private static let maxHandsFreeDuration: TimeInterval = 180

    /// Pure endpoint-window selection, exposed for testing.
    static func endpointSilenceWindow(speakingFor: TimeInterval) -> TimeInterval {
        speakingFor > longFormAfter ? longFormSilenceWindow : silenceWindow
    }

    /// Input gain multiplier and VAD speech-threshold offset (added to the
    /// adaptive noise floor) for normal vs. quiet/whispered speech. Quiet
    /// mode boosts gain ~1.75x and lowers the offset/floor so soft speech
    /// still crosses the threshold.
    private static let normalGain: Float = 1.0
    private static let normalVadOffsetDb: Float = 12
    private static let normalVadFloorDb: Float = -55
    private static let quietGain: Float = 1.75
    private static let quietVadOffsetDb: Float = 6
    private static let quietVadFloorDb: Float = -65

    /// Pure profile selection, exposed for testing.
    static func recordingProfile(quietModeEnabled: Bool) -> (gain: Float, vadOffsetDb: Float, vadFloorDb: Float) {
        quietModeEnabled
            ? (quietGain, quietVadOffsetDb, quietVadFloorDb)
            : (normalGain, normalVadOffsetDb, normalVadFloorDb)
    }

    private var gain: Float = normalGain
    private var vadOffsetDb: Float = normalVadOffsetDb
    private var vadFloorDb: Float = normalVadFloorDb

    private static let targetSampleRate = 16000.0
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        sampleQueue.sync { samples.removeAll() }
        autoStopEnabled = false
        autoStopFired = false
        speechDetected = false
        lastSpeechAt = .distantPast
        noiseFloorDb = -70
        recordingStartedAt = Date()
        samplesSinceLastPartialTick = 0

        let profile = Self.recordingProfile(quietModeEnabled: Config.quietModeEnabled)
        gain = profile.gain
        vadOffsetDb = profile.vadOffsetDb
        vadFloorDb = profile.vadFloorDb
        Log.info(
            "Recording profile: \(Config.quietModeEnabled ? "quiet" : "normal") " +
                "(gain \(gain), vad \(vadOffsetDb)/\(vadFloorDb))"
        )

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "LocalFlow", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input device available",
            ])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and returns the utterance as 16-bit PCM WAV data.
    /// Returns nil when the recording is too short to transcribe (<0.3 s).
    func stop() -> Data? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        var captured: [Float] = []
        sampleQueue.sync { captured = self.samples }

        lastDurationSec = Double(captured.count) / Self.targetSampleRate
        let minSamples = Int(Self.targetSampleRate * 0.3)
        guard captured.count >= minSamples else {
            Log.info("Recording too short (\(captured.count) samples), discarding")
            return nil
        }
        Log.info("Recorded \(String(format: "%.2f", lastDurationSec))s of audio")
        return Self.wavData(samples: captured, sampleRate: Int(Self.targetSampleRate))
    }

    /// Stops once the speaker has actually paused: waits for `silenceWindow`
    /// of trailing quiet (or `maxWait` at most) before cutting the recording,
    /// so a key released mid-word doesn't clip the utterance.
    func stopAfterTrailingSilence(
        silenceWindow: TimeInterval = 0.4,
        maxWait: TimeInterval = 1.5,
        completion: @escaping (Data?) -> Void
    ) {
        guard isRecording else {
            completion(nil)
            return
        }
        let started = Date()
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else {
                timer?.invalidate()
                completion(nil)
                return
            }
            let now = Date()
            let quietFor = now.timeIntervalSince(self.lastSpeechAt)
            let waited = now.timeIntervalSince(started)
            if quietFor >= silenceWindow || waited >= maxWait {
                timer?.invalidate()
                completion(self.stop())
            }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error {
            Log.error("Audio conversion failed: \(error.localizedDescription)")
            return
        }
        guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        var chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        if gain != 1.0 {
            for i in chunk.indices { chunk[i] *= gain }
        }
        sampleQueue.async {
            self.samples.append(contentsOf: chunk)
            self.checkPartialTick(addedSamples: chunk.count)
        }
        evaluateEndpoint(chunk)
    }

    /// Runs on `sampleQueue` (background) so the snapshot copy never touches
    /// the audio tap thread.
    private func checkPartialTick(addedSamples: Int) {
        guard onPartialAudio != nil else { return }
        samplesSinceLastPartialTick += addedSamples
        let elapsed = samplesSinceLastPartialTick
        guard elapsed >= Self.partialTickSamples else { return }
        samplesSinceLastPartialTick = 0
        let busy = isPartialInferenceBusy?() ?? false
        guard PartialCaptionScheduler.shouldRunTick(
            elapsedSamples: elapsed,
            samplesPerTick: Self.partialTickSamples,
            inFlight: busy
        ) else {
            Log.info("Partial caption tick skipped (inference in flight)")
            return
        }
        onPartialAudio?(samples)
    }

    /// Arms hands-free endpointing: the recording stops itself once speech
    /// has been heard and ~0.9 s of trailing silence follows.
    func enableAutoStop() {
        armedAt = Date()
        autoStopEnabled = true
    }

    private func evaluateEndpoint(_ chunk: [Float]) {
        let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
        let levelDb = 20 * log10(max(rms, 1e-7))

        // Adaptive noise floor: drops fast, rises slowly, so brief speech
        // doesn't drag it up.
        if levelDb < noiseFloorDb {
            noiseFloorDb = levelDb
        } else {
            noiseFloorDb += min(0.1, (levelDb - noiseFloorDb) * 0.02)
        }

        let now = Date()
        let speechThreshold = max(noiseFloorDb + vadOffsetDb, vadFloorDb)
        if levelDb > speechThreshold {
            speechDetected = true
            lastSpeechAt = now
        }
        if let onLevel {
            DispatchQueue.main.async { onLevel(levelDb) }
        }

        guard autoStopEnabled, !autoStopFired else { return }
        let speakingFor = now.timeIntervalSince(recordingStartedAt)
        let shouldStop =
            (speechDetected && now.timeIntervalSince(lastSpeechAt) > Self.endpointSilenceWindow(speakingFor: speakingFor)) ||
            (!speechDetected && now.timeIntervalSince(armedAt) > Self.noSpeechTimeout) ||
            (now.timeIntervalSince(recordingStartedAt) > Self.maxHandsFreeDuration)
        if shouldStop {
            autoStopFired = true
            Log.info("VAD auto-stop (speech=\(speechDetected), floor=\(String(format: "%.0f", noiseFloorDb))dB)")
            DispatchQueue.main.async { self.onAutoStop?() }
        }
    }

    private static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1)) // PCM
        data.appendLE(UInt16(1)) // mono
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(sampleRate * 2)) // byte rate
        data.appendLE(UInt16(2)) // block align
        data.appendLE(UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            data.appendLE(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
