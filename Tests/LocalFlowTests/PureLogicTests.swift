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

    // MARK: - Edit distance (glossary diffing)

    @Test func editDistance() {
        #expect(CorrectionWatcher.editDistance("kysely", "kysley") == 2)
        #expect(CorrectionWatcher.editDistance("same", "same") == 0)
        #expect(CorrectionWatcher.editDistance("abcdefgh", "xyz") == Int.max)
    }

    // MARK: - Partial-caption tick scheduler

    @Test func partialTickSkipsBeforeThreshold() {
        #expect(!PartialCaptionScheduler.shouldRunTick(elapsedSamples: 8_000, samplesPerTick: 16_000, inFlight: false))
    }

    @Test func partialTickRunsAtThresholdWhenIdle() {
        #expect(PartialCaptionScheduler.shouldRunTick(elapsedSamples: 16_000, samplesPerTick: 16_000, inFlight: false))
        #expect(PartialCaptionScheduler.shouldRunTick(elapsedSamples: 20_000, samplesPerTick: 16_000, inFlight: false))
    }

    @Test func partialTickSkipsAtThresholdWhenBusy() {
        #expect(!PartialCaptionScheduler.shouldRunTick(elapsedSamples: 16_000, samplesPerTick: 16_000, inFlight: true))
    }
}
