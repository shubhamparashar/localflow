import Contacts
import Foundation

/// One-shot glossary bootstrapping: pulls candidate proper nouns and code
/// identifiers from macOS Contacts, git history, and repo source, then
/// appends only the genuinely-new ones to the glossary file.
enum GlossaryImporter {
    enum ImportError: Error {
        case contactsAccessDenied
    }

    // MARK: - Dedup (pure)

    /// Dedupes `newTerms` against `existing` case-insensitively. Preserves the
    /// original casing of newly-added terms and the order they appear in.
    static func merge(newTerms: [String], into existing: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var added: [String] = []
        for term in newTerms {
            let key = term.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            added.append(term)
        }
        return added
    }

    /// Appends the genuinely-new candidates to the glossary file and returns
    /// how many were added.
    @discardableResult
    static func appendToGlossary(_ candidates: [String]) -> Int {
        Glossary.ensureFileExists()
        let added = merge(newTerms: candidates, into: Glossary.terms())
        guard !added.isEmpty else { return 0 }
        let block = added.joined(separator: "\n") + "\n"
        if let handle = FileHandle(forWritingAtPath: Glossary.fileURL.path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(Data(block.utf8))
        } else {
            try? block.write(to: Glossary.fileURL, atomically: true, encoding: .utf8)
        }
        return added.count
    }

    // MARK: - macOS Contacts importer

    /// Given+family names from Contacts, filtered to words 3+ chars long and capitalized.
    static func importFromContacts(completion: @escaping (Result<[String], Error>) -> Void) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, error in
            guard granted else {
                completion(.failure(error ?? ImportError.contactsAccessDenied))
                return
            }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var names: [String] = []
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    for word in [contact.givenName, contact.familyName] where word.count >= 3 {
                        names.append(word.prefix(1).uppercased() + word.dropFirst())
                    }
                }
                completion(.success(names))
            } catch {
                Log.error("Contacts import failed: \(error)")
                completion(.failure(error))
            }
        }
    }

    // MARK: - git log author importer

    /// Unique author names from `git log`, split into individual name words.
    static func importFromGitAuthors(repoPath: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoPath, "log", "--format=%aN"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error("git log author import failed: \(error)")
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let authors = Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return authors.flatMap { $0.split(separator: " ").map(String.init) }.filter { $0.count >= 3 }
    }

    // MARK: - Repo identifier importer

    private static let sourceExtensions: Set<String> = ["swift", "ts", "js", "py", "go", "rb", "java", "kt"]
    private static let maxFilesScanned = 2000
    private static let maxIdentifiers = 200

    private static let identifierRegex = try! NSRegularExpression(
        pattern: "\\b([A-Za-z][a-z0-9]*(?:[A-Z][a-z0-9]*)+|[a-z][a-z0-9]*(?:_[a-z0-9]+)+)\\b"
    )

    /// Scans source files under `repoPath` and returns the top identifiers by
    /// frequency, ready to append to the glossary.
    static func importFromRepoIdentifiers(repoPath: String) -> [String] {
        let files = sourceFiles(under: repoPath, limit: maxFilesScanned)
        let contents = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        return topIdentifiers(in: contents, top: maxIdentifiers)
    }

    /// Pure: extracts CamelCase/snake_case identifiers (6+ chars) from a chunk
    /// of source text.
    static func identifiers(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return identifierRegex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            let identifier = String(text[r])
            return identifier.count >= 6 ? identifier : nil
        }
    }

    /// Pure ranking: counts identifier occurrences across `texts` and returns
    /// the top `top` by frequency (ties broken alphabetically for stable order).
    static func topIdentifiers(in texts: [String], top: Int) -> [String] {
        var counts: [String: Int] = [:]
        for text in texts {
            for identifier in identifiers(in: text) {
                counts[identifier, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(top)
            .map(\.key)
    }

    private static func sourceFiles(under path: String, limit: Int) -> [URL] {
        let root = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains("node_modules") { continue }
            guard sourceExtensions.contains(url.pathExtension) else { continue }
            files.append(url)
            if files.count >= limit { break }
        }
        return files
    }
}
