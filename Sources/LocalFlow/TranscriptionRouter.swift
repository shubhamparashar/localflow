import Foundation

/// Picks the transcription engine per dictation: Parakeet (CoreML/ANE,
/// strongest English accuracy on spontaneous speech) when the language is
/// English and its models are loaded; whisper-server otherwise
/// (multilingual — Hindi, Hinglish, auto-detect).
enum TranscriptionRouter {
    static var activeEngineName: String {
        if Config.whisperLanguage == "en", ParakeetTranscriber.shared.isReady {
            return "Parakeet (English)"
        }
        return "whisper large-v3-turbo"
    }

    static func transcribe(wav: Data, completion: @escaping (Result<String, Error>) -> Void) {
        guard Config.whisperLanguage == "en", ParakeetTranscriber.shared.isReady else {
            Transcriber.transcribe(wav: wav, completion: completion)
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
                Transcriber.transcribe(wav: wav, completion: completion)
            }
        }
    }
}
