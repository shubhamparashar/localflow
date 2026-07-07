import Foundation

/// Runs Parakeet on rolling audio snapshots to update the Flow-Bar caption
/// while recording. Strictly HUD-only — this never produces the text that
/// gets injected; the final transcript still comes from
/// `TranscriptionRouter`/`ParakeetTranscriber` via the normal stop-and-send
/// path in `AppDelegate.transcribeAndRoute`, which does not read anything
/// from this class.
///
/// Serializes inference to at most one in-flight take (callers should also
/// consult `isBusy` before firing a new tick, so ticks are skipped rather
/// than queued) and drops results from a take that has since been
/// cancelled.
final class PartialCaptionRunner {
    private let lock = NSLock()
    private var busy = false
    private var generation = 0

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }

    /// Invalidates any in-flight or already-finished inference so its result
    /// is dropped when it calls back — call when recording stops or a new
    /// take starts.
    func cancel() {
        lock.lock()
        generation += 1
        busy = false
        lock.unlock()
    }

    /// `onCaption` is invoked on the main queue with a non-empty caption,
    /// unless this run was cancelled before Parakeet finished.
    func run(samples: [Float], onCaption: @escaping (String) -> Void) {
        lock.lock()
        guard !busy else {
            lock.unlock()
            return
        }
        busy = true
        let myGeneration = generation
        lock.unlock()

        ParakeetTranscriber.shared.transcribe(samples: samples) { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.generation == myGeneration
            self.busy = false
            self.lock.unlock()
            guard stillCurrent, case .success(let text) = result, !text.isEmpty else { return }
            onCaption(text)
        }
    }
}
