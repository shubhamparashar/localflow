import AppKit
import Foundation

/// Tone/formatting profile applied by the LLM-cleanup layer based on which
/// app is frontmost at dictation time (Wispr Flow-style context awareness).
struct AppCategoryProfile {
    let category: String          // "email" | "workChat" | "personalChat" | "code" | "other"
    let toneInstruction: String   // one sentence appended to the cleanup system prompt
    let cleanupEnabled: Bool      // code category: false (raw transcript is safer in editors/terminals)
    let stripTrailingPeriod: Bool // chat categories: true (casual style)
}

/// Maps the frontmost app's bundle identifier to a category profile via a
/// user-editable JSON file (`{ "com.tinyspeck.slackmacgap": "workChat", ... }`).
/// Missing or corrupt files fall back to the built-in mapping; unknown bundle
/// IDs and unknown category names fall back to "other".
enum AppContext {
    static var mappingFileURL: URL {
        Log.dir.appendingPathComponent("app-categories.json")
    }

    static func currentProfile() -> AppCategoryProfile {
        let bundleId = frontmostBundleId()
        return lookupProfile(bundleId: bundleId)
    }

    static func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func openInEditor() {
        ensureFileExists()
        NSWorkspace.shared.open(mappingFileURL)
    }

    static func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: mappingFileURL.path) else { return }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: builtinMapping, options: options) else { return }
        try? data.write(to: mappingFileURL, options: .atomic)
        Log.info("AppContext: created default mapping at \(mappingFileURL.path)")
    }

    // MARK: - Profiles (hardcoded per category)

    private static let otherProfile = AppCategoryProfile(
        category: "other",
        toneInstruction: "Keep the speaker's original tone; just clean up grammar and punctuation.",
        cleanupEnabled: true,
        stripTrailingPeriod: false
    )

    private static let profiles: [String: AppCategoryProfile] = [
        "email": AppCategoryProfile(
            category: "email",
            toneInstruction: "Write in a professional, well-punctuated tone suitable for email.",
            cleanupEnabled: true,
            stripTrailingPeriod: false
        ),
        "workChat": AppCategoryProfile(
            category: "workChat",
            toneInstruction: "Keep a natural, concise workplace-chat tone.",
            cleanupEnabled: true,
            stripTrailingPeriod: true
        ),
        "personalChat": AppCategoryProfile(
            category: "personalChat",
            toneInstruction: "Keep a casual, friendly tone.",
            cleanupEnabled: true,
            stripTrailingPeriod: true
        ),
        "code": AppCategoryProfile(
            category: "code",
            toneInstruction: "",
            cleanupEnabled: false,
            stripTrailingPeriod: false
        ),
        "other": otherProfile,
    ]

    // MARK: - Built-in default mapping

    static let builtinMapping: [String: String] = [
        // workChat
        "com.tinyspeck.slackmacgap": "workChat",
        "com.microsoft.teams2": "workChat",
        "com.microsoft.teams": "workChat",
        // email
        "com.apple.mail": "email",
        "com.microsoft.Outlook": "email",
        "com.readdle.smartemail-Mac": "email",
        "com.readdle.SparkDesktop": "email",
        // personalChat
        "com.apple.MobileSMS": "personalChat",
        "net.whatsapp.WhatsApp": "personalChat",
        "ru.keepcoder.Telegram": "personalChat",
        "org.whispersystems.signal-desktop": "personalChat",
        // code
        "com.apple.Terminal": "code",
        "com.googlecode.iterm2": "code",
        "com.microsoft.VSCode": "code",
        "com.todesktop.230313mzl4w4u92": "code", // Cursor
        "com.exafunction.windsurf": "code",
        "com.apple.dt.Xcode": "code",
        "com.jetbrains.intellij": "code",
        "dev.warp.Warp-Stable": "code",
        "com.mitchellh.ghostty": "code",
    ]

    // MARK: - Lookup

    static func lookupProfile(bundleId: String?) -> AppCategoryProfile {
        let mapping = loadMapping(at: mappingFileURL)
        return lookupProfile(bundleId: bundleId, mapping: mapping)
    }

    static func lookupProfile(bundleId: String?, mapping: [String: String]) -> AppCategoryProfile {
        guard let bundleId = bundleId, !bundleId.isEmpty else { return otherProfile }
        var category: String? = mapping[bundleId]
        if category == nil, bundleId.hasPrefix("com.jetbrains.") {
            // JetBrains IDEs share the prefix but vary per product (WebStorm,
            // PyCharm, GoLand, CE editions, ...) — treat them all as code.
            category = "code"
        }
        guard let resolved = category, let profile = profiles[resolved] else { return otherProfile }
        return profile
    }

    // MARK: - Mapping file (mtime-cached)

    private static let cacheLock = NSLock()
    private static var cachedMapping: [String: String]?
    private static var cachedURL: URL?
    private static var cachedMTime: Date?

    static func loadMapping(at url: URL) -> [String: String] {
        guard let mtime = modificationDate(of: url) else { return builtinMapping }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedMapping, cachedURL == url, cachedMTime == mtime {
            return cached
        }
        guard let data = try? Data(contentsOf: url), let parsed = parseMapping(data) else {
            Log.error("AppContext: could not parse \(url.path); using built-in mapping")
            return builtinMapping
        }
        cachedMapping = parsed
        cachedURL = url
        cachedMTime = mtime
        return parsed
    }

    static func parseMapping(_ data: Data) -> [String: String]? {
        let object = try? JSONSerialization.jsonObject(with: data)
        return object as? [String: String]
    }

    private static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
