import Foundation
import Testing
@testable import LocalFlow

/// Pure-logic tests only — no audio, no network, no AX. File-backed units
/// (snippets, glossary) are pointed at a per-suite temp directory; the suite
/// is serialized because those path overrides are process-global statics.
@Suite(.serialized)
final class PureLogicTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        SnippetsEngine.fileURL = tempDir.appendingPathComponent("snippets.json")
        Glossary.fileURL = tempDir.appendingPathComponent("glossary.txt")
        CorrectionWatcher.suggestionsFile = tempDir.appendingPathComponent("glossary-suggestions.txt")
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Snippet expansion

    private func writeSnippets(_ json: String) throws {
        try json.write(to: SnippetsEngine.fileURL, atomically: true, encoding: .utf8)
    }

    @Test func snippetFullMatchReplacesVerbatim() throws {
        try writeSnippets(#"{"snippets":[{"trigger":"my work email","expansion":"shubham.p@joinfleek.com"}]}"#)
        #expect(SnippetsEngine.apply("My work email.") == "shubham.p@joinfleek.com")
    }

    @Test func snippetInSentenceWholeWordOnly() throws {
        try writeSnippets(#"{"snippets":[{"trigger":"my work email","expansion":"shubham.p@joinfleek.com"}]}"#)
        #expect(SnippetsEngine.apply("Send it to my work email please")
            == "Send it to shubham.p@joinfleek.com please")
        try writeSnippets(#"{"snippets":[{"trigger":"cat","expansion":"dog"}]}"#)
        #expect(SnippetsEngine.apply("concatenate the cat") == "concatenate the dog")
    }

    @Test func snippetNoMatchPassesThrough() throws {
        try writeSnippets(#"{"snippets":[{"trigger":"my work email","expansion":"x"}]}"#)
        #expect(SnippetsEngine.apply("nothing to expand here") == "nothing to expand here")
    }

    // MARK: - Glossary promotion (2-sightings rule)

    @Test func glossaryPromotionAfterTwoSightings() {
        Glossary.ensureFileExists()
        CorrectionWatcher.registerSightings(["Kysely"])
        #expect(!Glossary.terms().contains("Kysely"), "one sighting must not promote")
        let suggestions = (try? String(contentsOf: CorrectionWatcher.suggestionsFile, encoding: .utf8)) ?? ""
        #expect(suggestions.contains("Kysely\t1"))

        CorrectionWatcher.registerSightings(["Kysely"])
        #expect(Glossary.terms().contains("Kysely"), "second sighting promotes")
        let after = (try? String(contentsOf: CorrectionWatcher.suggestionsFile, encoding: .utf8)) ?? ""
        #expect(!after.contains("Kysely"), "promoted term leaves the suggestions file")
    }

    @Test func glossaryKnownTermIsNotResuggested() {
        try? "Fleek\n".write(to: Glossary.fileURL, atomically: true, encoding: .utf8)
        CorrectionWatcher.registerSightings(["fleek"])
        let suggestions = (try? String(contentsOf: CorrectionWatcher.suggestionsFile, encoding: .utf8)) ?? ""
        #expect(!suggestions.contains("fleek"))
    }

    // MARK: - Cleanup guards

    @Test func guardsAcceptFaithfulCleanup() {
        let raw = "um so basically the meeting is at four pm tomorrow and we should prepare the slides"
        let cleaned = "The meeting is at 4 pm tomorrow and we should prepare the slides."
        #expect(OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned))
    }

    @Test func guardsRejectResponderModeGrowth() {
        let raw = "what time is the meeting tomorrow can you check"
        let cleaned = String(repeating: "The meeting tomorrow is scheduled at 4pm. ", count: 10)
        #expect(!OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned), "length ratio guard")
    }

    @Test func guardsRejectLowWordOverlap() {
        let raw = "please review the quarterly budget spreadsheet before friday afternoon standup meeting"
        let cleaned = "Certainly! Some totally different words about another topic entirely instead, honestly."
        #expect(!OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned), "overlap guard")
    }

    @Test func guardsRejectOverAggressiveShrink() {
        let raw = String(repeating: "we talked about the roadmap and the hiring plan today. ", count: 4)
        let cleaned = "Roadmap."
        #expect(!OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned))
    }

    @Test func wordOverlapEmptyRawIsFull() {
        #expect(OllamaCleaner.wordOverlap(raw: "a an it", cleaned: "whatever") == 1.0)
    }

    // MARK: - Long-take sentence chunker

    @Test func sentenceWindowsPackWholeSentences() {
        let s1 = "This is the first sentence about something."
        let s2 = "Here comes a second sentence with more words in it."
        let s3 = "And finally a third one to overflow the window."
        let windows = OllamaCleaner.sentenceWindows(s1 + " " + s2 + " " + s3, maxLength: 100)
        #expect(windows.count == 2)
        #expect(windows[0].contains("first sentence"))
        #expect(windows[0].contains("second sentence"))
        #expect(windows[1].contains("third one"))
    }

    @Test func sentenceWindowsOversizedSentenceIsOwnWindow() {
        let long = "this single sentence just keeps going and going without any terminal punctuation at all "
            + "so it cannot be split on a boundary and must become its own window even though it is oversized"
        let windows = OllamaCleaner.sentenceWindows("Short one. " + long, maxLength: 50)
        #expect(windows.first == "Short one.")
        #expect(windows.count >= 2)
    }

    @Test func sentenceWindowsShortTextSingleWindow() {
        #expect(OllamaCleaner.sentenceWindows("Just one.", maxLength: 500) == ["Just one."])
    }

    // MARK: - Cleanup levels & styles

    @Test func cleanupLevelsProduceDistinctPrompts() {
        let light = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .light)
        let medium = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .medium)
        let high = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .high)
        let code = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .medium, style: .code)
        #expect(Set([light, medium, high, code]).count == 4)
        #expect(!light.contains("homophones"), "light skips error correction")
        #expect(medium.contains("homophones"))
        #expect(high.contains("Smooth awkward grammar"))
        #expect(!medium.contains("Smooth awkward grammar"))
    }

    @Test func noneLevelBypassesOllamaEntirely() async {
        let savedEnabled = Config.cleanupEnabled
        let savedLevel = Config.cleanupLevel
        Config.cleanupEnabled = true
        Config.cleanupLevel = .none
        defer {
            Config.cleanupEnabled = savedEnabled
            Config.cleanupLevel = savedLevel
        }
        let raw = String(repeating: "some transcript text well over the minimum length. ", count: 3)
        // No Ollama server runs in tests: an immediate raw-text completion
        // proves the bypass (a real request would only fall back to raw after
        // a network failure/timeout).
        let started = Date()
        let result: String = await withCheckedContinuation { cont in
            OllamaCleaner.clean(raw) { cont.resume(returning: $0) }
        }
        #expect(result == raw)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test func cleanupLevelRoundTripsThroughConfig() {
        let saved = Config.cleanupLevel
        defer { Config.cleanupLevel = saved }
        for level in CleanupLevel.allCases {
            Config.cleanupLevel = level
            #expect(Config.cleanupLevel == level)
            #expect(UserDefaults.standard.string(forKey: "cleanupLevel") == level.rawValue)
        }
    }

    @Test func codeStylePromptPreservesIdentifiers() {
        let prompt = OllamaCleaner.cleanupSystemPrompt(glossary: ["Kysely"], level: .medium, style: .code)
        #expect(prompt.contains("camelCase"))
        #expect(prompt.contains("snake_case"))
        #expect(prompt.contains("Never alter the casing"))
        #expect(prompt.contains("Kysely"), "glossary bias included like the normal prompt")
    }

    @Test func guardsAcceptFaithfulCodeStyleCleanup() {
        let raw = "um so rename the get_user_id function to fetchUserId and update the snake_case call sites"
        let cleaned = "Rename the get_user_id function to fetchUserId and update the snake_case call sites."
        #expect(OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned))
    }

    @Test func codeCategoryDefaultsToCodeStyle() {
        let profile = AppContext.lookupProfile(
            bundleId: "com.apple.Terminal",
            mapping: ["com.apple.Terminal": CategoryMappingEntry(category: "code", style: nil)]
        )
        #expect(profile.category == "code")
        #expect(profile.styleOverride == .code)
        #expect(profile.cleanupEnabled)
    }

    @Test func mappingStyleOverrideWinsAndLegacyStringsParse() throws {
        let json = #"{"com.apple.mail": "email", "com.microsoft.VSCode": {"category": "code", "style": "casual"}}"#
        let mapping = try #require(AppContext.parseMapping(Data(json.utf8)))
        let mail = AppContext.lookupProfile(bundleId: "com.apple.mail", mapping: mapping)
        #expect(mail.category == "email")
        #expect(mail.styleOverride == nil)
        let vscode = AppContext.lookupProfile(bundleId: "com.microsoft.VSCode", mapping: mapping)
        #expect(vscode.styleOverride == .casual)
    }

    // MARK: - Edit distance (glossary diffing)

    @Test func editDistance() {
        #expect(CorrectionWatcher.editDistance("kysely", "kysley") == 2)
        #expect(CorrectionWatcher.editDistance("same", "same") == 0)
        #expect(CorrectionWatcher.editDistance("abcdefgh", "xyz") == Int.max)
    }
}
