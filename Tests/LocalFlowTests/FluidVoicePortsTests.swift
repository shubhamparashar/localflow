import Foundation
import Testing
@testable import LocalFlow

/// Pure-logic tests for the FluidVoice-derived injection cascade and the
/// transcription fallback-engine decision. No CGEvent/AX/audio/network.
struct FluidVoicePortsTests {

    // MARK: - Injection cascade tier selection

    @Test func cascadeEmptyWhenAXNotTrusted() {
        #expect(TextInjector.cascade(axTrusted: false, targetPidValid: true, textFitsCGEvent: true).isEmpty)
        #expect(TextInjector.cascade(axTrusted: false, targetPidValid: false, textFitsCGEvent: false).isEmpty)
    }

    @Test func cascadeIncludesPidUnicodeWhenPidValidAndTextFits() {
        let tiers = TextInjector.cascade(axTrusted: true, targetPidValid: true, textFitsCGEvent: true)
        #expect(tiers == [.pidUnicode, .axInsert, .clipboardPaste, .charByChar])
    }

    @Test func cascadeDropsPidUnicodeWhenNoValidPid() {
        let tiers = TextInjector.cascade(axTrusted: true, targetPidValid: false, textFitsCGEvent: true)
        #expect(tiers == [.axInsert, .clipboardPaste, .charByChar])
    }

    @Test func cascadeDropsPidUnicodeWhenTextTooLong() {
        let tiers = TextInjector.cascade(axTrusted: true, targetPidValid: true, textFitsCGEvent: false)
        #expect(tiers == [.axInsert, .clipboardPaste, .charByChar])
    }

    @Test func cascadeAlwaysEndsWithClipboardThenCharByChar() {
        for pid in [true, false] {
            for fits in [true, false] {
                let tiers = TextInjector.cascade(axTrusted: true, targetPidValid: pid, textFitsCGEvent: fits)
                #expect(tiers.suffix(2) == [.clipboardPaste, .charByChar])
            }
        }
    }

    // MARK: - Transcription fallback-engine decision

    @Test func runEngineParakeetWhenEnglishAndReady() {
        #expect(TranscriptionRouter.runEngine(language: "en", parakeetReady: true, appleSpeechAvailable: true) == .parakeet)
        #expect(TranscriptionRouter.runEngine(language: "en", parakeetReady: true, appleSpeechAvailable: false) == .parakeet)
    }

    @Test func runEngineAppleSpeechWhenParakeetNotReadyButAvailable() {
        #expect(TranscriptionRouter.runEngine(language: "en", parakeetReady: false, appleSpeechAvailable: true) == .appleSpeech)
    }

    @Test func runEngineWhisperWhenParakeetNotReadyAndNoAppleSpeech() {
        #expect(TranscriptionRouter.runEngine(language: "en", parakeetReady: false, appleSpeechAvailable: false) == .whisper)
    }

    @Test func runEngineWhisperForNonEnglishRegardlessOfAppleSpeech() {
        #expect(TranscriptionRouter.runEngine(language: "hi", parakeetReady: true, appleSpeechAvailable: true) == .whisper)
        #expect(TranscriptionRouter.runEngine(language: "auto", parakeetReady: false, appleSpeechAvailable: true) == .whisper)
    }

    @Test func runEngineNeverPicksAppleSpeechWhenParakeetWouldRun() {
        // Apple Speech is strictly a not-ready English fallback.
        let engine = TranscriptionRouter.runEngine(language: "en", parakeetReady: true, appleSpeechAvailable: true)
        #expect(engine != .appleSpeech)
    }
}
