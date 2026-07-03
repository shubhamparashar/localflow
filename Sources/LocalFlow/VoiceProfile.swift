import AppKit
import Foundation

/// One dictation event. `finalText` and `app` are optional so stats.jsonl
/// lines written before they existed still decode.
struct DictationRecord: Codable {
    let ts: Date
    let durationSec: Double
    let rawWords: Int
    let finalWords: Int
    let mode: String
    let sttSeconds: Double
    let cleanupSeconds: Double?
    let rawText: String
    var finalText: String?
    var app: String?
}

struct WordCount {
    let word: String
    let count: Int
}

struct DayWords {
    let label: String
    let words: Int
}

struct VoiceProfileStats {
    let totalDictations: Int
    let totalFinalWords: Int
    let totalSpeakingSec: Double
    let averageWPM: Double
    let fillerPer100RawWords: Double
    let timeSavedMinutes: Double
    let topWords: [WordCount]
    let wordsPerDay: [DayWords]
    let modeCounts: [String: Int]
}

enum VoiceProfileStore {
    static let statsFile: URL = Log.dir.appendingPathComponent("stats.jsonl")
    static let reportFile: URL = Log.dir.appendingPathComponent("voice-profile.html")

    private static let queue = DispatchQueue(label: "localflow.voiceprofile")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let fillerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\b(um|uh|er|hmm|like|you know)\\b",
        options: [.caseInsensitive]
    )

    private static let stopwords: Set<String> = [
        "that", "this", "with", "from", "have", "they", "will", "would", "there",
        "their", "what", "about", "which", "when", "your", "just", "like", "them",
        "some", "into", "than", "then", "were", "been", "more", "also", "because",
        "could", "should", "really", "going", "think", "know", "want", "need",
        "very", "over", "only", "other", "after", "before", "where", "these",
        "those", "here", "make", "made", "well", "yeah", "okay",
    ]

    // MARK: - Recording

    static func record(_ record: DictationRecord) {
        queue.async {
            guard let line: Data = encodeLine(record) else {
                Log.error("VoiceProfile: failed to encode dictation record")
                return
            }
            appendLine(line)
        }
    }

    // MARK: - Report

    static func present() {
        let records: [DictationRecord] = queue.sync { loadRecords() }
        let stats: VoiceProfileStats = computeStats(records)
        let html: String = renderHTML(stats)
        do {
            try html.write(to: reportFile, atomically: true, encoding: .utf8)
        } catch {
            Log.error("VoiceProfile: failed to write report: \(error)")
            return
        }
        NSWorkspace.shared.open(reportFile)
    }

    // MARK: - JSONL encode/decode

    static func encodeLine(_ record: DictationRecord) -> Data? {
        guard var data: Data = try? encoder.encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Decodes one record per line, silently dropping corrupt or partial lines
    /// so a crash mid-append can never poison the whole history.
    static func decodeRecords(from data: Data) -> [DictationRecord] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        var records: [DictationRecord] = []
        for line in content.split(separator: "\n") {
            let lineData = Data(line.utf8)
            if let record = try? decoder.decode(DictationRecord.self, from: lineData) {
                records.append(record)
            }
        }
        return records
    }

    // MARK: - Aggregation

    /// `now` anchors the 7-day window; injectable so aggregation is deterministic under test.
    static func computeStats(_ records: [DictationRecord], now: Date = Date()) -> VoiceProfileStats {
        let totalRawWords: Int = records.reduce(0) { $0 + $1.rawWords }
        let totalFinalWords: Int = records.reduce(0) { $0 + $1.finalWords }
        let totalSpeakingSec: Double = records.reduce(0.0) { $0 + $1.durationSec }
        let speakingMinutes: Double = totalSpeakingSec / 60.0
        let averageWPM: Double = speakingMinutes > 0 ? Double(totalRawWords) / speakingMinutes : 0.0
        let fillerCount: Int = records.reduce(0) { $0 + countFillers(in: $1.rawText) }
        let fillerPer100: Double = totalRawWords > 0
            ? Double(fillerCount) / Double(totalRawWords) * 100.0
            : 0.0
        let typingMinutes: Double = Double(totalFinalWords) / 40.0
        let timeSavedMinutes: Double = max(0.0, typingMinutes - speakingMinutes)
        var modeCounts: [String: Int] = [:]
        for record in records {
            modeCounts[record.mode, default: 0] += 1
        }
        return VoiceProfileStats(
            totalDictations: records.count,
            totalFinalWords: totalFinalWords,
            totalSpeakingSec: totalSpeakingSec,
            averageWPM: averageWPM,
            fillerPer100RawWords: fillerPer100,
            timeSavedMinutes: timeSavedMinutes,
            topWords: topWords(in: records),
            wordsPerDay: wordsPerDay(records, now: now),
            modeCounts: modeCounts
        )
    }

    static func countFillers(in text: String) -> Int {
        guard let regex = fillerRegex else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    static func topWords(in records: [DictationRecord], limit: Int = 10) -> [WordCount] {
        var counts: [String: Int] = [:]
        for record in records {
            let lowered: String = record.rawText.lowercased()
            let tokens = lowered.split(whereSeparator: { !$0.isLetter && $0 != "'" })
            for token in tokens {
                let word = String(token)
                if word.count >= 4 && !stopwords.contains(word) {
                    counts[word, default: 0] += 1
                }
            }
        }
        let sorted: [(key: String, value: Int)] = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key < rhs.key
        }
        return sorted.prefix(limit).map { WordCount(word: $0.key, count: $0.value) }
    }

    /// Returns exactly 7 entries, oldest day first, ending with `now`'s calendar day.
    static func wordsPerDay(_ records: [DictationRecord], now: Date) -> [DayWords] {
        let calendar = Calendar.current
        let today: Date = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        var days: [DayWords] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            let sameDay: [DictationRecord] = records.filter {
                calendar.isDate($0.ts, inSameDayAs: dayStart)
            }
            let words: Int = sameDay.reduce(0) { $0 + $1.finalWords }
            let label: String = formatter.string(from: dayStart)
            days.append(DayWords(label: label, words: words))
        }
        return days
    }

    // MARK: - Persistence internals

    private static func loadRecords() -> [DictationRecord] {
        guard let data = try? Data(contentsOf: statsFile) else { return [] }
        return decodeRecords(from: data)
    }

    private static func appendLine(_ line: Data) {
        if let handle = try? FileHandle(forWritingTo: statsFile) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            do {
                try line.write(to: statsFile)
            } catch {
                Log.error("VoiceProfile: failed to write stats file: \(error)")
            }
        }
    }

    // MARK: - HTML rendering

    private static func renderHTML(_ stats: VoiceProfileStats) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        let generatedAt: String = formatter.string(from: Date())
        let cards: String = renderCards(stats)
        let chart: String = renderChart(stats.wordsPerDay)
        let words: String = renderTopWords(stats.topWords)
        let modes: String = renderModes(stats.modeCounts)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>LocalFlow &mdash; Voice Profile</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background: #111318; color: #e6e8ee; font-family: system-ui, -apple-system, sans-serif; padding: 40px 20px; }
        .wrap { max-width: 860px; margin: 0 auto; }
        h1 { font-size: 28px; font-weight: 700; }
        h2 { font-size: 15px; font-weight: 600; color: #9aa0aa; text-transform: uppercase; letter-spacing: 0.08em; margin: 36px 0 14px; }
        .sub { color: #9aa0aa; font-size: 13px; margin-top: 6px; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-top: 24px; }
        .card { background: #1c1f26; border: 1px solid #2a2e38; border-radius: 12px; padding: 16px; }
        .card .value { font-size: 24px; font-weight: 700; color: #7aa2f7; }
        .card .label { font-size: 12px; color: #9aa0aa; margin-top: 4px; }
        .chart { display: flex; align-items: flex-end; gap: 10px; background: #1c1f26; border: 1px solid #2a2e38; border-radius: 12px; padding: 20px; }
        .bar-col { flex: 1; display: flex; flex-direction: column; justify-content: flex-end; align-items: center; height: 200px; }
        .bar { width: 100%; max-width: 56px; background: linear-gradient(180deg, #7aa2f7, #3d5aa9); border-radius: 6px 6px 2px 2px; }
        .bar-val { font-size: 12px; color: #9aa0aa; margin-bottom: 6px; }
        .bar-label { font-size: 12px; color: #9aa0aa; margin-top: 8px; }
        .topwords { list-style: none; counter-reset: rank; }
        .topwords li { display: flex; align-items: center; gap: 12px; background: #1c1f26; border: 1px solid #2a2e38; border-radius: 8px; padding: 8px 14px; margin-bottom: 6px; counter-increment: rank; }
        .topwords li::before { content: counter(rank); color: #5a5f6b; font-size: 12px; width: 18px; }
        .topwords .w { flex: 1; font-weight: 600; }
        .topwords .c { color: #7aa2f7; font-variant-numeric: tabular-nums; }
        .modes { display: flex; gap: 12px; flex-wrap: wrap; }
        .mode { background: #1c1f26; border: 1px solid #2a2e38; border-radius: 8px; padding: 10px 16px; font-size: 14px; }
        .mode b { color: #7aa2f7; margin-left: 8px; }
        .empty { color: #5a5f6b; font-size: 14px; }
        </style>
        </head>
        <body>
        <div class="wrap">
        <h1>Voice Profile</h1>
        <p class="sub">Generated \(generatedAt) &middot; all data stays on this Mac</p>
        \(cards)
        <h2>Words per day &mdash; last 7 days</h2>
        \(chart)
        <h2>Top words</h2>
        \(words)
        <h2>Modes</h2>
        \(modes)
        </div>
        </body>
        </html>
        """
    }

    private static func renderCards(_ stats: VoiceProfileStats) -> String {
        let wpm: String = String(format: "%.1f", stats.averageWPM)
        let filler: String = String(format: "%.1f", stats.fillerPer100RawWords)
        let speaking: String = formatDuration(stats.totalSpeakingSec)
        let saved: String = formatDuration(stats.timeSavedMinutes * 60.0)
        var html: String = "<div class=\"cards\">"
        html += statCard(value: "\(stats.totalDictations)", label: "Dictations")
        html += statCard(value: "\(stats.totalFinalWords)", label: "Words dictated")
        html += statCard(value: speaking, label: "Speaking time")
        html += statCard(value: wpm, label: "Average WPM")
        html += statCard(value: filler, label: "Fillers per 100 words")
        html += statCard(value: saved, label: "Saved vs typing at 40 WPM")
        html += "</div>"
        return html
    }

    private static func statCard(value: String, label: String) -> String {
        return "<div class=\"card\"><div class=\"value\">\(value)</div><div class=\"label\">\(label)</div></div>"
    }

    private static func renderChart(_ days: [DayWords]) -> String {
        let maxWords: Int = max(days.map { $0.words }.max() ?? 0, 1)
        var html: String = "<div class=\"chart\">"
        for day in days {
            let scaled: Int = Int(Double(day.words) / Double(maxWords) * 150.0)
            let height: Int = day.words == 0 ? 2 : max(6, scaled)
            html += "<div class=\"bar-col\">"
            html += "<div class=\"bar-val\">\(day.words)</div>"
            html += "<div class=\"bar\" style=\"height:\(height)px\"></div>"
            html += "<div class=\"bar-label\">\(escapeHTML(day.label))</div>"
            html += "</div>"
        }
        html += "</div>"
        return html
    }

    private static func renderTopWords(_ words: [WordCount]) -> String {
        if words.isEmpty {
            return "<p class=\"empty\">No words recorded yet.</p>"
        }
        var html: String = "<ol class=\"topwords\">"
        for entry in words {
            let word: String = escapeHTML(entry.word)
            html += "<li><span class=\"w\">\(word)</span><span class=\"c\">\(entry.count)</span></li>"
        }
        html += "</ol>"
        return html
    }

    private static func renderModes(_ modeCounts: [String: Int]) -> String {
        if modeCounts.isEmpty {
            return "<p class=\"empty\">No dictations recorded yet.</p>"
        }
        let sorted: [(key: String, value: Int)] = modeCounts.sorted { $0.value > $1.value }
        var html: String = "<div class=\"modes\">"
        for entry in sorted {
            let mode: String = escapeHTML(entry.key)
            html += "<div class=\"mode\">\(mode)<b>\(entry.value)</b></div>"
        }
        html += "</div>"
        return html
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total: Int = Int(seconds.rounded())
        let hours: Int = total / 3600
        let minutes: Int = (total % 3600) / 60
        let secs: Int = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    private static func escapeHTML(_ text: String) -> String {
        var escaped: String = text
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        return escaped
    }
}
