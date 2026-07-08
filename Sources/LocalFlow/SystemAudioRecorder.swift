import AppKit
import AVFoundation
import ScreenCaptureKit

/// Outcome of one energy-frame evaluation in `MeetingAudioChunker`.
enum MeetingChunkDecision: Equatable {
    /// Keep accumulating into the current chunk.
    case continueRecording
    /// Chunk boundary reached with enough speech content — hand it off.
    case emit
    /// Chunk boundary reached (silence-only, or a forced cutover with no
    /// real speech) — drop it, nothing worth transcribing.
    case discard
}

/// Pure energy-based chunk-boundary logic for system-audio capture, decoupled
/// from ScreenCaptureKit/AVFoundation so it's unit-testable without a live
/// stream or a granted permission. Mirrors the trailing-silence idea behind
/// `AudioRecorder`'s VAD endpointing, but chunks a continuous stream into
/// segments instead of ending a single recording.
enum MeetingAudioChunker {
    /// How much trailing silence after speech ends a chunk.
    static let trailingSilenceThreshold: TimeInterval = 1.5
    /// Hard cap so a chunk can't grow unbounded through a long monologue.
    static let forceEmitCap: TimeInterval = 600
    /// Chunks with less spoken content than this are noise, not a note.
    static let minSpeechForEmit: TimeInterval = 0.5

    static func decide(
        isSpeechFrame: Bool,
        elapsedSpeechSeconds: TimeInterval,
        elapsedTrailingSilenceSeconds: TimeInterval,
        totalElapsedSeconds: TimeInterval
    ) -> MeetingChunkDecision {
        let hitCap = totalElapsedSeconds >= forceEmitCap
        let silenceEndedSpeech = !isSpeechFrame
            && elapsedSpeechSeconds > 0
            && elapsedTrailingSilenceSeconds >= trailingSilenceThreshold
        guard hitCap || silenceEndedSpeech else { return .continueRecording }
        return elapsedSpeechSeconds >= minSpeechForEmit ? .emit : .discard
    }
}

