import Foundation

struct SecretMatch {
    let kind: String
    let range: Range<String.Index>
}

/// Pure regex scan for credential-shaped strings, run before injecting a
/// dictation into a non-code app so an accidentally read-aloud (or
/// clipboard-leaked) secret isn't pasted into chat/email. Detection only —
/// the caller decides what to do with matches.
enum RedactionGuard {
    /// kind → pattern. The generic rule only fires when a secret-ish keyword
    /// appears within ~20 chars before a long hex/base64 blob (which must
    /// contain a digit), so ordinary long words and URLs stay unflagged.
    private static let patterns: [(kind: String, regex: NSRegularExpression)] = [
        ("github-token", regex(#"\b(?:ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{20,}"#)),
        ("aws-access-key", regex(#"\bAKIA[0-9A-Z]{16}\b"#)),
        ("api-key", regex(#"\bsk-[A-Za-z0-9_-]{20,}"#)),
        ("slack-token", regex(#"\bxox[baprs]-[A-Za-z0-9-]{10,}"#)),
        ("jwt", regex(#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"#)),
        ("private-key", regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#)),
        ("generic-secret", regex(#"(?i)(?:secret|token|password|api[_-]?key).{0,20}?(?=[A-Za-z0-9+/=]*\d)([A-Fa-f0-9]{32,}|[A-Za-z0-9+/=]{32,})\b"#)),
    ]

    static func findSecrets(in text: String) -> [SecretMatch] {
        let fullRange = NSRange(text.startIndex..., in: text)
        var matches: [SecretMatch] = []
        for (kind, regex) in patterns {
            let found = regex.matches(in: text, range: fullRange)
            for match in found {
                if let range = Range(match.range, in: text) {
                    matches.append(SecretMatch(kind: kind, range: range))
                }
            }
        }
        return matches
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time literals; a failure here is a programmer error.
        try! NSRegularExpression(pattern: pattern)
    }
}
