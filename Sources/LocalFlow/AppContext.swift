import AppKit
import Foundation

/// Tone/formatting profile applied by the LLM-cleanup layer based on which
/// app is frontmost at dictation time (Wispr Flow-style context awareness).
struct AppCategoryProfile {
    let category: String                  // "email" | "workChat" | "personalChat" | "code" | "other"
    let toneInstruction: String           // one sentence appended to the cleanup system prompt
    let cleanupEnabled: Bool              // false disables cleanup entirely for the category
    let stripTrailingPeriod: Bool         // chat categories: true (casual style)
    var styleOverride: CleanupStyle? = nil // per-category cleanup style; nil = use the global default

    /// Copy with `styleOverride` replaced, used when the mapping file pins a
    /// style for this bundle ID. A `nil` argument leaves the profile's own
    /// default untouched (e.g. the code category's built-in `.code` style).
    func withStyleOverride(_ style: CleanupStyle?) -> AppCategoryProfile {
        guard let style else { return self }
        return AppCategoryProfile(
            category: category,
            toneInstruction: toneInstruction,
            cleanupEnabled: cleanupEnabled,
            stripTrailingPeriod: stripTrailingPeriod,
            styleOverride: style
        )
    }
}

/// One entry of the user-editable mapping file: a category, plus an optional
/// per-app cleanup style override.
struct CategoryMappingEntry {
    let category: String
    let style: CleanupStyle?
}

/// Maps the frontmost app's bundle identifier to a category profile via a
/// user-editable JSON file. Each value is either a plain category string
/// (`{ "com.tinyspeck.slackmacgap": "workChat" }`) or an object pinning a
/// style override (`{ "com.apple.Terminal": { "category": "code", "style": "code" } }`).
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
            cleanupEnabled: true,
            stripTrailingPeriod: false,
            styleOverride: .code
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

    static func lookupProfile(bundleId: String?, mapping: [String: CategoryMappingEntry]) -> AppCategoryProfile {
        guard let bundleId = bundleId, !bundleId.isEmpty else { return otherProfile }
        var entry = mapping[bundleId]
        if entry == nil, bundleId.hasPrefix("com.jetbrains.") {
            // JetBrains IDEs share the prefix but vary per product (WebStorm,
            // PyCharm, GoLand, CE editions, ...) — treat them all as code.
            entry = CategoryMappingEntry(category: "code", style: nil)
        }
        guard let resolved = entry, let profile = profiles[resolved.category] else { return otherProfile }
        return profile.withStyleOverride(resolved.style)
    }

    // MARK: - Mapping file (mtime-cached)

    private static let cacheLock = NSLock()
    private static var cachedMapping: [String: CategoryMappingEntry]?
    private static var cachedURL: URL?
    private static var cachedMTime: Date?

    private static var builtinMappingEntries: [String: CategoryMappingEntry] {
        builtinMapping.mapValues { CategoryMappingEntry(category: $0, style: nil) }
    }

    static func loadMapping(at url: URL) -> [String: CategoryMappingEntry] {
        guard let mtime = modificationDate(of: url) else { return builtinMappingEntries }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedMapping, cachedURL == url, cachedMTime == mtime {
            return cached
        }
        guard let data = try? Data(contentsOf: url), let parsed = parseMapping(data) else {
            Log.error("AppContext: could not parse \(url.path); using built-in mapping")
            return builtinMappingEntries
        }
        cachedMapping = parsed
        cachedURL = url
        cachedMTime = mtime
        return parsed
    }

    /// Accepts either `{ "bundleId": "category" }` or
    /// `{ "bundleId": { "category": "...", "style": "formal|casual|code" } }`.
    static func parseMapping(_ data: Data) -> [String: CategoryMappingEntry]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [String: CategoryMappingEntry] = [:]
        for (bundleId, value) in object {
            if let category = value as? String {
                result[bundleId] = CategoryMappingEntry(category: category, style: nil)
            } else if let fields = value as? [String: String], let category = fields["category"] {
                let style = fields["style"].flatMap(CleanupStyle.init(rawValue:))
                result[bundleId] = CategoryMappingEntry(category: category, style: style)
            }
        }
        return result
    }

    private static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
