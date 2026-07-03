import Foundation

/// User-maintained list of proper nouns, jargon, and code identifiers that
/// whisper and the cleanup LLM should spell exactly. One term per line;
/// lines starting with # are comments.
enum Glossary {
    static var fileURL: URL {
        Log.dir.appendingPathComponent("glossary.txt")
    }

    static func terms() -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Initial prompt for whisper itself — biases decoding toward these
    /// spellings before the LLM pass even runs.
    static func whisperPrompt() -> String? {
        let list = terms()
        guard !list.isEmpty else { return nil }
        return "Glossary: " + list.joined(separator: ", ") + "."
    }

    static func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let template = """
        # LocalFlow glossary — one term per line. Whisper and the cleanup
        # LLM will prefer these exact spellings. Lines starting with # are
        # ignored.
        #
        # Examples:
        # Fleek
        # Kysely
        # whisper.cpp
        """
        try? template.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
