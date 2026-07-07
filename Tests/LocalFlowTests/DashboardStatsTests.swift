import Foundation
import Testing
@testable import LocalFlow

@Suite
struct DashboardStatsTests {

    private func record(
        daysAgo: Double,
        durationSec: Double = 30,
        finalWords: Int = 100,
        sttSeconds: Double = 1.0,
        cleanupSeconds: Double? = 0.5,
        now: Date
    ) -> DictationRecord {
        DictationRecord(
            ts: now.addingTimeInterval(-daysAgo * 86400),
            durationSec: durationSec,
            rawWords: finalWords,
            finalWords: finalWords,
            mode: "hold",
            sttSeconds: sttSeconds,
            cleanupSeconds: cleanupSeconds,
            rawText: "",
            finalText: nil,
            app: nil
        )
    }

    @Test func recordAtExactMidnightCountsAsToday() {
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        let midnight = calendar.startOfDay(for: now)
        let records = [record(daysAgo: 0, finalWords: 50, now: midnight)]

        let stats = computeDashboardStats(records: records, now: now)

        #expect(stats.todayWords == 50)
        #expect(stats.weekWords == 50)
    }

    @Test func eightDayOldRecordExcludedFromWeek() {
        let now = Date()
        let records = [record(daysAgo: 8, finalWords: 40, now: now)]

        let stats = computeDashboardStats(records: records, now: now)

        #expect(stats.weekWords == 0)
        #expect(stats.todayWords == 0)
    }

    @Test func sixDayOldRecordIncludedInWeek() {
        let now = Date()
        let records = [record(daysAgo: 6, finalWords: 40, now: now)]

        let stats = computeDashboardStats(records: records, now: now)

        #expect(stats.weekWords == 40)
    }

    @Test func averageLatencyIsMeanOfSttPlusCleanup() {
        let now = Date()
        let records = [
            record(daysAgo: 0, sttSeconds: 1.0, cleanupSeconds: 1.0, now: now),
            record(daysAgo: 1, sttSeconds: 2.0, cleanupSeconds: nil, now: now),
        ]

        let stats = computeDashboardStats(records: records, now: now)

        // (1.0 + 1.0 + 2.0 + 0.0) / 2 records = 2.0
        #expect(stats.avgLatencySec == 2.0)
    }

    @Test func timeSavedMatchesWordsOver40WpmMinusSpeakingTime() {
        let now = Date()
        // 400 words / 40 wpm = 10 minutes typing; 300s speaking = 5 minutes.
        let records = [record(daysAgo: 0, durationSec: 300, finalWords: 400, now: now)]

        let stats = computeDashboardStats(records: records, now: now)

        #expect(stats.timeSavedMinutes == 5.0)
    }

    @Test func timeSavedNeverNegative() {
        let now = Date()
        // 40 words / 40 wpm = 1 minute typing; 300s speaking = 5 minutes.
        let records = [record(daysAgo: 0, durationSec: 300, finalWords: 40, now: now)]

        let stats = computeDashboardStats(records: records, now: now)

        #expect(stats.timeSavedMinutes == 0.0)
    }

    @Test func emptyRecordsProduceZeroedStats() {
        let stats = computeDashboardStats(records: [], now: Date())

        #expect(stats.todayWords == 0)
        #expect(stats.weekWords == 0)
        #expect(stats.avgLatencySec == 0.0)
        #expect(stats.timeSavedMinutes == 0.0)
    }
}
