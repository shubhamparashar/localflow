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

    /// Compact form for the Home tab's greeting chip, e.g. "right ⌥".
    var shortLabel: String {
        switch self {
        case .rightOption: return "right ⌥"
        case .fn: return "fn 🌐"
        }
    }
}

/// How aggressively `OllamaCleaner` rewrites a transcript. `none` skips
/// Ollama entirely; `medium` is the historical default behavior.
enum CleanupLevel: String, CaseIterable {
    case none
    case light
    case medium
    case high

    var displayName: String {
        switch self {
        case .none: return "Off (raw text)"
        case .light: return "Light (punctuation + fillers)"
        case .medium: return "Medium (default)"
        case .high: return "High (grammar + tone)"
        }
    }
}

/// Style variant layered on top of `CleanupLevel`, selectable per app
/// category (`AppCategoryProfile.styleOverride`). `nil` on a category means
/// "use the global default" — there is no free-standing global style.
enum CleanupStyle: String, CaseIterable {
    case formal
    case casual
    case code
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

    /// Global default cleanup aggressiveness; `none` bypasses Ollama entirely.
    static var cleanupLevel: CleanupLevel {
        get {
            let raw = defaults.string(forKey: "cleanupLevel") ?? ""
            return CleanupLevel(rawValue: raw) ?? .medium
        }
        set { defaults.set(newValue.rawValue, forKey: "cleanupLevel") }
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

    /// Whisper decode language: "en" (default), any code from
    /// `whisperLanguages` below, "hinglish" (English decode + romanized-Hindi
    /// seed for code-switched speech), or "auto" (detect).
    static var whisperLanguage: String {
        get { defaults.string(forKey: "whisperLanguage") ?? "en" }
        set { defaults.set(newValue, forKey: "whisperLanguage") }
    }

    /// The full whisper.cpp language table (large-v3-turbo's ~100 supported
    /// languages), code → English display name, alphabetical by name.
    /// "hinglish" and "auto" are pseudo-languages handled separately and are
    /// not part of this table.
    static let whisperLanguages: [(code: String, name: String)] = [
        ("af", "Afrikaans"), ("am", "Amharic"), ("ar", "Arabic"), ("as", "Assamese"),
        ("az", "Azerbaijani"), ("ba", "Bashkir"), ("be", "Belarusian"), ("bn", "Bengali"),
        ("bs", "Bosnian"), ("br", "Breton"), ("bg", "Bulgarian"), ("ca", "Catalan"),
        ("zh", "Chinese"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"),
        ("nl", "Dutch"), ("en", "English"), ("et", "Estonian"), ("fo", "Faroese"),
        ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"), ("ka", "Georgian"),
        ("de", "German"), ("el", "Greek"), ("gu", "Gujarati"), ("ht", "Haitian Creole"),
        ("ha", "Hausa"), ("haw", "Hawaiian"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("hu", "Hungarian"), ("is", "Icelandic"), ("id", "Indonesian"), ("it", "Italian"),
        ("ja", "Japanese"), ("jw", "Javanese"), ("kn", "Kannada"), ("kk", "Kazakh"),
        ("km", "Khmer"), ("ko", "Korean"), ("lo", "Lao"), ("la", "Latin"),
        ("lv", "Latvian"), ("ln", "Lingala"), ("lt", "Lithuanian"), ("lb", "Luxembourgish"),
        ("mk", "Macedonian"), ("mg", "Malagasy"), ("ms", "Malay"), ("ml", "Malayalam"),
        ("mt", "Maltese"), ("mi", "Maori"), ("mr", "Marathi"), ("mn", "Mongolian"),
        ("my", "Myanmar"), ("ne", "Nepali"), ("no", "Norwegian"), ("nn", "Nynorsk"),
        ("oc", "Occitan"), ("ps", "Pashto"), ("fa", "Persian"), ("pl", "Polish"),
        ("pt", "Portuguese"), ("pa", "Punjabi"), ("ro", "Romanian"), ("ru", "Russian"),
        ("sa", "Sanskrit"), ("sr", "Serbian"), ("sn", "Shona"), ("sd", "Sindhi"),
        ("si", "Sinhala"), ("sk", "Slovak"), ("sl", "Slovenian"), ("so", "Somali"),
        ("es", "Spanish"), ("su", "Sundanese"), ("sw", "Swahili"), ("sv", "Swedish"),
        ("tl", "Tagalog"), ("tg", "Tajik"), ("ta", "Tamil"), ("tt", "Tatar"),
        ("te", "Telugu"), ("th", "Thai"), ("bo", "Tibetan"), ("tr", "Turkish"),
        ("tk", "Turkmen"), ("uk", "Ukrainian"), ("ur", "Urdu"), ("uz", "Uzbek"),
        ("vi", "Vietnamese"), ("cy", "Welsh"), ("yi", "Yiddish"), ("yo", "Yoruba"),
        ("yue", "Cantonese"),
    ]

    /// Most-recently-used language codes, most-recent-first, deduped, capped
    /// at 3. Feeds the Flow-Bar pill's quick-switch menu and badge cycling.
    /// Only `setLanguage` should mutate this — every surface that changes the
    /// active language routes through it so recents stay consistent.
    static var languageRecents: [String] {
        get { defaults.stringArray(forKey: "languageRecents") ?? [] }
        set { defaults.set(newValue, forKey: "languageRecents") }
    }

    /// Single choke point for changing the active language: updates
    /// `whisperLanguage` and folds the choice into `languageRecents`.
    static func setLanguage(_ code: String) {
        whisperLanguage = code
        languageRecents = updatedRecents(languageRecents, selecting: code)
    }

    /// Pure dedupe/reorder/cap logic for `languageRecents`, extracted for testing.
    static func updatedRecents(_ recents: [String], selecting code: String, cap: Int = 3) -> [String] {
        var updated = recents.filter { $0 != code }
        updated.insert(code, at: 0)
        if updated.count > cap {
            updated.removeLast(updated.count - cap)
        }
        return updated
    }

    /// Pure cycling logic for badge clicks: the language after `current` in
    /// `recents`, wrapping around. Falls back to `current` when there's
    /// nothing to cycle through yet.
    static func nextLanguage(after current: String, in recents: [String]) -> String {
        guard !recents.isEmpty else { return current }
        if let index = recents.firstIndex(of: current) {
            return recents[(index + 1) % recents.count]
        }
        return recents[0]
    }

    /// Short badge shown on the idle Flow-Bar pill for the active language.
    static func languageBadge(for code: String) -> String {
        switch code {
        case "auto": return "A"
        case "hinglish": return "HG"
        default: return String(code.uppercased().prefix(2))
        }
    }

    /// Per-app language memory, off by default: remembers the last language
    /// used per frontmost-app bundle id and auto-switches at dictation start.
    static var perAppLanguageEnabled: Bool {
        get { defaults.bool(forKey: "perAppLanguageEnabled") }
        set { defaults.set(newValue, forKey: "perAppLanguageEnabled") }
    }

    static var perAppLanguageMap: [String: String] {
        get { defaults.dictionary(forKey: "perAppLanguageMap") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "perAppLanguageMap") }
    }

    /// Pure decision: the language (if any) dictation should switch to for
    /// `bundleId`, given whether per-app memory is enabled.
    static func perAppLanguage(enabled: Bool, map: [String: String], bundleId: String?) -> String? {
        guard enabled, let bundleId else { return nil }
        return map[bundleId]
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

    /// Blocks injection into non-code apps when the final text looks like it
    /// contains a credential (see `RedactionGuard`); the text stays on the
    /// clipboard so the user can Cmd+V deliberately.
    static var redactionGuardEnabled: Bool {
        get { defaults.object(forKey: "redactionGuardEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "redactionGuardEnabled") }
    }

    /// Boosts input gain and lowers the VAD speech threshold for quiet or
    /// whispered speech. Not a whisper-specific model — just a more
    /// sensitive capture profile.
    static var quietModeEnabled: Bool {
        get { defaults.object(forKey: "quietModeEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "quietModeEnabled") }
    }

    /// Labels each Capture Mode chunk in the Scratchpad with its dominant
    /// speaker's name via on-device diarization. Off by default so the
    /// diarization models are never downloaded unless explicitly opted in.
    static var speakerLabelsEnabled: Bool {
        get { defaults.object(forKey: "speakerLabelsEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "speakerLabelsEnabled") }
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

    /// Shows the "Open LocalFlow" dashboard automatically on every launch.
    /// Off by default so existing menu-bar-only launch behavior is unchanged.
    static var openDashboardOnLaunch: Bool {
        get { defaults.object(forKey: "openDashboardOnLaunch") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "openDashboardOnLaunch") }
    }

    /// "Dictate to Claude" route: off by default so the pill/menu items and
    /// the extra armed-take path stay invisible until explicitly enabled.
    static var claudePipeEnabled: Bool {
        get { defaults.object(forKey: "claudePipeEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "claudePipeEnabled") }
    }

    /// Shell command run with the transcript substituted for `{text}`; see
    /// `ClaudePipe.buildInvocation` for how the substitution is done safely.
    static var claudePipeCommand: String {
        get { defaults.string(forKey: "claudePipeCommand") ?? "claude -p {text}" }
        set { defaults.set(newValue, forKey: "claudePipeCommand") }
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
