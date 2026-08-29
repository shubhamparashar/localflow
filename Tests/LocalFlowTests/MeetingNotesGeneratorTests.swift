import Foundation
import Testing
@testable import LocalFlow

/// Feature: Meeting Recorder v2 - post-meeting notes generation
/// ERD: docs/erd/MEETING_RECORDER_ERD.md
/// Scenarios: prompt building (happy), empty transcript guard (G1),
/// long-transcript truncation (G3), empty model response (G2).
@Suite
struct MeetingNotesGeneratorTests {

    // Scenario: normal transcript produces a prompt containing the transcript
    // ERD Section: 5 H2
    @Test func promptContainsTranscript() {
        let prompt = MeetingNotesGenerator.prompt(transcript: "[12:00] **Me:** hello there")
        #expect(prompt != nil)
        #expect(prompt!.contains("hello there"))
        #expect(prompt!.contains("## Summary"))
    }

    // Scenario: empty/whitespace transcript yields no prompt (no Ollama call)
    // ERD Section: 5 G1
    @Test func emptyTranscriptYieldsNil() {
        #expect(MeetingNotesGenerator.prompt(transcript: "") == nil)
        #expect(MeetingNotesGenerator.prompt(transcript: "  \n ") == nil)
    }

    // Scenario: 3h-scale transcript is truncated to the newest tail and says so
    // ERD Section: 5 G3
    @Test func longTranscriptTruncatesKeepingTail() {
        let filler = String(repeating: "old line\n", count: 5000)
        let prompt = MeetingNotesGenerator.prompt(transcript: filler + "FINAL DECISION MARKER")!
        #expect(prompt.contains("FINAL DECISION MARKER"))
        #expect(prompt.contains("truncated"))
        #expect(prompt.count < MeetingNotesGenerator.maxTranscriptChars + 1000)
    }

    // Scenario: empty model response is treated as failure, not appended
    // ERD Section: 5 G2
    @Test func emptyResponseCleansToNil() {
        #expect(MeetingNotesGenerator.cleanResponse("") == nil)
        #expect(MeetingNotesGenerator.cleanResponse("  \n") == nil)
        #expect(MeetingNotesGenerator.cleanResponse(" notes ") == "notes")
    }
}
