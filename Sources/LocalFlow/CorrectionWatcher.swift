import AppKit
import ApplicationServices

/// Learns vocabulary from the user's own corrections: after a transcript is
/// injected, the focused field's value is re-read later and diffed against
/// what was pasted. Words the user typed over (small edit distance,
/// proper-noun/jargon shaped) become glossary suggestions; a term seen
/// twice is promoted into the glossary automatically.
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    static var suggestionsFile: URL = Log.dir.appendingPathComponent("glossary-suggestions.txt")

    private struct Snapshot {
        let pastedText: String
        let element: AXUIElement
    }

    private var pending: Snapshot?
    private static let recheckDelay: TimeInterval = 45
    private static let promoteAfterSightings = 2

    /// Called right after text is injected into the focused field.
    func recordInjection(_ text: String) {
        guard text.count >= 20 else { return }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let focused else { return }
        let element = focused as! AXUIElement
        pending = Snapshot(pastedText: text, element: element)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recheckDelay) { [weak self] in
            self?.checkPending()
        }
    }

    /// Re-reads the field and harvests corrections. Also called at the
    /// start of the next dictation (the user is done editing by then).
    func checkPending() {
        guard let snapshot = pending else { return }
        pending = nil
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            snapshot.element,
            kAXValueAttribute as CFString,
            &value
        )
        // Many apps (Electron, canvas-based) don't expose AXValue — skip
        // silently; this feature is opportunistic.
        guard err == .success, let current = value as? String, !current.isEmpty else { return }
        let corrections = Self.findCorrections(pasted: snapshot.pastedText, current: current)
        guard !corrections.isEmpty else { return }
        Log.info("Learned correction candidates: \(corrections.joined(separator: ", "))")
        Self.registerSightings(corrections)
    }

    // MARK: - Diffing

    /// Words in `current` that look like the user's respelling of a word we
    /// pasted: close edit distance, not present in the pasted text, and
    /// proper-noun/jargon shaped.
    static func findCorrections(pasted: String, current: String) -> [String] {
        let pastedWords = contentWords(pasted)
        let currentWords = contentWords(current)
        let pastedSet = Set(pastedWords.map { $0.lowercased() })
        let checker = NSSpellChecker.shared
        var found: [String] = []
        for candidate in Set(currentWords) {
            let lower = candidate.lowercased()
            guard !pastedSet.contains(lower) else { continue }
            guard isVocabularyShaped(candidate, checker: checker) else { continue }
            for original in pastedWords {
                let distance = editDistance(lower, original.lowercased())
                if distance >= 1 && distance <= 3 {
                    found.append(candidate)
                    break
                }
            }
            if found.count >= 5 { break }
        }
        return found
    }

    private static func contentWords(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)
            .filter { $0.count >= 4 }
    }

    /// Proper nouns, mixed-case identifiers, or words the system spell
    /// checker doesn't know (jargon). Plain lowercase dictionary words are
    /// everyday edits, not vocabulary.
    private static func isVocabularyShaped(_ word: String, checker: NSSpellChecker) -> Bool {
        let startsUpper = word.first?.isUppercase == true
        let mixedCase = word.dropFirst().contains(where: { $0.isUppercase })
        if startsUpper || mixedCase { return true }
        let range = checker.checkSpelling(of: word, startingAt: 0)
        return range.location != NSNotFound
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if abs(aChars.count - bChars.count) > 3 { return Int.max }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...max(aChars.count, 1) where !aChars.isEmpty {
            current[0] = i
            for j in 1...max(bChars.count, 1) where !bChars.isEmpty {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return bChars.isEmpty ? aChars.count : previous[bChars.count]
    }

    // MARK: - Suggestion store

    /// suggestions file format: one "term<TAB>count" per line.
    static func registerSightings(_ terms: [String]) {
        var counts: [String: Int] = [:]
        if let existing = try? String(contentsOf: suggestionsFile, encoding: .utf8) {
            for line in existing.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count == 2, let count = Int(parts[1]) {
                    counts[String(parts[0])] = count
                }
            }
        }
        let glossaryTerms = Set(Glossary.terms().map { $0.lowercased() })
        for term in terms {
            guard !glossaryTerms.contains(term.lowercased()) else { continue }
            let newCount = (counts[term] ?? 0) + 1
            if newCount >= promoteAfterSightings {
                promoteToGlossary(term)
                counts[term] = nil
            } else {
                counts[term] = newCount
            }
        }
        let body = counts
            .sorted { $0.value > $1.value }
            .map { "\($0.key)\t\($0.value)" }
            .joined(separator: "\n")
        try? (body + "\n").data(using: .utf8)?.write(to: suggestionsFile)
    }

    private static func promoteToGlossary(_ term: String) {
        Glossary.ensureFileExists()
        if let handle = try? FileHandle(forUpdating: Glossary.fileURL) {
            let end = handle.seekToEndOfFile()
            // A file whose last line lacks a trailing newline would glue the
            // appended term onto that line (and a #-comment would swallow it).
            if end > 0 {
                handle.seek(toFileOffset: end - 1)
                let lastByte = handle.readData(ofLength: 1)
                if lastByte != Data("\n".utf8) {
                    handle.write(Data("\n".utf8))
                }
            }
            handle.write(Data("\(term)\n".utf8))
            try? handle.close()
            Log.info("Auto-learned glossary term: \(term)")
        }
    }
}
