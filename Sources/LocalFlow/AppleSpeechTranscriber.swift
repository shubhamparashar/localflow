// Portions adapted from FluidVoice (https://github.com/altic-dev/FluidVoice), commit 1698a31, Apache License 2.0.

import AVFoundation
import Foundation
import Speech

/// On-device transcription via Apple's `SFSpeechRecognizer`. Requires no model
/// download and has ~0 idle footprint, so it's the fallback used while the
/// Parakeet models are still downloading. Recognition is forced on-device
/// (`requiresOnDeviceRecognition = true`); permission is requested lazily on
/// first real use.
final class AppleSpeechTranscriber {
    static let shared = AppleSpeechTranscriber()

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var didRequestAuthorization = false

    private init() {}

    /// Optimistic readiness for the routing decision: true unless we know the
    /// recognizer is missing/unavailable or the user has denied/restricted it.
    /// `notDetermined` counts as available — the actual request happens lazily
    /// in `transcribe`, and a denial there falls through to whisper.
    var isAvailable: Bool {
        guard let recognizer, recognizer.isAvailable else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return false
        default:
            return true
        }
    }

    /// wav = 16-bit PCM mono 16kHz WAV data (44-byte header + samples).
    /// The completion is called on the main queue.
    func transcribe(wav: Data, completion: @escaping (Result<String, Error>) -> Void) {
        requestAuthorizationIfNeeded { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                completion(.failure(Self.error(1, "Speech recognition not authorized")))
                return
            }
            self.run(samples: ParakeetTranscriber.floatSamples(fromWav: wav), completion: completion)
        }
    }

    private func run(samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            completion(.failure(Self.error(2, "SFSpeechRecognizer unavailable")))
            return
        }
        guard let buffer = Self.pcmBuffer(from: samples) else {
            completion(.failure(Self.error(3, "Failed to build audio buffer")))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.append(buffer)
        request.endAudio()

        let started = Date()
        var resumed = false
        recognizer.recognitionTask(with: request) { result, error in
            guard !resumed else { return }
            if let error {
                resumed = true
                Log.error("Apple Speech failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let result, result.isFinal else { return }
            resumed = true
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            Log.info("Apple Speech transcribed in \(elapsed)s: \"\(text)\"")
            DispatchQueue.main.async { completion(.success(text)) }
        }
    }

    private func requestAuthorizationIfNeeded(_ completion: @escaping (Bool) -> Void) {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            completion(true)
            return
        }
        guard status == .notDetermined, !didRequestAuthorization else {
            completion(false)
            return
        }
        didRequestAuthorization = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    private static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "LocalFlow.AppleSpeech", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
