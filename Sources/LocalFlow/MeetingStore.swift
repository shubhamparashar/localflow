import Foundation

struct MeetingDocument: Codable, Identifiable, Equatable {
    struct Entry: Codable, Equatable {
        var at: Date
        var speaker: String
        var text: String
    }

    var id = UUID()
    var title = "Untitled meeting"
    var startedAt = Date()
    var endedAt: Date?
    var rawNotes = ""
    var enhancedNotes = ""
    var captureWarnings: [String]?
    var entries: [Entry] = []

    var transcript: String {
        entries.sorted { $0.at < $1.at }.map {
            MeetingFormatting.prefixedLine(at: $0.at, speaker: $0.speaker, text: $0.text)
        }.joined(separator: "\n\n")
    }
}

final class MeetingStore {
    let directory: URL
    private(set) var documents: [MeetingDocument] = []
    private(set) var loadErrors: [String] = []

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalFlow/Meetings", isDirectory: true)) {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                do {
                    let document = try JSONDecoder().decode(MeetingDocument.self, from: Data(contentsOf: url))
                    guard url.deletingPathExtension().lastPathComponent == document.id.uuidString else {
                        loadErrors.append(url.lastPathComponent)
                        continue
                    }
                    documents.append(document)
                } catch { loadErrors.append(url.lastPathComponent) }
            }
            documents.sort { $0.startedAt > $1.startedAt }
        } catch { loadErrors.append(error.localizedDescription) }
    }

    func document(_ id: UUID) -> MeetingDocument? { documents.first { $0.id == id } }

    func save(_ document: MeetingDocument) throws {
        let data = try JSONEncoder().encode(document)
        try data.write(to: directory.appendingPathComponent(document.id.uuidString + ".json"), options: .atomic)
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        } else {
            documents.insert(document, at: 0)
        }
    }
}
