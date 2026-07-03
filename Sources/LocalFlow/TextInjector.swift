import AppKit
import ApplicationServices

/// Inserts text into the focused app via clipboard paste: snapshot the
/// pasteboard, write the transcript, synthesize Cmd+V, then restore the
/// previous contents. Restore is skipped if something else wrote to the
/// pasteboard in the meantime (changeCount moved).
final class TextInjector {
    private(set) var lastTranscript: String?

    private static let restoreDelay: TimeInterval = 0.35
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8

    func inject(_ rawText: String) {
        let text = Config.smartSpacing && !rawText.hasSuffix(" ") ? rawText + " " : rawText
        lastTranscript = text
        let pasteboard = NSPasteboard.general

        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            Log.error("Accessibility not granted — transcript left on clipboard (Cmd+V manually)")
            return
        }

        let snapshot = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        guard Self.postKey(Self.vKeyCode, flags: .maskCommand) else {
            Log.error("Failed to synthesize Cmd+V — transcript left on clipboard")
            return
        }
        Log.info("Injected \(text.count) chars via paste")

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            Self.restore(pasteboard, items: snapshot)
        }
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
}
