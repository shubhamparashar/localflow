import Foundation

struct DashboardStats {
    let todayWords: Int
    let weekWords: Int
    let avgLatencySec: Double
    let timeSavedMinutes: Double
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
        return DashboardStats(todayWords: 0, weekWords: 0, avgLatencySec: 0, timeSavedMinutes: 0)
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

    return DashboardStats(
        todayWords: todayWords,
        weekWords: weekWords,
        avgLatencySec: avgLatencySec,
        timeSavedMinutes: timeSavedMinutes
    )
}
