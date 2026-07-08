import Foundation
import Testing
@testable import LocalFlow

/// Pure-logic tests for Meeting Mode: the energy chunker's boundary
/// decisions, the timestamp-prefix formatter, and Me/Them/named-speaker
/// label composition. No ScreenCaptureKit, no live audio.
@Suite
struct MeetingModeTests {

    // MARK: - MeetingAudioChunker

    @Test func chunkerContinuesWhileSpeechIsOngoing() {
        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: true,
            elapsedSpeechSeconds: 3.0,
            elapsedTrailingSilenceSeconds: 0,
            totalElapsedSeconds: 3.0
        )
        #expect(decision == .continueRecording)
    }

    @Test func chunkerContinuesDuringShortSilenceBeforeThreshold() {
        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: false,
            elapsedSpeechSeconds: 3.0,
            elapsedTrailingSilenceSeconds: 0.8,
            totalElapsedSeconds: 3.8
        )
        #expect(decision == .continueRecording)
    }

    @Test func chunkerEmitsAfterSpeechThenAdequateSilence() {
        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: false,
            elapsedSpeechSeconds: 4.0,
            elapsedTrailingSilenceSeconds: 1.5,
            totalElapsedSeconds: 5.5
        )
        #expect(decision == .emit)
    }

    @Test func chunkerDiscardsSilenceOnlyRunAtForcedCap() {
        // No speech ever heard, but the 600s cap forces a boundary decision.
        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: false,
            elapsedSpeechSeconds: 0,
            elapsedTrailingSilenceSeconds: 600,
            totalElapsedSeconds: 600
        )
        #expect(decision == .discard)
    }

    @Test func chunkerForceEmitsAtCapWithEnoughSpeech() {
        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: true,
            elapsedSpeechSeconds: 450,
            elapsedTrailingSilenceSeconds: 0,
            totalElapsedSeconds: 600
        )
        #expect(decision == .emit)
    }

    @Test func chunkerDiscardsShortSpeechBelowMinimum() {
        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: false,
            elapsedSpeechSeconds: 0.2,
            elapsedTrailingSilenceSeconds: 1.5,
            totalElapsedSeconds: 1.7
        )
        #expect(decision == .discard)
    }

    // MARK: - Timestamp prefix formatting

    @Test func prefixedLineFormatsTimeSpeakerAndText() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 8
        components.hour = 12
        components.minute = 14
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!
        let line = MeetingFormatting.prefixedLine(at: date, speaker: "Me", text: "hello")
        #expect(line.contains("**Me:** hello"))
        #expect(line.hasPrefix("["))
    }

    // MARK: - Speaker label composition

    @Test func micChunkAlwaysLabeledMe() {
        let label = MeetingFormatting.speakerLabel(
            isMic: true,
            speakerLabelsEnabled: true,
            diarizerReady: true,
            dominantSpeakerName: "Alice"
        )
        #expect(label == "Me")
    }

    @Test func systemChunkFallsBackToThemWhenLabelingDisabled() {
        let label = MeetingFormatting.speakerLabel(
            isMic: false,
            speakerLabelsEnabled: false,
            diarizerReady: true,
            dominantSpeakerName: "Alice"
        )
        #expect(label == "Them")
    }

    @Test func systemChunkFallsBackToThemWhenDiarizerNotReady() {
        let label = MeetingFormatting.speakerLabel(
            isMic: false,
            speakerLabelsEnabled: true,
            diarizerReady: false,
            dominantSpeakerName: "Alice"
        )
        #expect(label == "Them")
    }

    @Test func systemChunkFallsBackToThemWhenNoDominantSpeaker() {
        let label = MeetingFormatting.speakerLabel(
            isMic: false,
            speakerLabelsEnabled: true,
            diarizerReady: true,
            dominantSpeakerName: nil
        )
        #expect(label == "Them")
    }

    @Test func systemChunkUsesDominantSpeakerNameWhenAvailable() {
        let label = MeetingFormatting.speakerLabel(
            isMic: false,
            speakerLabelsEnabled: true,
            diarizerReady: true,
            dominantSpeakerName: "Alice"
        )
        #expect(label == "Alice")
    }
}
