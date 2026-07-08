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
        totalLatencySec: Double? = nil,
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
            app: nil,
            totalLatencySec: totalLatencySec
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
        #expect(stats.p50TakeLatencySec == 0.0)
        #expect(stats.p95TakeLatencySec == 0.0)
    }

    @Test func takeLatencyPercentilesSkipRecordsWithoutLatency() {
        let now = Date()
        let records = [
            record(daysAgo: 0, totalLatencySec: 1.0, now: now),
            record(daysAgo: 0, totalLatencySec: 2.0, now: now),
            record(daysAgo: 0, totalLatencySec: nil, now: now),
        ]

        let stats = computeDashboardStats(records: records, now: now)

        #expect(stats.p50TakeLatencySec == 1.5)
    }
}

@Suite
struct DictationRecordDecodeTests {
    @Test func decodesLineWithTotalLatencySec() {
        let json = """
        {"ts":"2026-01-01T00:00:00Z","durationSec":5,"rawWords":10,"finalWords":10,\
        "mode":"hold","sttSeconds":1.0,"cleanupSeconds":null,"rawText":"hi","totalLatencySec":2.5}
        """
        let records = VoiceProfileStore.decodeRecords(from: Data(json.utf8))
        #expect(records.count == 1)
        #expect(records.first?.totalLatencySec == 2.5)
    }

    @Test func decodesOldFormatLineMissingTotalLatencySec() {
        let json = """
        {"ts":"2026-01-01T00:00:00Z","durationSec":5,"rawWords":10,"finalWords":10,\
        "mode":"hold","sttSeconds":1.0,"cleanupSeconds":null,"rawText":"hi"}
        """
        let records = VoiceProfileStore.decodeRecords(from: Data(json.utf8))
        #expect(records.count == 1)
        #expect(records.first?.totalLatencySec == nil)
    }
}

@Suite
struct SpeedupMultiplierTests {
    @Test func zeroWordsReturnsZero() {
        #expect(speedupMultiplier(words: 0, speakingMinutes: 5) == 0)
    }

    @Test func zeroSpeakingMinutesReturnsZero() {
        #expect(speedupMultiplier(words: 100, speakingMinutes: 0) == 0)
    }

    @Test func computesRatioOfTypingToSpeakingTime() {
        // 400 words at 40wpm typing = 10 minutes; spoken in 2 minutes -> 5x.
        #expect(abs(speedupMultiplier(words: 400, speakingMinutes: 2) - 5.0) < 0.0001)
    }
}

@Suite
struct PercentileTests {
    @Test func emptyArrayReturnsZero() {
        #expect(percentile([], 0.5) == 0)
    }

    @Test func singleElementArrayReturnsThatElement() {
        #expect(percentile([3.0], 0.95) == 3.0)
    }

    @Test func interpolatesBetweenNearestRanks() {
        // Sorted [1, 2, 3, 4], p95 rank = 0.95 * 3 = 2.85 -> interpolate
        // between index 2 (3.0) and index 3 (4.0) at fraction 0.85.
        let values = [4.0, 1.0, 3.0, 2.0]
        #expect(abs(percentile(values, 0.95) - 3.85) < 0.0001)
    }
}
