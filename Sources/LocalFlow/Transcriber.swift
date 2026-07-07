import Foundation

/// Client for the whisper.cpp server's /inference endpoint.
enum Transcriber {
    /// Total cap on the combined glossary + field-context prompt sent to
    /// whisper; well under the model's context window.
    static let maxPromptLength = 800

    static func transcribe(wav: Data, fieldContext: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        let boundary = "----LocalFlow\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Config.serverPort)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("temperature", "0.0")
        appendField("response_format", "json")
        let language = Config.whisperLanguage
        var promptParts: [String] = []
        switch language {
        case "auto":
            break
        case "hinglish":
            // Code-switched Hindi/English: decode as English but seed the
            // decoder with romanized Hindi so mixed-in Hindi words stay in
            // Latin script instead of being mangled into English or
            // switched to Devanagari.
            appendField("language", "en")
            promptParts.append("Haan, toh kal meeting hai. Main abhi office ja raha hoon. Yeh feature ready hai, theek hai?")
        default:
            appendField("language", language)
        }
        if let glossaryPrompt = Glossary.whisperPrompt() {
            promptParts.append(glossaryPrompt)
        }
        if let fieldContext, !fieldContext.isEmpty {
            promptParts.append("Context: " + fieldContext)
        }
        if !promptParts.isEmpty {
            let joined = promptParts.joined(separator: " ")
            appendField("prompt", String(joined.prefix(maxPromptLength)))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let started = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            if let error {
                Log.error("Transcription request failed after \(elapsed)s: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                Log.error("Unexpected transcription response (HTTP \(status)): \(bodyText.prefix(500))")
                let err = NSError(domain: "LocalFlow", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Unexpected response from whisper-server (HTTP \(status))",
                ])
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            let cleaned = Self.clean(text)
            Log.info("Transcribed in \(elapsed)s: \"\(cleaned)\"")
            DispatchQueue.main.async { completion(.success(cleaned)) }
        }.resume()
    }

    /// Trims whitespace, collapses whisper's segment-break newlines into
    /// single spaces, and drops non-speech markers emitted for silence or
    /// noise, e.g. "[BLANK_AUDIO]", "(wind blowing)", "*music*".
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(
            of: #"\s*\n\s*"#,
            with: " ",
            options: .regularExpression
        )
        let markerPattern = #"^[\[\(\*][^\]\)\*]*[\]\)\*]$"#
        if text.range(of: markerPattern, options: .regularExpression) != nil {
            text = ""
        }
        return text
    }
}
