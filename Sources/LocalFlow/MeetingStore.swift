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

    /// Repeated speech across mic/system channels cannot establish an owner.
    /// Keep the original transcript intact for inspection and correction.
    var notesTranscript: String { notesInput.transcript }

    var notesInput: (transcript: String, hasOverlappingChannels: Bool) {
        let ordered = entries.sorted { $0.at < $1.at }
        func words(_ text: String) -> [String] {
            let letters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
            return text.lowercased().components(separatedBy: letters.inverted).filter { !$0.isEmpty }
        }
        var spans: [String: [Int]] = [:]
        var uncertain: Set<Int> = []
        for (index, entry) in ordered.enumerated() {
            let tokens = words(entry.text)
            guard tokens.count >= 12 else { continue }
            for offset in 0...(tokens.count - 12) {
                let key = tokens[offset..<(offset + 12)].joined(separator: " ")
                for previous in spans[key] ?? [] where previous != index {
                    let other = ordered[previous]
                    if (entry.speaker == "Me") != (other.speaker == "Me"),
                       entry.at.timeIntervalSince(other.at) <= 600 {
                        uncertain.formUnion([previous, index])
                    }
                }
                if spans[key]?.last != index { spans[key, default: []].append(index) }
            }
        }
        let text = ordered.enumerated().map { index, entry in
            var seen: Set<String> = []
            var sentences: [String] = []
            entry.text.enumerateSubstrings(in: entry.text.startIndex..<entry.text.endIndex, options: .bySentences) { sentence, _, _, _ in
                guard let sentence else { return }
                let tokens = words(sentence)
                if tokens.count >= 6, !seen.insert(tokens.joined(separator: " ")).inserted { return }
                sentences.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let speaker = uncertain.contains(index) ? "Unknown speaker (overlapping channels)" : entry.speaker
            return MeetingFormatting.prefixedLine(at: entry.at, speaker: speaker, text: sentences.joined(separator: " "))
        }.joined(separator: "\n\n")
        return (text, !uncertain.isEmpty)
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
