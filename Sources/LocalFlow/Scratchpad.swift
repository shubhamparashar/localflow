import AppKit

/// A native notepad window to dictate into and refine. Because injection is a
/// synthetic paste into whatever field has focus, dictating while this window
/// is focused drops text straight into the text view — no special routing.
/// "Improve Writing" rewrites the selection (or the whole note) via the local
/// LLM in place.
final class ScratchpadController: NSObject, NSWindowDelegate {

    private static let windowSize = NSSize(width: 560, height: 440)
    private static let barHeight: CGFloat = 48
    private static let margin: CGFloat = 12

    private var window: NSWindow?
    private var textView: NSTextView?
    private var improveButton: NSButton?
    private var statusLabel: NSTextField?

    func show() {
        if window == nil {
            build()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let frame = NSRect(origin: .zero, size: Self.windowSize)
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "LocalFlow Scratchpad"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.minSize = NSSize(width: 360, height: 260)

        let content = NSView(frame: frame)
        content.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(
            x: 0,
            y: Self.barHeight,
            width: frame.width,
            height: frame.height - Self.barHeight
        ))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = NSTextView(frame: scroll.bounds)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.isEditable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = tv
        content.addSubview(scroll)

        let bar = buildBar(width: frame.width)
        content.addSubview(bar)

        win.contentView = content
        window = win
        textView = tv
    }

    private func buildBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.barHeight))
        bar.autoresizingMask = [.width]

        let improve = NSButton(title: "Improve Writing", target: self, action: #selector(improveTapped))
        improve.bezelStyle = .rounded
        improve.sizeToFit()
        improve.frame = NSRect(
            x: Self.margin,
            y: (Self.barHeight - improve.frame.height) / 2,
            width: max(improve.frame.width, 130),
            height: improve.frame.height
        )
        improve.autoresizingMask = [.maxXMargin]
        bar.addSubview(improve)
        improveButton = improve

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(
            x: improve.frame.maxX + 10,
            y: (Self.barHeight - 16) / 2,
            width: 160,
            height: 16
        )
        status.autoresizingMask = [.width]
        bar.addSubview(status)
        statusLabel = status

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearTapped))
        clear.bezelStyle = .rounded
        clear.sizeToFit()
        let clearWidth = max(clear.frame.width, 64)
        clear.frame = NSRect(
            x: width - Self.margin - clearWidth,
            y: (Self.barHeight - clear.frame.height) / 2,
            width: clearWidth,
            height: clear.frame.height
        )
        clear.autoresizingMask = [.minXMargin]
        bar.addSubview(clear)

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyTapped))
        copy.bezelStyle = .rounded
        copy.sizeToFit()
        let copyWidth = max(copy.frame.width, 64)
        copy.frame = NSRect(
            x: clear.frame.minX - 8 - copyWidth,
            y: (Self.barHeight - copy.frame.height) / 2,
            width: copyWidth,
            height: copy.frame.height
        )
        copy.autoresizingMask = [.minXMargin]
        bar.addSubview(copy)

        return bar
    }

    // MARK: - Actions

    @objc private func improveTapped() {
        guard let textView else { return }
        let selectedRange = textView.selectedRange()
        let usesSelection = selectedRange.length > 0
        let full = textView.string as NSString
        let target = usesSelection ? full.substring(with: selectedRange) : textView.string
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        setBusy(true)
        OllamaCleaner.applyCommand(instruction: OllamaCleaner.improveInstruction, to: target) { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .success(let improved) where !improved.isEmpty:
                self.replace(range: usesSelection ? selectedRange : nil, with: improved)
            case .success:
                Log.error("Improve: empty result, leaving text unchanged")
            case .failure(let error):
                Log.error("Improve failed (is Ollama running?): \(error.localizedDescription)")
            }
        }
    }

    /// Replaces `range` (or the whole document when nil) through the text
    /// view's undo-aware path so ⌘Z restores the original.
    private func replace(range: NSRange?, with text: String) {
        guard let textView else { return }
        let target = range ?? NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: target, replacementString: text) else { return }
        textView.replaceCharacters(in: target, with: text)
        textView.didChangeText()
    }

    @objc private func copyTapped() {
        guard let textView else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
    }

    @objc private func clearTapped() {
        replace(range: nil, with: "")
    }

    private func setBusy(_ busy: Bool) {
        improveButton?.isEnabled = !busy
        statusLabel?.stringValue = busy ? "Improving…" : ""
    }
}
