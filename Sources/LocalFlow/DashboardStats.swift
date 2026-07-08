import Foundation

struct DashboardStats {
    let todayWords: Int
    let weekWords: Int
    let avgLatencySec: Double
    let timeSavedMinutes: Double
    let p50TakeLatencySec: Double
    let p95TakeLatencySec: Double
    let speakingMinutes: Double
}

/// "N× faster than typing" — ratio of typing time (at 40wpm) to actual
/// speaking time for the same word count. Returns 0 when there's nothing to
/// compare (no words, or no time spent speaking).
func speedupMultiplier(words: Int, speakingMinutes: Double) -> Double {
    guard words > 0, speakingMinutes > 0 else { return 0 }
    let typingMinutes = Double(words) / 40.0
    return typingMinutes / speakingMinutes
}

/// Linear-interpolation percentile (matches the common "R-7" definition):
/// sorts `values`, then interpolates between the two nearest ranks rather
/// than snapping to the nearest sample. Returns 0 for an empty input.
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    guard sorted.count > 1 else { return sorted[0] }
    let rank = p * Double(sorted.count - 1)
    let lowerIndex = Int(rank.rounded(.down))
    let upperIndex = Int(rank.rounded(.up))
    let fraction = rank - Double(lowerIndex)
    return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
}

/// Pure aggregation over already-loaded records — no file I/O, so it's cheap
/// to call from the dashboard and to unit test directly.
///
/// "Today" is the calendar day containing `now`. "This week" is the 7
/// calendar days ending on that day (today plus the preceding 6), matching
/// `VoiceProfileStore.wordsPerDay`'s window. Latency and time-saved are
/// computed over the week window so they track the "this week" stats strip.
func computeDashboardStats(records: [DictationRecord], now: Date) -> DashboardStats {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    guard let weekStart = calendar.date(byAdding: .day, value: -6, to: today) else {
        return DashboardStats(
            todayWords: 0, weekWords: 0, avgLatencySec: 0, timeSavedMinutes: 0,
            p50TakeLatencySec: 0, p95TakeLatencySec: 0, speakingMinutes: 0
        )
    }

    let todayRecords = records.filter { calendar.isDate($0.ts, inSameDayAs: today) }
    let weekRecords = records.filter { $0.ts >= weekStart }

    let todayWords = todayRecords.reduce(0) { $0 + $1.finalWords }
    let weekWords = weekRecords.reduce(0) { $0 + $1.finalWords }

    let totalLatency = weekRecords.reduce(0.0) { $0 + $1.sttSeconds + ($1.cleanupSeconds ?? 0) }
    let avgLatencySec = weekRecords.isEmpty ? 0.0 : totalLatency / Double(weekRecords.count)

    let speakingMinutes = weekRecords.reduce(0.0) { $0 + $1.durationSec } / 60.0
    let typingMinutes = Double(weekWords) / 40.0
    let timeSavedMinutes = max(0.0, typingMinutes - speakingMinutes)

    let takeLatencies = weekRecords.compactMap { $0.totalLatencySec }
    let p50TakeLatencySec = percentile(takeLatencies, 0.5)
    let p95TakeLatencySec = percentile(takeLatencies, 0.95)

    return DashboardStats(
        todayWords: todayWords,
        weekWords: weekWords,
        avgLatencySec: avgLatencySec,
        timeSavedMinutes: timeSavedMinutes,
        p50TakeLatencySec: p50TakeLatencySec,
        p95TakeLatencySec: p95TakeLatencySec,
        speakingMinutes: speakingMinutes
    )
}
