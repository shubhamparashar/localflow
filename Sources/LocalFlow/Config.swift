import CoreGraphics
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

    /// How long Ollama keeps the cleanup model resident after a request.
    /// Well above the model default so dictations spread across a working
    /// session skip the multi-second cold reload on the next take.
    static var ollamaKeepAlive: String {
        defaults.string(forKey: "ollamaKeepAlive") ?? "2h"
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

    /// Keeps the Flow-Bar pill on screen while idle (click to dictate). When
    /// off, the pill only appears during recording/transcribing.
    static var showIdleHUD: Bool {
        get { defaults.object(forKey: "showIdleHUD") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showIdleHUD") }
    }

    /// Plays a short sound the moment recording starts.
    static var playStartSound: Bool {
        get { defaults.object(forKey: "playStartSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playStartSound") }
    }

    /// Boosts input gain and lowers the VAD speech threshold for quiet or
    /// whispered speech. Not a whisper-specific model — just a more
    /// sensitive capture profile.
    static var quietModeEnabled: Bool {
        get { defaults.object(forKey: "quietModeEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "quietModeEnabled") }
    }

    /// While `Date()` is before this, the idle Flow-Bar stays hidden (the
    /// "Hide for 1 hour" action); recording feedback still shows. Unset reads
    /// as the epoch, i.e. always in the past → visible.
    static var hudHiddenUntil: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "hudHiddenUntil")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "hudHiddenUntil") }
    }

    /// Set once the user drags the Flow-Bar pill. While true, the pill restores
    /// to `hudCenter` on every show (and across relaunches) instead of snapping
    /// to bottom-center. Clearing it returns the pill to the default position.
    static var hudHasCustomPosition: Bool {
        get { defaults.bool(forKey: "hudHasCustomPosition") }
        set { defaults.set(newValue, forKey: "hudHasCustomPosition") }
    }

    /// The user-chosen pill center, in global screen coordinates. Stored as the
    /// center (not the origin) so the pill stays put when it grows/shrinks
    /// between idle and recording. Only meaningful when `hudHasCustomPosition`.
    static var hudCenter: CGPoint {
        get { CGPoint(x: defaults.double(forKey: "hudCenterX"), y: defaults.double(forKey: "hudCenterY")) }
        set {
            defaults.set(newValue.x, forKey: "hudCenterX")
            defaults.set(newValue.y, forKey: "hudCenterY")
        }
    }

    /// Set once the user finishes (or dismisses) the first-run welcome, so the
    /// onboarding window appears only on the very first launch.
    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
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
