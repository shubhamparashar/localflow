import Foundation

enum HotkeyChoice: String, CaseIterable {
    case rightOption
    case fn

    var displayName: String {
        switch self {
        case .rightOption: return "Hold Right Option (⌥)"
        case .fn: return "Hold Fn (🌐)"
        }
    }
}

enum Config {
    private static let defaults = UserDefaults.standard

    static var hotkey: HotkeyChoice {
        get {
            let raw = defaults.string(forKey: "hotkey") ?? ""
            return HotkeyChoice(rawValue: raw) ?? .rightOption
        }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var serverPort: Int {
        let port = defaults.integer(forKey: "serverPort")
        return port == 0 ? 8178 : port
    }

    static var modelPath: String {
        if let custom = defaults.string(forKey: "modelPath"), !custom.isEmpty {
            return custom
        }
        return Log.dir.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin").path
    }

    static var cleanupEnabled: Bool {
        get { defaults.object(forKey: "cleanupEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "cleanupEnabled") }
    }

    static var ollamaModel: String {
        defaults.string(forKey: "ollamaModel") ?? "llama3.2:3b"
    }

    static var ollamaPort: Int {
        let port = defaults.integer(forKey: "ollamaPort")
        return port == 0 ? 11434 : port
    }

    /// Whisper decode language: "en" (default), "hi", "hinglish"
    /// (English decode + romanized-Hindi seed for code-switched speech),
    /// or "auto" (detect).
    static var whisperLanguage: String {
        get { defaults.string(forKey: "whisperLanguage") ?? "en" }
        set { defaults.set(newValue, forKey: "whisperLanguage") }
    }

    static var handsFreeEnabled: Bool {
        get { defaults.object(forKey: "handsFreeEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "handsFreeEnabled") }
    }

    /// Appends a space after injected text so consecutive dictations don't
    /// run together ("…see.Can you…").
    static var smartSpacing: Bool {
        get { defaults.object(forKey: "smartSpacing") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "smartSpacing") }
    }

    static var vadModelPath: String {
        Log.dir.appendingPathComponent("models/ggml-silero-v5.1.2.bin").path
    }

    static var whisperServerBinary: String {
        if let custom = defaults.string(forKey: "whisperServerBinary"), !custom.isEmpty {
            return custom
        }
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/whisper-server").path {
            candidates.append(bundled)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
        ])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return candidates.last ?? "/opt/homebrew/bin/whisper-server"
    }
}
