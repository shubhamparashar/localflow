import Foundation
import Testing
@testable import LocalFlow

@Suite struct MeetingStoreTests {
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
