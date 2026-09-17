import Foundation
import Testing
@testable import LocalFlow

@Suite struct MeetingStoreTests {
    @Test func notesFlagCrossChannelOwnershipAndKeepRawTranscript() {
        var document = MeetingDocument()
        let speech = "We should check the existing integration documentation before deciding who will implement this change."
        document.entries = [
            .init(at: Date(timeIntervalSince1970: 0), speaker: "Me", text: speech + " " + speech),
            .init(at: Date(timeIntervalSince1970: 300), speaker: "Speaker 2", text: speech),
            .init(at: Date(timeIntervalSince1970: 310), speaker: "Me", text: "I will not deploy today."),
            .init(at: Date(timeIntervalSince1970: 1200), speaker: "Speaker 2", text: "I will publish the draft tomorrow.")
        ]
        let original = document.transcript
        let notes = document.notesTranscript
        #expect(document.notesInput.hasOverlappingChannels)
        #expect(notes.components(separatedBy: "Unknown speaker (overlapping channels)").count - 1 == 2)
        #expect(notes.components(separatedBy: speech).count - 1 == 2)
        #expect(notes.contains("**Me:** I will not deploy today."))
        #expect(notes.contains("**Speaker 2:** I will publish the draft tomorrow."))
        #expect(document.transcript == original)
        #expect(original.components(separatedBy: speech).count - 1 == 3)
    }

    @Test func distantRepetitionAndShortAcknowledgmentsDoNotInvalidateSpeaker() {
        var document = MeetingDocument()
        let speech = "We should check the existing integration documentation before deciding who will implement this change."
        document.entries = [
            .init(at: Date(timeIntervalSince1970: 0), speaker: "Me", text: speech),
            .init(at: Date(timeIntervalSince1970: 700), speaker: "Speaker 2", text: speech),
            .init(at: Date(timeIntervalSince1970: 705), speaker: "Me", text: "Okay."),
            .init(at: Date(timeIntervalSince1970: 706), speaker: "Speaker 2", text: "Okay.")
        ]
        #expect(!document.notesTranscript.contains("Unknown speaker"))
        #expect(!document.notesInput.hasOverlappingChannels)
    }

    @Test func deduplicationPreservesDistinctCombiningMarks() {
        var document = MeetingDocument()
        let first = "Jose\u{0301} will review the shipping integration changes tomorrow."
        let second = "Jose\u{0300} will review the shipping integration changes tomorrow."
        document.entries = [.init(at: Date(), speaker: "Me", text: first + " " + second)]
        #expect(document.notesTranscript.contains(first))
        #expect(document.notesTranscript.contains(second))
    }

    @Test func recoversSeparateMeetingsAndOrdersTranscriptByCaptureTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(directory: directory)
        var first = MeetingDocument()
        first.rawNotes = "Keep the launch decision · कल"
        first.enhancedNotes = "Launch on Friday"
        first.captureWarnings = ["System audio unavailable. Recording microphone only."]
        first.entries = [
            .init(at: Date(timeIntervalSince1970: 20), speaker: "Them", text: "Closing decision"),
            .init(at: Date(timeIntervalSince1970: 10), speaker: "Me", text: "Opening context")
        ]
        try store.save(first)
        var second = MeetingDocument()
        second.title = "Separate meeting"
        try store.save(second)
        first.rawNotes += "\nFollow up tomorrow"
        try store.save(first)
        let recovered = MeetingStore(directory: directory)
        #expect(recovered.documents.count == 2)
        #expect(recovered.document(first.id) == first)
        #expect(recovered.document(second.id) == second)
        #expect(first.transcript.range(of: "Opening context")!.lowerBound < first.transcript.range(of: "Closing decision")!.lowerBound)
        #expect(recovered.loadErrors.isEmpty)
    }

    @Test func corruptFileDoesNotHideGoodMeetingsOrGetOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(directory: directory)
        let document = MeetingDocument()
        try store.save(document)
        let corrupt = directory.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: corrupt)
        let recovered = MeetingStore(directory: directory)
        #expect(recovered.document(document.id) == document)
        #expect(recovered.loadErrors == ["broken.json"])
        #expect(try String(contentsOf: corrupt) == "broken")
    }

    @Test func failedSaveIsReportedWithoutReplacingSavedContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(directory: directory)
        var document = MeetingDocument()
        try store.save(document)
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        document.rawNotes = "Cannot save"
        #expect(throws: (any Error).self) { try store.save(document) }
        #expect(store.document(document.id)?.rawNotes == "")
    }
}
