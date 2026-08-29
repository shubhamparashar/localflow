import Foundation

/// Builds the post-meeting notes prompt and calls the local Ollama server.
/// Pure prompt/cleanup logic is static and unit-testable; only `generate`
/// touches the network. Uses the general summary model, never s1-mini (which
/// is a transcript normalizer and ignores instructions).
enum MeetingNotesGenerator {

    /// Keep the prompt inside a small local model's context: keep the newest
    /// tail of the transcript, which carries conclusions and action items.
    static let maxTranscriptChars = 24_000

    static func prompt(transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var body = trimmed
        var truncationNote = ""
        if body.count > maxTranscriptChars {
            body = String(body.suffix(maxTranscriptChars))
            truncationNote = "(The transcript was truncated; only the latter part is shown.)\n"
        }
        return """
        Write meeting notes from this transcript. Lines are prefixed [time] **speaker:**.
        Output exactly three markdown sections: ## Summary (3-6 bullets), \
        ## Decisions (bullets, or "None"), ## Action items (bullets with owner \
        when known, or "None"). No preamble, no other sections.
        \(truncationNote)
        Transcript:
        \(body)
        """
    }

    static func cleanResponse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Calls back on the main queue with formatted notes, or nil on any
    /// failure (Ollama down, timeout, empty output). The transcript is already
    /// safe in the Scratchpad, so failures only cost the notes section.
    static func generate(transcript: String, completion: @escaping (String?) -> Void) {
        guard let userPrompt = prompt(transcript: transcript) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Config.ollamaPort)/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let payload: [String: Any] = [
            "model": Config.summaryModel,
            "messages": [["role": "user", "content": userPrompt]],
            "stream": false,
            "options": ["temperature": 0.2],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, _, error in
            var notes: String?
            if error == nil,
               let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                notes = cleanResponse(content)
            }
            if let error {
                Log.error("Meeting notes generation failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion(notes) }
        }.resume()
    }
}
