import Foundation

/// Downloads the transcription models on first run so the app works on a
/// fresh machine with no manual setup. Progress is surfaced through
/// `status` for the menu.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    enum Status {
        case idle
        case downloading(name: String, progress: Double)
        case failed(String)
        case done
    }

    private(set) var status: Status = .idle
    var onStatusChange: (() -> Void)?

    private struct ModelSpec {
        let name: String
        let url: URL
        let destination: URL
    }

    private var queue: [ModelSpec] = []
    private var completion: ((Bool) -> Void)?
    private var currentSpec: ModelSpec?
    private lazy var session: URLSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: OperationQueue.main
    )

    private static let modelsDir = Log.dir.appendingPathComponent("models", isDirectory: true)

    /// Ensures all required models exist locally, downloading any that are
    /// missing. Calls back on the main queue.
    func ensureModels(completion: @escaping (Bool) -> Void) {
        try? FileManager.default.createDirectory(at: Self.modelsDir, withIntermediateDirectories: true)
        var missing: [ModelSpec] = []
        let whisperModel = URL(fileURLWithPath: Config.modelPath)
        if !FileManager.default.fileExists(atPath: whisperModel.path) {
            missing.append(ModelSpec(
                name: "whisper large-v3-turbo (574 MB)",
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
                destination: whisperModel
            ))
        }
        let vadModel = URL(fileURLWithPath: Config.vadModelPath)
        if !FileManager.default.fileExists(atPath: vadModel.path) {
            missing.append(ModelSpec(
                name: "silero VAD (1 MB)",
                url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
                destination: vadModel
            ))
        }
        guard !missing.isEmpty else {
            status = .done
            completion(true)
            return
        }
        Log.info("Downloading \(missing.count) missing model(s)")
        queue = missing
        self.completion = completion
        downloadNext()
    }

    private func downloadNext() {
        guard let spec = queue.first else {
            status = .done
            onStatusChange?()
            completion?(true)
            completion = nil
            return
        }
        queue.removeFirst()
        currentSpec = spec
        status = .downloading(name: spec.name, progress: 0)
        onStatusChange?()
        Log.info("Downloading \(spec.name) from \(spec.url.host ?? "")")
        let task = session.downloadTask(with: spec.url)
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let spec = currentSpec, totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        status = .downloading(name: spec.name, progress: progress)
        onStatusChange?()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let spec = currentSpec else { return }
        let http = downloadTask.response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            fail("HTTP \(http?.statusCode ?? -1) for \(spec.name)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: spec.destination)
            try FileManager.default.moveItem(at: location, to: spec.destination)
            Log.info("Downloaded \(spec.name)")
            downloadNext()
        } catch {
            fail("Could not save \(spec.name): \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        Log.error("Model download failed: \(message)")
        status = .failed(message)
        onStatusChange?()
        completion?(false)
        completion = nil
        currentSpec = nil
    }
}
