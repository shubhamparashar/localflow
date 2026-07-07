import AppKit
import Foundation

/// User-defined trigger phrases that expand into longer text during
/// dictation. If the whole cleaned transcript matches a trigger (ignoring
/// case and trailing punctuation) the expansion replaces the transcript
/// verbatim; otherwise triggers found inside the text are replaced in
/// place, longest trigger first, on whole-word boundaries only.
enum SnippetsEngine {

    struct Snippet: Codable {
        let trigger: String
        let expansion: String
    }

    private struct SnippetsFile: Codable {
        let snippets: [Snippet]
    }

    static var fileURL: URL = Log.dir.appendingPathComponent("snippets.json")

    private static var cachedSnippets: [Snippet] = []
    private static var cachedModificationDate: Date?

    static func apply(_ text: String) -> String {
        let snippets: [Snippet] = loadSnippets()
        guard !snippets.isEmpty else { return text }

        let normalizedInput: String = normalize(text)
        if !normalizedInput.isEmpty {
            for snippet in snippets {
                let normalizedTrigger: String = normalize(snippet.trigger)
                if normalizedTrigger == normalizedInput {
                    return snippet.expansion
                }
            }
        }

        let longestFirst: [Snippet] = snippets.sorted { (a: Snippet, b: Snippet) -> Bool in
            a.trigger.count > b.trigger.count
        }
        var result: String = text
        for snippet in longestFirst {
            result = replacingWholeWordOccurrences(of: snippet.trigger, with: snippet.expansion, in: result)
        }
        return result
    }

    /// Fills injection-time placeholders in an expanded snippet: `{clipboard}`
    /// becomes the given pasteboard string, `{date}` the formatted date, and
    /// `{cursor}` is stripped, returning instead how many characters from the
    /// END of the final text the caret should land (nil when absent; only the
    /// first `{cursor}` counts).
    static func fillSlots(
        expansion: String,
        clipboard: String,
        date: Date
    ) -> (text: String, cursorOffsetFromEnd: Int?) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var text = expansion
            .replacingOccurrences(of: "{clipboard}", with: clipboard)
            .replacingOccurrences(of: "{date}", with: formatter.string(from: date))
        var offsetFromEnd: Int?
        if let range = text.range(of: "{cursor}") {
            // Mark the first occurrence, strip the rest, then measure — later
            // occurrences sit in the tail and would inflate a naive distance.
            let marker = "\u{0}"
            text.replaceSubrange(range, with: marker)
            text = text.replacingOccurrences(of: "{cursor}", with: "")
            if let markerRange = text.range(of: marker) {
                text.removeSubrange(markerRange)
                offsetFromEnd = text.distance(from: markerRange.lowerBound, to: text.endIndex)
            }
        }
        return (text, offsetFromEnd)
    }

    static func count() -> Int {
        let snippets: [Snippet] = loadSnippets()
        return snippets.count
    }

    static func openInEditor() {
        ensureFileExists()
        NSWorkspace.shared.open(fileURL)
    }

    static func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? template.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Loading

    private static func loadSnippets() -> [Snippet] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedSnippets = []
            cachedModificationDate = nil
            return []
        }
        let attributes: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modificationDate: Date? = attributes?[.modificationDate] as? Date
        if let cached: Date = cachedModificationDate, let current: Date = modificationDate, cached == current {
            return cachedSnippets
        }
        cachedModificationDate = modificationDate
        cachedSnippets = parseFile()
        return cachedSnippets
    }

    private static func parseFile() -> [Snippet] {
        guard let data: Data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            let file: SnippetsFile = try JSONDecoder().decode(SnippetsFile.self, from: data)
            return file.snippets
        } catch {
            Log.error("snippets.json is unreadable, ignoring it: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Matching

    /// Lowercases, trims, and strips trailing sentence punctuation so that
    /// a dictated "My email signature." still matches the trigger
    /// "my email signature".
    private static func normalize(_ text: String) -> String {
        var result: String = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trailingPunctuation: Set<Character> = [".", "!", "?", ","]
        while let last: Character = result.last, trailingPunctuation.contains(last) {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingWholeWordOccurrences(of trigger: String, with expansion: String, in text: String) -> String {
        let trimmedTrigger: String = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty else { return text }
        let escapedTrigger: String = NSRegularExpression.escapedPattern(for: trimmedTrigger)
        // Lookarounds instead of \b so triggers that start or end with a
        // non-word character still get boundary-safe matching.
        let pattern: String = "(?<!\\w)" + escapedTrigger + "(?!\\w)"
        guard let regex: NSRegularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let fullRange: NSRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let template: String = NSRegularExpression.escapedTemplate(for: expansion)
        return regex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: template)
    }

    // MARK: - Template

    private static let template: String = """
    {
        "_comment": "LocalFlow snippets. Each entry maps a spoken trigger phrase to the text inserted instead. If an entire dictation matches a trigger (ignoring case and trailing punctuation) the expansion replaces it verbatim; otherwise triggers spoken inside a sentence are replaced in place. Use \\n inside an expansion for line breaks.",
        "snippets": [
            {
                "trigger": "my email signature",
                "expansion": "Best,\\nShubham Parashar\\nEngineering @ Fleek"
            },
            {
                "trigger": "my work email",
                "expansion": "shubham.p@joinfleek.com"
            }
        ]
    }
    """
}
