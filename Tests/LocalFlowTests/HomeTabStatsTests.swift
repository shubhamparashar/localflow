import Foundation
import Testing
@testable import LocalFlow

@Suite
struct HomeTabStatsTests {

    private func record(daysAgo: Double, durationSec: Double = 30, finalWords: Int = 100, now: Date) -> DictationRecord {
        DictationRecord(
            ts: now.addingTimeInterval(-daysAgo * 86400),
            durationSec: durationSec,
            rawWords: finalWords,
            finalWords: finalWords,
            mode: "hold",
            sttSeconds: 1.0,
            cleanupSeconds: 0.5,
            rawText: "",
            finalText: nil,
            app: nil,
            totalLatencySec: nil
        )
    }

    // MARK: totalWords

    @Test func totalWordsSumsFinalWords() {
        let now = Date()
        let records = [
            record(daysAgo: 0, finalWords: 10, now: now),
            record(daysAgo: 1, finalWords: 25, now: now),
            record(daysAgo: 2, finalWords: 5, now: now),
        ]
        #expect(totalWords(records: records) == 40)
    }

    @Test func totalWordsEmptyIsZero() {
        #expect(totalWords(records: []) == 0)
    }

    // MARK: wpm

    @Test func wpmZeroDurationReturnsZero() {
        let now = Date()
        let records = [record(daysAgo: 0, durationSec: 0, finalWords: 50, now: now)]
        #expect(wpm(records: records) == 0)
    }

    @Test func wpmEmptyRecordsReturnsZero() {
        #expect(wpm(records: []) == 0)
    }

    @Test func wpmComputesArithmeticCorrectly() {
        let now = Date()
        // 120 words over 60 seconds (1 minute) => 120 wpm.
        let records = [record(daysAgo: 0, durationSec: 60, finalWords: 120, now: now)]
        #expect(wpm(records: records) == 120)
    }

    // MARK: wordsToNextMilestone

    @Test func milestoneZeroWordsNeedsFullThousand() {
        #expect(wordsToNextMilestone(totalWords: 0) == 1000)
    }

    @Test func milestoneOneWordNeedsAlmostThousand() {
        #expect(wordsToNextMilestone(totalWords: 1) == 999)
    }

    @Test func milestoneNineNinetyNineNeedsOneMore() {
        #expect(wordsToNextMilestone(totalWords: 999) == 1)
    }

    @Test func milestoneExactlyOneThousandNeedsFullThousandMore() {
        #expect(wordsToNextMilestone(totalWords: 1000) == 1000)
    }

    @Test func milestoneFifteenHundredNeedsFiveHundredMore() {
        #expect(wordsToNextMilestone(totalWords: 1500) == 500)
    }

    // MARK: dayStreak

    @Test func dayStreakEmptyRecordsIsZero() {
        #expect(dayStreak(records: [], now: Date()) == 0)
    }

    @Test func dayStreakGapBreaksStreakCountingOnlyTrailingRun() {
        let now = Date()
        // Dictations today, yesterday, then a gap, then 3 days ago.
        let records = [
            record(daysAgo: 0, now: now),
            record(daysAgo: 1, now: now),
            record(daysAgo: 3, now: now),
        ]
        #expect(dayStreak(records: records, now: now) == 2)
    }

    @Test func dayStreakTodayOnlyIsOne() {
        let now = Date()
        let records = [record(daysAgo: 0, now: now)]
        #expect(dayStreak(records: records, now: now) == 1)
    }

    @Test func dayStreakEndingYesterdayCountsWhenNothingToday() {
        let now = Date()
        let records = [
            record(daysAgo: 1, now: now),
            record(daysAgo: 2, now: now),
        ]
        #expect(dayStreak(records: records, now: now) == 2)
    }

    @Test func dayStreakNeitherTodayNorYesterdayIsZero() {
        let now = Date()
        let records = [record(daysAgo: 2, now: now)]
        #expect(dayStreak(records: records, now: now) == 0)
    }

    @Test func dayStreakMultipleRecordsSameDayCountAsOneDay() {
        let now = Date()
        let records = [
            record(daysAgo: 0, now: now),
            record(daysAgo: 0.1, now: now),
            record(daysAgo: 0.2, now: now),
        ]
        #expect(dayStreak(records: records, now: now) == 1)
    }
}
