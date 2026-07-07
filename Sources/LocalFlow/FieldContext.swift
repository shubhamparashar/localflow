import AppKit
import ApplicationServices

/// Reads the focused field's existing text via AX at dictation start, so the
/// STT prompt and cleanup pass can be biased toward what's already on the
/// page (proper nouns, in-progress sentences). Opportunistic and read-only:
/// any AX failure or unsupported app yields `nil`, matching CorrectionWatcher's
/// AX usage style.
enum FieldContext {
    static let maxLength = 500

    /// Roles/subroles whose value must never be read or logged.
    private static let secureSubroles: Set<String> = ["AXSecureTextField"]

    /// Captures up to `maxLength` chars of context around the caret in the
    /// focused field. Returns `nil` for secure fields, apps without AX
    /// support (Electron/canvas), or any AX error.
    static func capture() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let focused else { return nil }
        let element = focused as! AXUIElement

        if isSecureField(element) { return nil }

        var value: CFTypeRef?
        let valueErr = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard valueErr == .success, let text = value as? String, !text.isEmpty else { return nil }

        let caretOffset = selectedCaretOffset(element)
        let excerpt = sanitizedWindow(fullText: text, caretOffset: caretOffset, maxLength: maxLength)
        return excerpt.isEmpty ? nil : excerpt
    }

    /// True if the focused element (or its subrole) marks it as a secure
    /// field — password inputs must never have their value read.
    private static func isSecureField(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if err == .success, let subrole = subrole as? String, secureSubroles.contains(subrole) {
            return true
        }
        var role: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if roleErr == .success, let role = role as? String, role == "AXSecureTextField" {
            return true
        }
        return false
    }

    /// Best-effort caret offset from the focused element's selected-text
    /// range. `nil` when the app doesn't expose it — callers fall back to
    /// the tail of the field.
    private static func selectedCaretOffset(_ element: AXUIElement) -> Int? {
        var rangeValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        guard err == .success, let rangeValue else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Pure, testable window extraction: collapses whitespace, strips
    /// control characters, and returns at most `maxLength` chars centered on
    /// `caretOffset` (or the tail of the text when no caret is known).
    static func sanitizedWindow(fullText: String, caretOffset: Int?, maxLength: Int) -> String {
        let sanitized = fullText
            .unicodeScalars
            .filter { !$0.properties.generalCategory.isControlLike }
            .map(Character.init)
            .reduce(into: "") { $0.append($1) }
        let collapsed = sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }

        guard let caretOffset, caretOffset > 0 else {
            return String(collapsed.suffix(maxLength))
        }
        // Caret offset is measured in the original (pre-collapse) text; since
        // collapsing only removes whitespace runs, clamping it into the
        // collapsed string's bounds keeps the window roughly caret-centered
        // without needing an exact offset mapping.
        let clampedOffset = min(caretOffset, collapsed.count)
        let half = maxLength / 2
        let startIndexOffset = max(0, clampedOffset - half)
        let start = collapsed.index(collapsed.startIndex, offsetBy: startIndexOffset)
        let end = collapsed.index(start, offsetBy: maxLength, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        return String(collapsed[start..<end])
    }
}

private extension Unicode.GeneralCategory {
    var isControlLike: Bool {
        self == .control || self == .format || self == .surrogate || self == .unassigned
    }
}
