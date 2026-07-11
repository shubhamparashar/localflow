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

    /// The engine actually run by `transcribe()`, which layers an Apple Speech
    /// fallback on top of `route()` without changing the pure decision above.
    enum RunEngine: Equatable {
        case parakeet
        case appleSpeech
        case whisper
    }

    /// Pure fallback-engine selection. When English would route to Parakeet but
    /// its models aren't loaded yet, prefer on-device Apple Speech (if
    /// available) over whisper, which may also still be downloading. Every
    /// other case defers to `route()`. Testable in isolation.
    static func runEngine(language: String, parakeetReady: Bool, appleSpeechAvailable: Bool) -> RunEngine {
        if language == "en", parakeetReady {
            return .parakeet
        }
        if language == "en", !parakeetReady, appleSpeechAvailable {
            return .appleSpeech
        }
        return .whisper
    }

    static var activeEngineName: String {
        route(language: Config.whisperLanguage, parakeetReady: ParakeetTranscriber.shared.isReady).engine == .parakeet
            ? "Parakeet (English)"
            : "whisper large-v3-turbo"
    }

    static func transcribe(
        wav: Data,
        fieldContext: String? = nil,
        languageOverride: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Every engine's output goes through the decode-loop collapse — a
        // single choke point so repetition artifacts never reach injection,
        // cleanup, or capture notes.
        let deliver: (Result<String, Error>) -> Void = { result in
            completion(result.map { text in
                Transcriber.collapseRepeatedClauses(Transcriber.collapseRepeatedSentences(text))
            })
        }
        let language = languageOverride ?? Config.whisperLanguage
        let whisper = {
            Transcriber.transcribe(wav: wav, fieldContext: fieldContext, languageOverride: languageOverride, completion: deliver)
        }
        let engine = runEngine(
            language: language,
            parakeetReady: ParakeetTranscriber.shared.isReady,
            appleSpeechAvailable: AppleSpeechTranscriber.shared.isAvailable
        )
        switch engine {
        case .whisper:
            whisper()
        case .appleSpeech:
            Log.info("Parakeet not ready — falling back to Apple Speech")
            AppleSpeechTranscriber.shared.transcribe(wav: wav) { result in
                switch result {
                case .success(let text) where !text.isEmpty:
                    deliver(.success(Transcriber.clean(text)))
                case .success:
                    Log.info("Apple Speech returned empty — falling back to whisper")
                    whisper()
                case .failure(let error):
                    Log.error("Apple Speech failed (\(error.localizedDescription)) — falling back to whisper")
                    whisper()
                }
            }
        case .parakeet:
            let started = Date()
            ParakeetTranscriber.shared.transcribe(wav: wav) { result in
                switch result {
                case .success(let text):
                    let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
                    let cleaned = Transcriber.clean(text)
                    Log.info("Parakeet transcribed in \(elapsed)s: \"\(cleaned)\"")
                    deliver(.success(cleaned))
                case .failure(let error):
                    Log.error("Parakeet failed (\(error.localizedDescription)) — falling back to whisper")
                    whisper()
                }
            }
        }
    }
}
