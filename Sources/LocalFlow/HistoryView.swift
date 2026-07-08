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
        window.show(html: html())
    }

    /// Renders the current history as HTML, for embedding in the dashboard's
    /// History tab (or any other in-app WKWebView).
    static func html() -> String {
        let records = loadRecords().suffix(maxEntries).reversed()
        return render(Array(records))
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
            let searchText = escape((cleaned + " " + raw).lowercased())
            return "<div class=\"entry\" data-search=\"\(searchText)\"><div class=\"meta\">\(escape(meta))</div>\(blocks)</div>"
        }.joined()

        let body = records.isEmpty
            ? "<p class=\"empty\">No dictations recorded yet — hold your hotkey and speak.</p>"
            : entries
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>LocalFlow History</title><style>
        :root {
            --bg: #f5f5f7; --fg: #1d1d1f; --sub: #6e6e73; --card: #ffffff; --border: #e5e5e7;
            --accent: #0066cc; --btn: #eceef1; --btn-hover: #dfe2e6; --raw: #6e6e73;
        }
        @media (prefers-color-scheme: dark) {
            :root { --bg: #1e1e1e; --fg: #e8eaed; --sub: #9aa0a6; --card: #262626; --border: #3a3a3c;
                --accent: #8ab4f8; --btn: #2b3138; --btn-hover: #3a424b; --raw: #b8bcc2; }
        }
        * { box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            background: var(--bg); color: var(--fg); margin: 0 auto; max-width: 780px; padding: 32px 20px; }
        h1 { font-size: 22px; } .sub { color: var(--sub); font-size: 13px; margin-bottom: 24px; }
        .entry { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 14px 16px; margin-bottom: 14px; }
        .meta { color: var(--sub); font-size: 12px; margin-bottom: 8px; }
        .label { color: var(--accent); font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; margin: 8px 0 4px; display: flex; justify-content: space-between; }
        .text { white-space: pre-wrap; font-size: 14px; line-height: 1.45; }
        .raw .text { color: var(--raw); }
        button { background: var(--btn); color: var(--fg); border: none; border-radius: 6px; padding: 2px 10px; font-size: 11px; cursor: pointer; }
        button:hover { background: var(--btn-hover); }
        .empty { color: var(--sub); }
        #search { width: 100%; background: var(--card); border: 1px solid var(--border); color: var(--fg);
            border-radius: 10px; padding: 9px 14px; font-size: 13px; margin-bottom: 16px; }
        #search:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 25%, transparent); }
        #noResults { display: none; color: var(--sub); }
        </style></head><body>
        <h1>Dictation History</h1>
        <div class="sub">Last \(records.count) dictations · newest first · "Copy raw" recovers your exact words when the AI cleanup got it wrong</div>
        <input id="search" type="search" placeholder="Search history…" oninput="filterHistory(this.value)">
        <p id="noResults">No dictations match your search.</p>
        \(body)
        <script>
        function cp(btn) {
            const text = btn.closest('section').querySelector('.text').innerText;
            const ta = document.createElement('textarea');
            ta.value = text; document.body.appendChild(ta); ta.select();
            document.execCommand('copy'); document.body.removeChild(ta);
            btn.textContent = 'Copied ✓'; setTimeout(() => btn.textContent = 'Copy', 1200);
        }
        function filterHistory(query) {
            const needle = query.trim().toLowerCase();
            const entries = document.querySelectorAll('.entry');
            let visible = 0;
            entries.forEach(entry => {
                const match = needle === '' || (entry.dataset.search || '').includes(needle);
                entry.style.display = match ? '' : 'none';
                if (match) visible++;
            });
            document.getElementById('noResults').style.display = (visible === 0 && entries.length > 0) ? '' : 'none';
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
