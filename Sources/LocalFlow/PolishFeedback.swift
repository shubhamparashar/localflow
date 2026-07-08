import Foundation

/// Sentence-level cleanup feedback: when the user rewrites an injected
/// transcript in place, the (injected → corrected) pair is kept and the most
/// recent pairs are fed into the cleanup prompt as few-shot style examples —
/// so the cleaner learns punctuation, filler handling, and phrasing the user
/// keeps fixing by hand. Vocabulary-level learning stays in CorrectionWatcher.
enum PolishFeedback {
    struct Pair: Codable {
        let ts: Date
        let injected: String
        let corrected: String
    }

    static var file: URL = Log.dir.appendingPathComponent("polish-feedback.jsonl")

    static let maxStored = 20
    static let promptExamples = 3
    private static let maxChars = 500

    /// True when `current` reads as the user's edit of `injected` — same text
    /// (high word overlap) but meaningfully changed, not a different document
    /// and not an untouched or trivially-tweaked paste.
    static func shouldRecord(injected: String, current: String) -> Bool {
        guard injected.count >= 30, injected.count <= maxChars, current.count <= maxChars else { return false }
        let normalizedInjected = normalize(injected)
        let normalizedCurrent = normalize(current)
        guard normalizedInjected != normalizedCurrent else { return false }
        let ratio = Double(current.count) / Double(injected.count)
        guard ratio >= 0.5, ratio <= 2.0 else { return false }
        let overlap = wordJaccard(injected, current)
        // <0.35: a different text (field held other content); >0.95: a
        // one-word fix, which CorrectionWatcher already harvests. Heavy
        // rewrites of the same sentence land around 0.4-0.6.
        return overlap >= 0.35 && overlap <= 0.95
    }

    static func record(injected: String, current: String) {
        guard shouldRecord(injected: injected, current: current) else { return }
        var pairs = load()
        pairs.append(Pair(ts: Date(), injected: injected, corrected: current))
        pairs = Array(pairs.suffix(maxStored))
        save(pairs)
        Log.info("Polish feedback recorded (\(injected.count) → \(current.count) chars)")
    }

    /// Few-shot block appended to the cleanup system prompt; empty string
    /// when there is nothing to teach.
    static func promptBlock() -> String {
        promptBlock(pairs: load())
    }

    static func promptBlock(pairs: [Pair]) -> String {
        let recent = pairs.suffix(promptExamples)
        guard !recent.isEmpty else { return "" }
        let examples = recent.map { pair in
            "Draft: \(pair.injected)\nUser's preferred version: \(pair.corrected)"
        }.joined(separator: "\n---\n")
        return """


        The user rewrote these past outputs by hand. Match the style of the \
        preferred versions (punctuation, casing, phrasing) — do NOT copy their \
        content into the output:
        \(examples)
        """
    }

    // MARK: - Store (JSONL, newest last)

    static func load() -> [Pair] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap {
            decoder.decodeOrNil(Pair.self, from: Data($0.utf8))
        }
    }

    private static func save(_ pairs: [Pair]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = pairs.compactMap { pair -> String? in
            guard let data = try? encoder.encode(pair) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: file)
    }

    // MARK: - Similarity

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func wordJaccard(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let wordsB = Set(b.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        let union = wordsA.union(wordsB).count
        return Double(wordsA.intersection(wordsB).count) / Double(union)
    }
}

private extension JSONDecoder {
    func decodeOrNil<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decode(type, from: data)
    }
}
