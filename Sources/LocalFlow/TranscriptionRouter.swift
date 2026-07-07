import Foundation

/// Picks the transcription engine per dictation: Parakeet (CoreML/ANE,
/// strongest English accuracy on spontaneous speech) when the language is
/// English and its models are loaded; whisper-server otherwise
/// (multilingual — Hindi, Hinglish, auto-detect).
enum TranscriptionRouter {
    enum Engine: Equatable {
        case parakeet
        case whisper
    }

    /// The routing outcome for a dictation: which engine runs it, and (for
    /// whisper) which language code to decode with — `nil` means auto-detect.
    struct Decision: Equatable {
        let engine: Engine
        let whisperLanguage: String?
    }

    /// Pure decision function, no audio/network — the language selection and
    /// Parakeet readiness fully determine the route, so this is unit-testable
    /// in isolation. `auto` clears the language (auto-detect); `hinglish` is
    /// the pseudo-language handled by `Transcriber`'s English-decode + seed
    /// prompt; every other code is passed straight through to whisper.
    static func route(language: String, parakeetReady: Bool) -> Decision {
        if language == "en", parakeetReady {
            return Decision(engine: .parakeet, whisperLanguage: nil)
        }
        switch language {
        case "auto":
            return Decision(engine: .whisper, whisperLanguage: nil)
        default:
            return Decision(engine: .whisper, whisperLanguage: language)
        }
    }

    static var activeEngineName: String {
        route(language: Config.whisperLanguage, parakeetReady: ParakeetTranscriber.shared.isReady).engine == .parakeet
            ? "Parakeet (English)"
            : "whisper large-v3-turbo"
    }

    static func transcribe(wav: Data, fieldContext: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        guard route(language: Config.whisperLanguage, parakeetReady: ParakeetTranscriber.shared.isReady).engine == .parakeet else {
            Transcriber.transcribe(wav: wav, fieldContext: fieldContext, completion: completion)
            return
        }
        let started = Date()
        ParakeetTranscriber.shared.transcribe(wav: wav) { result in
            switch result {
            case .success(let text):
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
                let cleaned = Transcriber.clean(text)
                Log.info("Parakeet transcribed in \(elapsed)s: \"\(cleaned)\"")
                completion(.success(cleaned))
            case .failure(let error):
                Log.error("Parakeet failed (\(error.localizedDescription)) — falling back to whisper")
                Transcriber.transcribe(wav: wav, fieldContext: fieldContext, completion: completion)
            }
        }
    }
}
