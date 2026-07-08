import Foundation
import Testing
@testable import LocalFlow

/// Pure-logic tests for speaker diarization support: dominant-speaker
/// selection, speakers.json round-trip, and provisional-name numbering. No
/// model is loaded — `SpeakerDiarizer.shared.isReady` stays false, which is
/// exactly the "diarizer not ready" path exercised elsewhere.
@Suite(.serialized)
final class SpeakerDiarizerTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        SpeakerStore.fileURL = tempDir.appendingPathComponent("speakers.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Dominant speaker

    @Test func dominantSpeakerPicksLongestTotalDuration() {
        let segments = [
            SpeakerSegment(speakerId: "1", start: 0, end: 1),
            SpeakerSegment(speakerId: "2", start: 1, end: 4),
            SpeakerSegment(speakerId: "1", start: 4, end: 4.5),
        ]
        #expect(SpeakerDiarizer.dominantSpeaker(segments) == "2")
    }

    @Test func dominantSpeakerNilForEmptySegments() {
        #expect(SpeakerDiarizer.dominantSpeaker([]) == nil)
    }

    @Test func dominantSpeakerSingleSegment() {
        let segments = [SpeakerSegment(speakerId: "3", start: 0, end: 2)]
        #expect(SpeakerDiarizer.dominantSpeaker(segments) == "3")
    }

    // MARK: - speakers.json round-trip

    @Test func speakerStoreRoundTrip() {
        let speakers = [
            SavedSpeaker(id: "1", name: "Alice", embedding: [0.1, 0.2, 0.3]),
            SavedSpeaker(id: "2", name: "Speaker 2", embedding: [0.4, 0.5]),
        ]
        SpeakerStore.save(speakers)
        #expect(SpeakerStore.load() == speakers)
    }

    @Test func speakerStoreLoadMissingFileReturnsEmpty() {
        #expect(SpeakerStore.load().isEmpty)
    }

    @Test func speakerStoreOverwritesPreviousSave() {
        SpeakerStore.save([SavedSpeaker(id: "1", name: "Alice", embedding: [0.1])])
        SpeakerStore.save([SavedSpeaker(id: "1", name: "Alicia", embedding: [0.1])])
        #expect(SpeakerStore.load() == [SavedSpeaker(id: "1", name: "Alicia", embedding: [0.1])])
    }

    // MARK: - Provisional naming

    @Test func nextProvisionalNameStartsAtOne() {
        #expect(SpeakerDiarizer.nextProvisionalName(taken: []) == "Speaker 1")
    }

    @Test func nextProvisionalNameSkipsTakenNames() {
        #expect(SpeakerDiarizer.nextProvisionalName(taken: ["Speaker 1", "Speaker 2"]) == "Speaker 3")
    }

    @Test func nextProvisionalNameSkipsNonContiguousTakenNames() {
        #expect(SpeakerDiarizer.nextProvisionalName(taken: ["Speaker 1", "Speaker 3"]) == "Speaker 2")
    }

    @Test func nextProvisionalNameIgnoresUnrelatedNames() {
        #expect(SpeakerDiarizer.nextProvisionalName(taken: ["Alice", "Bob"]) == "Speaker 1")
    }

    // MARK: - Panel merge (diarizer not ready ⇒ no session speakers)

    @Test func mergedSpeakersReturnsPersistedWhenNoSession() {
        SpeakerStore.save([SavedSpeaker(id: "1", name: "Alice", embedding: [0.1])])
        #expect(SpeakersPanel.mergedSpeakers() == [SavedSpeaker(id: "1", name: "Alice", embedding: [0.1])])
    }

    @Test func mergedSpeakersEmptyWhenNothingPersisted() {
        #expect(SpeakersPanel.mergedSpeakers().isEmpty)
    }
}
