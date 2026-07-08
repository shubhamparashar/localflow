import Foundation
import Testing
@testable import LocalFlow

@Suite(.serialized)
struct PolishFeedbackTests {
    private let injected = "And one more thing, it's not taking long transcripts when speaking out loud for a minute."

    @Test func recordsGenuineRewrite() {
        let corrected = "One more thing: it doesn't handle long transcripts — speaking for a minute just disappears."
        #expect(PolishFeedback.shouldRecord(injected: injected, current: corrected))
    }

    @Test func ignoresUntouchedText() {
        #expect(!PolishFeedback.shouldRecord(injected: injected, current: injected))
    }

    @Test func ignoresUnrelatedFieldContent() {
        let unrelated = "Quarterly revenue grew 12% while churn stayed flat across all cohorts this period."
        #expect(!PolishFeedback.shouldRecord(injected: injected, current: unrelated))
    }

    @Test func ignoresFieldWithLotsOfOtherContent() {
        let padded = injected + String(repeating: " Existing document text around the dictation.", count: 12)
        #expect(!PolishFeedback.shouldRecord(injected: injected, current: padded))
    }

    @Test func ignoresShortInjections() {
        #expect(!PolishFeedback.shouldRecord(injected: "Hi there.", current: "Hello there!"))
    }

    @Test func promptBlockEmptyWithoutPairs() {
        #expect(PolishFeedback.promptBlock(pairs: []) == "")
    }

    @Test func promptBlockUsesMostRecentPairs() {
        let pairs = (1...5).map {
            PolishFeedback.Pair(ts: Date(), injected: "draft \($0)", corrected: "final \($0)")
        }
        let block = PolishFeedback.promptBlock(pairs: pairs)
        #expect(block.contains("draft 5"))
        #expect(block.contains("final 3"))
        #expect(!block.contains("draft 2"))
        #expect(block.contains("do NOT copy"))
    }

    @Test func recordAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = PolishFeedback.file
        defer { PolishFeedback.file = original }
        PolishFeedback.file = dir.appendingPathComponent("polish-feedback.jsonl")

        let corrected = "One more thing: it doesn't handle long transcripts — speaking for a minute disappears."
        PolishFeedback.record(injected: injected, current: corrected)
        let loaded = PolishFeedback.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.corrected == corrected)
    }
}
