// Portions adapted from FluidVoice (https://github.com/altic-dev/FluidVoice), commit 1698a31, Apache License 2.0.

import AppKit
import ApplicationServices

/// Inserts text into the focused app via a degrading cascade: a PID-targeted
/// bulk-unicode CGEvent (fastest, no clipboard), then AX insert-at-cursor,
/// then the clipboard+Cmd+V path (snapshot the pasteboard, synthesize Cmd+V,
/// restore), then char-by-char CGEvents as a last resort. Each tier is tried
/// in turn until one reports success.
final class TextInjector {
    private(set) var lastTranscript: String?

    private static let restoreDelay: TimeInterval = 0.35
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8
    /// A single CGEvent can only carry a bounded unicode string; longer text
    /// must go through the clipboard tier instead.
    private static let cgEventUnicodeLimit = 200

    /// One rung of the injection cascade, ordered fastest-to-most-compatible.
    enum Tier: String {
        case pidUnicode      // bulk-unicode CGEvent posted to a specific PID
        case axInsert        // set kAXSelectedText/kAXValue on the focused element
        case clipboardPaste  // pasteboard snapshot + synthetic Cmd+V + restore
        case charByChar      // per-character CGEvents
    }

    /// Pure tier-selection: given the available signals, the ordered list of
    /// tiers to attempt. Empty means injection can't proceed (AX not granted)
    /// and the caller should leave the text on the clipboard for a manual
    /// paste. Testable in isolation — no CGEvent/AX side effects.
    static func cascade(axTrusted: Bool, targetPidValid: Bool, textFitsCGEvent: Bool) -> [Tier] {
        guard axTrusted else { return [] }
        var tiers: [Tier] = []
        if targetPidValid, textFitsCGEvent { tiers.append(.pidUnicode) }
        tiers.append(.axInsert)
        tiers.append(.clipboardPaste)
        tiers.append(.charByChar)
        return tiers
    }

    func inject(_ rawText: String, targetPid: pid_t? = nil) {
        let text = Config.smartSpacing && !rawText.hasSuffix(" ") ? rawText + " " : rawText
        lastTranscript = text
        let pasteboard = NSPasteboard.general

        let pidValid = (targetPid ?? 0) > 0
        let fits = text.utf16.count <= Self.cgEventUnicodeLimit
        let tiers = Self.cascade(axTrusted: AXIsProcessTrusted(), targetPidValid: pidValid, textFitsCGEvent: fits)

        guard !tiers.isEmpty else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            Log.error("Accessibility not granted — transcript left on clipboard (Cmd+V manually)")
            return
        }

        for tier in tiers where run(tier, text: text, targetPid: targetPid, pasteboard: pasteboard) {
            Log.info("Injected \(text.count) chars via tier \(tier.rawValue)")
            return
        }
        Log.error("All injection tiers failed — transcript left on clipboard")
    }

    private func run(_ tier: Tier, text: String, targetPid: pid_t?, pasteboard: NSPasteboard) -> Bool {
        switch tier {
        case .pidUnicode:
            guard let pid = targetPid, pid > 0 else { return false }
            return Self.postUnicodeBulk(text, targetPid: pid)
        case .axInsert:
            return Self.insertAtCursorViaAX(text, targetPid: targetPid)
        case .clipboardPaste:
            return pasteViaClipboard(text, pasteboard: pasteboard)
        case .charByChar:
            Self.typeCharByChar(text)
            return true
        }
    }

    private func pasteViaClipboard(_ text: String, pasteboard: NSPasteboard) -> Bool {
        let snapshot = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        guard Self.postKey(Self.vKeyCode, flags: .maskCommand) else {
            Log.error("Failed to synthesize Cmd+V")
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            Self.restore(pasteboard, items: snapshot)
        }
        return true
    }

    /// Copies the current selection in the focused app (synthetic Cmd+C)
    /// without disturbing the user's clipboard. Calls back with nil when
    /// nothing was selected.
    func captureSelection(completion: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else {
            Log.error("Accessibility not granted — cannot capture selection")
            completion(nil)
            return
        }
        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(pasteboard)
        let beforeCount = pasteboard.changeCount

        guard Self.postKey(Self.cKeyCode, flags: .maskCommand) else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let copied = pasteboard.changeCount != beforeCount
                ? pasteboard.string(forType: .string)
                : nil
            Self.restore(pasteboard, items: snapshot)
            completion((copied?.isEmpty ?? true) ? nil : copied)
        }
    }

    /// Repositions the caret after a paste by sending left-arrow key events
    /// (used by snippet `{cursor}` slots). Capped — a runaway count would
    /// visibly walk the caret across the document.
    func moveCaretLeft(_ count: Int) {
        guard AXIsProcessTrusted(), count > 0 else { return }
        let leftArrowKeyCode: CGKeyCode = 123
        for _ in 0..<min(count, 200) {
            _ = Self.postKey(leftArrowKeyCode, flags: [])
        }
    }

    /// Escape hatch for terminals/SSH/tmux where synthetic paste fails:
    /// re-injects the most recent transcript.
    func pasteLastTranscript() {
        guard let lastTranscript else { return }
        inject(lastTranscript)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var flavors: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    flavors[type] = data
                }
            }
            return flavors
        }
    }

    private static func restore(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let restored = items.map { flavors -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in flavors {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Posts the whole string as a single unicode CGEvent pair aimed at a
    /// specific process — no clipboard, no per-key events. Reliable for
    /// terminals and Electron apps that swallow synthetic paste.
    private static func postUnicodeBulk(_ text: String, targetPid: pid_t) -> Bool {
        let utf16 = Array(text.utf16)
        guard utf16.count <= cgEventUnicodeLimit,
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return false }
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.postToPid(targetPid)
        usleep(2000)
        keyUp.postToPid(targetPid)
        return true
    }

    /// Inserts text at the caret of the focused UI element by replacing the
    /// current selected range in its kAXValue. Prefers the focused element of
    /// `targetPid`, falling back to the system-wide focused element.
    private static func insertAtCursorViaAX(_ text: String, targetPid: pid_t?) -> Bool {
        guard let element = focusedElement(targetPid: targetPid) else { return false }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let current = valueRef as? String else { return false }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range) else { return false }

        let currentNS = current as NSString
        let loc = max(0, min(range.location, currentNS.length))
        let len = max(0, min(range.length, currentNS.length - loc))
        let mutable = NSMutableString(string: current)
        mutable.replaceCharacters(in: NSRange(location: loc, length: len), with: text)

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, mutable as CFString) == .success
        else { return false }

        var caret = CFRange(location: loc + (text as NSString).length, length: 0)
        if let axCaret = AXValueCreate(.cfRange, &caret) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axCaret)
        }
        return true
    }

    private static func focusedElement(targetPid: pid_t?) -> AXUIElement? {
        let root = (targetPid.map { $0 > 0 } ?? false)
            ? AXUIElementCreateApplication(targetPid!)
            : AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    private static func typeCharByChar(_ text: String) {
        for char in text {
            let utf16 = Array(String(char).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { continue }
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyDown.post(tap: .cghidEventTap)
            usleep(1000)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