/// Captures system (loopback) audio via ScreenCaptureKit — the audio side of
/// whatever's playing in a Meet/Zoom tab or app window — and chunks it the
/// same way a meeting note-taker would: speech, then a pause, is one note.
///
/// Audio-only: the video side of the mandatory screen stream is configured at
/// a minimal 2x2 resolution and every `.screen` sample is ignored in the
/// output callback: SCStream requires *some* video track even when only
/// audio is wanted.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let targetSampleRate = 16000.0
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "localflow.systemaudio")
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    private var chunkSamples: [Float] = []
    private var elapsedSpeechSeconds: TimeInterval = 0
    private var elapsedTrailingSilenceSeconds: TimeInterval = 0
    private var totalElapsedSeconds: TimeInterval = 0
    private var noiseFloorDb: Float = -70

    private(set) var isRunning = false

    /// Fired on a background queue with an emitted chunk's samples (16 kHz
    /// mono Float32) — never the discarded ones.
    var onChunk: (([Float]) -> Void)?

    /// True once `SCShareableContent` has failed at least once this launch —
    /// used to only alert the user about the Screen Recording permission once.
    private static var didWarnPermission = false

    func start(completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            completion(true)
            return
        }
        resetChunkState()

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard let display = content.displays.first else {
                    Log.error("Meeting mode: no shareable display found")
                    await self.finishStart(false, completion: completion)
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Int(Self.targetSampleRate)
                config.channelCount = 1
                // Minimal mandatory video track — every .screen sample is
                // dropped in the output callback below.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let newStream = SCStream(filter: filter, configuration: config, delegate: self)
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await newStream.startCapture()
                self.stream = newStream
                self.isRunning = true
                Log.info("Meeting mode: system audio capture started")
                await self.finishStart(true, completion: completion)
            } catch {
                Log.error("Meeting mode: system audio capture failed to start (\(error.localizedDescription))")
                Self.warnPermissionOnce()
                await self.finishStart(false, completion: completion)
            }
        }
    }

    @MainActor
    private func finishStart(_ ok: Bool, completion: @escaping (Bool) -> Void) {
        completion(ok)
    }

    /// Stops the stream and flushes whatever partial chunk was mid-flight, so
    /// audio recorded right up to the toggle-off isn't silently dropped.
    func stop(completion: @escaping ([Float]?) -> Void) {
        guard isRunning, let stream else {
            completion(nil)
            return
        }
        isRunning = false
        self.stream = nil
        stream.stopCapture { [weak self] error in
            if let error {
                Log.error("Meeting mode: system audio stop failed (\(error.localizedDescription))")
            }
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.sampleQueue.async {
                let flushed = self.finalizeChunk(force: true)
                DispatchQueue.main.async { completion(flushed) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Meeting mode: system audio stream stopped unexpectedly (\(error.localizedDescription))")
        isRunning = false
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = extractSamples(from: sampleBuffer) else { return }
        // Already hopping through `sampleQueue` (the configured
        // sampleHandlerQueue) — process inline rather than re-dispatching.
        process(samples)
    }

    // MARK: - Sample extraction (AVFoundation glue, runs on sampleQueue)

    private func extractSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        guard let sourceFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: &audioBufferList) else {
            return nil
        }

        // The stream is configured for 16 kHz mono already, but the
        // converter step is kept as a defensive resample in case the
        // delivered format doesn't exactly match the requested config.
        if converterSourceFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
            converterSourceFormat = sourceFormat
        }
        guard let converter else { return nil }

        let ratio = Self.targetSampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        if let error {
            Log.error("Meeting mode: system audio conversion failed (\(error.localizedDescription))")
            return nil
        }
        guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    // MARK: - Chunking (runs on sampleQueue)

    private func resetChunkState() {
        chunkSamples.removeAll()
        elapsedSpeechSeconds = 0
        elapsedTrailingSilenceSeconds = 0
        totalElapsedSeconds = 0
        noiseFloorDb = -70
    }

    private func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        chunkSamples.append(contentsOf: samples)

        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        let levelDb = 20 * log10(max(rms, 1e-7))
        if levelDb < noiseFloorDb {
            noiseFloorDb = levelDb
        } else {
            noiseFloorDb += min(0.1, (levelDb - noiseFloorDb) * 0.02)
        }
        let isSpeech = levelDb > max(noiseFloorDb + 12, -55)

        let frameSeconds = Double(samples.count) / Self.targetSampleRate
        totalElapsedSeconds += frameSeconds
        if isSpeech {
            elapsedSpeechSeconds += frameSeconds
            elapsedTrailingSilenceSeconds = 0
        } else {
            elapsedTrailingSilenceSeconds += frameSeconds
        }

        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: isSpeech,
            elapsedSpeechSeconds: elapsedSpeechSeconds,
            elapsedTrailingSilenceSeconds: elapsedTrailingSilenceSeconds,
            totalElapsedSeconds: totalElapsedSeconds
        )
        switch decision {
        case .continueRecording:
            return
        case .emit:
            let emitted = chunkSamples
            resetChunkState()
            onChunk?(emitted)
        case .discard:
            Log.info("Meeting mode: system-audio chunk discarded (\(String(format: "%.1f", elapsedSpeechSeconds))s speech)")
            resetChunkState()
        }
    }

    /// Called on stop: forces whatever's accumulated out as a final chunk
    /// (still subject to the minimum-speech floor) instead of dropping it.
    private func finalizeChunk(force: Bool) -> [Float]? {
        guard !chunkSamples.isEmpty else { return nil }
        let hadEnoughSpeech = elapsedSpeechSeconds >= MeetingAudioChunker.minSpeechForEmit
        let samples = chunkSamples
        resetChunkState()
        return hadEnoughSpeech ? samples : nil
    }

    // MARK: - Permission

    private static func warnPermissionOnce() {
        guard !didWarnPermission else { return }
        didWarnPermission = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Screen Recording permission needed"
            alert.informativeText = "Meeting Mode needs Screen Recording access to hear system audio (the other side of a call). Grant it in System Settings, then turn Meeting Mode on again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Screen Recording Settings")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
