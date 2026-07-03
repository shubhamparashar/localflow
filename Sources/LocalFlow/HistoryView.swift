import AppKit
import Foundation

/// Renders the dictation history (raw vs AI-cleaned, most recent first) as
/// a local HTML page — the "undo AI edit" escape hatch: any cleanup
/// mistake can be recovered by copying the raw transcript.
enum HistoryView {
    private static let maxEntries = 50
    private static let window = HTMLReportWindow(
        title: "LocalFlow History",
        size: NSSize(width: 820, height: 640)
    )

    static func present() {
        let records = loadRecords().suffix(maxEntries).reversed()
        let html = render(Array(records))
        window.show(html: html)
    }

    private static func loadRecords() -> [DictationRecord] {
        guard let data = try? Data(contentsOf: VoiceProfileStore.statsFile) else { return [] }
        return VoiceProfileStore.decodeRecords(from: data)
    }

    private static func render(_ records: [DictationRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        let entries = records.map { record -> String in
            let time = formatter.string(from: record.ts)
            let cleaned = record.finalText ?? ""
            let raw = record.rawText
            let showRaw = !cleaned.isEmpty && cleaned != raw
            let meta = [
                time,
                record.app.map { "→ \($0)" },
                record.mode,
                "\(record.finalWords)w",
                String(format: "stt %.1fs", record.sttSeconds),
                record.cleanupSeconds.map { String(format: "cleanup %.1fs", $0) },
            ].compactMap { $0 }.joined(separator: " · ")
            var blocks = block(label: showRaw ? "Final (AI-cleaned)" : "Transcript", text: cleaned.isEmpty ? raw : cleaned)
            if showRaw {
                blocks += block(label: "Raw (as spoken)", text: raw)
            }
            return "<div class=\"entry\"><div class=\"meta\">\(escape(meta))</div>\(blocks)</div>"
        }.joined()

        let body = records.isEmpty
            ? "<p class=\"empty\">No dictations recorded yet — hold your hotkey and speak.</p>"
            : entries
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>LocalFlow History</title><style>
        body { font-family: -apple-system, system-ui; background: #111418; color: #e8eaed; margin: 0 auto; max-width: 780px; padding: 32px 20px; }
        h1 { font-size: 22px; } .sub { color: #9aa0a6; font-size: 13px; margin-bottom: 24px; }
        .entry { background: #1b1f24; border-radius: 10px; padding: 14px 16px; margin-bottom: 14px; }
        .meta { color: #9aa0a6; font-size: 12px; margin-bottom: 8px; }
        .label { color: #8ab4f8; font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; margin: 8px 0 4px; display: flex; justify-content: space-between; }
        .text { white-space: pre-wrap; font-size: 14px; line-height: 1.45; }
        .raw .text { color: #b8bcc2; }
        button { background: #2b3138; color: #e8eaed; border: none; border-radius: 6px; padding: 2px 10px; font-size: 11px; cursor: pointer; }
        button:hover { background: #3a424b; }
        .empty { color: #9aa0a6; }
        </style></head><body>
        <h1>Dictation History</h1>
        <div class="sub">Last \(records.count) dictations · newest first · "Copy raw" recovers your exact words when the AI cleanup got it wrong</div>
        \(body)
        <script>
        function cp(btn) {
            const text = btn.closest('section').querySelector('.text').innerText;
            const ta = document.createElement('textarea');
            ta.value = text; document.body.appendChild(ta); ta.select();
            document.execCommand('copy'); document.body.removeChild(ta);
            btn.textContent = 'Copied ✓'; setTimeout(() => btn.textContent = 'Copy', 1200);
        }
        </script>
        </body></html>
        """
    }

    private static func block(label: String, text: String) -> String {
        let cls = label.hasPrefix("Raw") ? "raw" : "final"
        return """
        <section class="\(cls)"><div class="label"><span>\(escape(label))</span><button onclick="cp(this)">Copy</button></div><div class="text">\(escape(text))</div></section>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
