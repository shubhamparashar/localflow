import Foundation

/// Runs a transcript through a user-configured shell command ("Dictate to
/// Claude") instead of injecting it, and hands back stdout/stderr.
enum ClaudePipe {

    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    struct RunError: Error {
        let message: String
    }

    static let envVarName = "LOCALFLOW_TEXT"

    /// Builds the zsh invocation for `command`, substituting the literal
    /// `{text}` placeholder with a quoted reference to an environment
    /// variable rather than interpolating the transcript into the shell
    /// line — so quotes/backticks/`$`/semicolons in the transcript can never
    /// be interpreted by the shell.
    static func buildInvocation(command: String, transcript: String) -> Invocation {
        let substituted = command.replacingOccurrences(of: "{text}", with: "\"$\(envVarName)\"")
        return Invocation(
            executable: "/bin/zsh",
            arguments: ["-lc", substituted],
            environment: [envVarName: transcript]
        )
    }

    /// Runs `command` against `transcript` off the main thread, killing the
    /// process if it exceeds `timeout`. Completion fires on a background
    /// queue — callers touching UI must hop back to main themselves.
    static func run(
        command: String,
        transcript: String,
        timeout: TimeInterval = 120,
        completion: @escaping (Result<String, RunError>) -> Void
    ) {
        let invocation = buildInvocation(command: command, transcript: transcript)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in invocation.environment { environment[key] = value }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let completionQueue = DispatchQueue(label: "localflow.claudepipe")
        var didComplete = false
        let completeOnce: (Result<String, RunError>) -> Void = { result in
            completionQueue.async {
                guard !didComplete else { return }
                didComplete = true
                completion(result)
            }
        }

        process.terminationHandler = { proc in
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if proc.terminationStatus == 0 {
                completeOnce(.success(out))
            } else {
                completeOnce(.failure(RunError(message: err.isEmpty ? "exit code \(proc.terminationStatus)" : err)))
            }
        }

        do {
            try process.run()
        } catch {
            completeOnce(.failure(RunError(message: error.localizedDescription)))
            return
        }

        completionQueue.asyncAfter(deadline: .now() + timeout) {
            guard !didComplete else { return }
            process.terminate()
            completeOnce(.failure(RunError(message: "timed out after \(Int(timeout))s")))
        }
    }
}
