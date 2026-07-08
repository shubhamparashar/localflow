import AppKit

/// Minimal naming UI for "Label Speakers": lists every speaker known to
/// `speakers.json` plus any speaker discovered in the current capture
/// session, with an editable name per row. Saving persists names (and
/// embeddings) back to `speakers.json` so renamed speakers are recognized
/// in future capture sessions.
final class SpeakersPanel: NSObject {
    private var window: NSWindow?
    private var rows: [(id: String, embedding: [Float], field: NSTextField)] = []

    func show() {
        build()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let speakers = Self.mergedSpeakers()
        let width: CGFloat = 360

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let hint = NSTextField(wrappingLabelWithString:
            "Rename Speaker 1 to yourself or a teammate — future meetings will recognize them.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = width - 32
        stack.addArrangedSubview(hint)

        rows = []
        if speakers.isEmpty {
            stack.addArrangedSubview(
                NSTextField(labelWithString: "No speakers yet — enable Label Speakers and run a capture."))
        }
        for speaker in speakers {
            let field = NSTextField()
            field.stringValue = speaker.name
            field.widthAnchor.constraint(equalToConstant: width - 32).isActive = true
            stack.addArrangedSubview(field)
            rows.append((id: speaker.id, embedding: speaker.embedding, field: field))
        }

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        stack.addArrangedSubview(saveButton)

        stack.layoutSubtreeIfNeeded()

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Speakers"
        win.isReleasedWhenClosed = false
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        win.center()
        window = win
    }

    @objc private func save() {
        let speakers = rows.map { SavedSpeaker(id: $0.id, name: $0.field.stringValue, embedding: $0.embedding) }
        SpeakerStore.save(speakers)
        Log.info("Speakers panel: saved \(speakers.count) speaker(s)")
        window?.close()
    }

    /// Known (persisted) speakers merged with any session-only speakers not
    /// yet saved, deduped by id (the session copy wins — it has the
    /// freshest embedding), with any resulting duplicate placeholder names
    /// ("Speaker N") resolved so the list never shows two identical labels.
    static func mergedSpeakers() -> [SavedSpeaker] {
        var byId: [String: SavedSpeaker] = [:]
        for speaker in SpeakerStore.load() { byId[speaker.id] = speaker }
        for speaker in SpeakerDiarizer.shared.sessionSpeakers() { byId[speaker.id] = speaker }

        var taken = Set<String>()
        var result: [SavedSpeaker] = []
        for speaker in byId.values.sorted(by: { $0.id < $1.id }) {
            var speaker = speaker
            if taken.contains(speaker.name) {
                speaker.name = SpeakerDiarizer.nextProvisionalName(taken: taken)
            }
            taken.insert(speaker.name)
            result.append(speaker)
        }
        return result
    }
}
