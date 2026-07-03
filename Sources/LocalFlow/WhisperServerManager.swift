import Foundation

/// Owns the whisper-server child process. Reuses an already-running server
/// on the configured port; otherwise spawns one and waits for it to come up
/// (the server binds its port only after the model is loaded).
final class WhisperServerManager {
    private var process: Process?
    private(set) var spawnedByUs = false

    var serverLogFile: URL {
        Log.dir.appendingPathComponent("whisper-server.log")
    }

    func ensureRunning(completion: @escaping (Bool) -> Void) {
        healthCheck { alive in
            if alive {
                Log.info("whisper-server already running on port \(Config.serverPort)")
                completion(true)
                return
            }
            self.spawnAndWait(completion: completion)
        }
    }

    func stop() {
        guard spawnedByUs, let process, process.isRunning else { return }
        process.terminate()
        Log.info("whisper-server terminated")
    }

    private func spawnAndWait(completion: @escaping (Bool) -> Void) {
        let binary = Config.whisperServerBinary
        let model = Config.modelPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            Log.error("whisper-server binary not found at \(binary) — run scripts/setup.sh")
            completion(false)
            return
        }
        guard FileManager.default.fileExists(atPath: model) else {
            Log.error("Model not found at \(model) — run scripts/setup.sh")
            completion(false)
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        var arguments = [
            "-m", model,
            "--host", "127.0.0.1",
            "--port", "\(Config.serverPort)",
        ]
        if FileManager.default.fileExists(atPath: Config.vadModelPath) {
            arguments += [
                "--vad",
                "--vad-model", Config.vadModelPath,
                "--vad-speech-pad-ms", "120",
            ]
            Log.info("Silero VAD enabled (suppresses silence hallucinations)")
        }
        proc.arguments = arguments
        FileManager.default.createFile(atPath: serverLogFile.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: serverLogFile) {
            proc.standardOutput = handle
            proc.standardError = handle
        }
        do {
            try proc.run()
        } catch {
            Log.error("Failed to launch whisper-server: \(error.localizedDescription)")
            completion(false)
            return
        }
        process = proc
        spawnedByUs = true
        Log.info("Spawned whisper-server (pid \(proc.processIdentifier)), waiting for model load…")
        pollUntilHealthy(deadline: Date().addingTimeInterval(90), completion: completion)
    }

    private func pollUntilHealthy(deadline: Date, completion: @escaping (Bool) -> Void) {
        healthCheck { alive in
            if alive {
                Log.info("whisper-server is up")
                completion(true)
                return
            }
            if let process = self.process, !process.isRunning {
                Log.error("whisper-server exited during startup — see \(self.serverLogFile.path)")
                completion(false)
                return
            }
            if Date() > deadline {
                Log.error("whisper-server did not come up within 90s")
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.pollUntilHealthy(deadline: deadline, completion: completion)
            }
        }
    }

    private func healthCheck(_ completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Config.serverPort)/")!)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let alive = response is HTTPURLResponse
            DispatchQueue.main.async { completion(alive) }
        }.resume()
    }
}
