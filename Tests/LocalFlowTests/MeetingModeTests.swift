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
        // Silent streams also advance through bounded windows.
        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: false,
            elapsedSpeechSeconds: 0,
            elapsedTrailingSilenceSeconds: 30,
            totalElapsedSeconds: 30
        )
        #expect(decision == .discard)
    }

    @Test func chunkerForceEmitsAtCapWithEnoughSpeech() {
        let decision = MeetingAudioChunker.decide(
            isSpeechFrame: true,
            elapsedSpeechSeconds: 30,
            elapsedTrailingSilenceSeconds: 0,
            totalElapsedSeconds: 30
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

@Suite struct MeetingQualityFixTests {
    @Test func clauseLoopCollapses() {
        let text = "If you want to get a process, then you have to get a process, and you have to get a process, and you have to get a process, and you have to get a process."
        let out = Transcriber.collapseRepeatedClauses(text)
        #expect(out == "If you want to get a process, then you have to get a process.")
    }

    @Test func clauseCollapseLeavesNormalProseAlone() {
        let text = "We shipped the harness, fixed the pipeline, and updated the docs."
        #expect(Transcriber.collapseRepeatedClauses(text) == text)
    }

    @Test func hallucinationDetectedOnTinyVocabularyWall() {
        let text = String(repeating: "you have to get a process, and then you have to get a process. ", count: 12)
        #expect(Transcriber.looksLikeHallucination(text))
    }

    @Test func realSpeechNotFlaggedAsHallucination() {
        let text = "So the first step of the job is getting to the reactive state on cost. "
            + "We can connect daily, share multiple channels, watch for spikes higher or lower than expected, "
            + "and take action quickly. That brings accountability, and doing justice to it drives our own growth "
            + "over the next two weeks while sea shipping keeps running in parallel with everything else."
        #expect(!Transcriber.looksLikeHallucination(text))
    }

    @Test func shortTextNeverFlagged() {
        #expect(!Transcriber.looksLikeHallucination("Thank you. Thank you."))
    }

    @Test func leadingLabelsStripped() {
        #expect(MeetingFormatting.strippingLeadingLabels("**Them:** So, we're still working.") == "So, we're still working.")
        #expect(MeetingFormatting.strippingLeadingLabels("**Me:** **Them:** Huh.") == "Huh.")
        #expect(MeetingFormatting.strippingLeadingLabels("No labels here.") == "No labels here.")
    }
}

@Suite struct MeetingMicrophoneBufferTests {
    @Test func continuousSpeechRollsOverWithoutDroppingOrDuplicatingSamples() {
        let start = Date(timeIntervalSince1970: 1_000)
        let input = (0..<(65 * 16_000)).map { Float($0) }
        var buffer = MeetingMicrophoneBuffer()
        var windows: [MeetingMicrophoneBuffer.Chunk] = []
        for offset in stride(from: 0, to: input.count, by: 4096) {
            let end = min(offset + 4096, input.count)
            windows += buffer.append(Array(input[offset..<end]), at: start.addingTimeInterval(Double(offset) / 16_000), isSpeech: true)
        }
        #expect(windows.count == 2)
        #expect(windows.map { $0.samples.count } == [480_000, 480_000])
        #expect(windows.map { $0.startedAt } == [start, start.addingTimeInterval(30)])
        #expect(buffer.startedAt == start.addingTimeInterval(60))
        #expect(buffer.samples.count == 80_000)
        #expect(windows.flatMap { $0.samples } + buffer.samples == input)
    }

    @Test func silenceIsSkippedWithoutResettingTheSampleClock() {
        var buffer = MeetingMicrophoneBuffer()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(buffer.append([Float](repeating: 0, count: 480_000), at: start, isSpeech: false).isEmpty)
        #expect(buffer.startedAt == start.addingTimeInterval(30))
        #expect(!buffer.hasSpeech)
        #expect(buffer.append([Float](repeating: 0.1, count: 4_000), at: start, isSpeech: true).isEmpty)
        #expect(!buffer.hasSpeech)
        #expect(buffer.append([Float](repeating: 0.1, count: 4_000), at: start, isSpeech: true).isEmpty)
        #expect(buffer.hasSpeech)
        #expect(buffer.samples.count == 8_000)
    }

    @Test func speechPauseEmitsWithoutLosingTheNextUtterance() {
        var buffer = MeetingMicrophoneBuffer()
        let start = Date(timeIntervalSince1970: 1_000)
        let firstSpeech = [Float](repeating: 0.2, count: 16_000)
        let pause = [Float](repeating: 0, count: 24_000)
        let nextSpeech = [Float](repeating: 0.3, count: 16_000)
        #expect(buffer.append(firstSpeech, at: start, isSpeech: true).isEmpty)
        let windows = buffer.append(pause, at: start.addingTimeInterval(1), isSpeech: false)
        #expect(windows.count == 1)
        let firstWindowPreserved = windows.first?.samples == firstSpeech + pause
        #expect(firstWindowPreserved)
        #expect(windows.first?.startedAt == start)
        #expect(buffer.startedAt == start.addingTimeInterval(2.5))
        #expect(buffer.append(nextSpeech, at: start.addingTimeInterval(2.5), isSpeech: true).isEmpty)
        #expect(buffer.hasSpeech)
        let allSamplesPreserved = windows.flatMap { $0.samples } + buffer.samples == firstSpeech + pause + nextSpeech
        #expect(allSamplesPreserved)
    }

    @Test func exactBoundaryLeavesNoDuplicateFinalWindow() {
        var buffer = MeetingMicrophoneBuffer()
        let start = Date(timeIntervalSince1970: 1_000)
        let windows = buffer.append([Float](repeating: 0.2, count: 480_000), at: start, isSpeech: true)
        #expect(windows.count == 1)
        #expect(buffer.samples.isEmpty)
        #expect(buffer.startedAt == start.addingTimeInterval(30))
        #expect(buffer.append([], at: start, isSpeech: false).isEmpty)
    }
}
