import AppKit

final class MeetingNotebookController: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    var onToggleMeeting: (() -> Void)?
    private let store: MeetingStore
    private var window: NSWindow?
    private let picker = NSPopUpButton()
    private let titleField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "Start meeting", target: nil, action: nil)
    private let enhanceButton = NSButton(title: "Enhance notes", target: nil, action: nil)
    private let tabs = NSSegmentedControl(labels: ["My notes", "Enhanced notes", "Transcript"], trackingMode: .selectOne, target: nil, action: nil)
    private let editor = NSTextView()
    private var selectedID: UUID?
    private var activeID: UUID?
    private var stoppingID: UUID?
    private var documents: [UUID: MeetingDocument] = [:]
    private var messages: [UUID: String] = [:]
    private var generating: Set<UUID> = []
    private var saveErrors: [UUID: String] = [:]
    private var displaying = false

    init(store: MeetingStore = MeetingStore()) {
        self.store = store
        super.init()
        documents = Dictionary(uniqueKeysWithValues: store.documents.map { ($0.id, $0) })
        selectedID = store.documents.first?.id
    }

    func show() {
        if window == nil { build() }
        refreshPicker()
        render()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func beginMeeting() -> UUID {
        editor.undoManager?.removeAllActions()
        var document = MeetingDocument()
        document.title = "Meeting · " + document.startedAt.formatted(date: .abbreviated, time: .shortened)
        selectedID = document.id
        activeID = document.id
        persist(document)
        tabs.selectedSegment = 0
        show()
        return document.id
    }

    func append(text: String, speaker: String, at date: Date, to id: UUID) {
        guard var document = documents[id] else { return }
        document.entries.append(.init(at: date, speaker: speaker, text: text))
        persist(document)
        if selectedID == id && tabs.selectedSegment == 2 { render() }
    }

    func finishingMeeting(_ id: UUID) {
        stoppingID = id
        messages[id] = "Finishing the last transcript segments…"
        render()
    }

    func endMeeting(_ id: UUID) {
        guard var document = documents[id] else { return }
        document.endedAt = Date()
        if activeID == id { activeID = nil }
        if stoppingID == id { stoppingID = nil }
        persist(document)
        enhance(id)
        render()
    }

    func report(message: String, for id: UUID) {
        if var document = documents[id] {
            var warnings = document.captureWarnings ?? []
            if !warnings.contains(message) { warnings.append(message) }
            document.captureWarnings = warnings
            persist(document)
        }
        render()
    }

    // Keep unsaved content in memory when disk writes fail so it remains copyable.
    private func persist(_ document: MeetingDocument) {
        documents[document.id] = document
        let previousError = saveErrors[document.id]
        do {
            try store.save(document)
            saveErrors[document.id] = nil
        } catch { saveErrors[document.id] = "Not saved: \(error.localizedDescription). Copy your notes before quitting." }
        if previousError != saveErrors[document.id] { render() }
    }

    private var ordered: [MeetingDocument] { documents.values.sorted { $0.startedAt > $1.startedAt } }

    private func refreshPicker() {
        picker.removeAllItems()
        for document in ordered {
            let item = NSMenuItem(title: document.title.isEmpty ? "Untitled meeting" : document.title, action: nil, keyEquivalent: "")
            item.representedObject = document.id
            picker.menu?.addItem(item)
        }
        if let selectedID, let index = ordered.firstIndex(where: { $0.id == selectedID }) { picker.selectItem(at: index) }
    }

    private func render() {
        guard window != nil else { return }
        displaying = true
        defer { displaying = false }
        let document = selectedID.flatMap { documents[$0] }
        titleField.stringValue = document?.title ?? ""
        titleField.isEnabled = document != nil
        let tab = tabs.selectedSegment
        let text = tab == 0 ? document?.rawNotes : tab == 1 ? document?.enhancedNotes : document?.transcript
        if editor.string != (text ?? "") {
            editor.string = text ?? ""
            editor.undoManager?.removeAllActions()
        }
        editor.isEditable = document != nil && tab != 2 && !(tab == 1 && generating.contains(document!.id))
        recordButton.title = activeID == nil ? "Start meeting" : "Stop meeting"
        recordButton.isEnabled = stoppingID == nil
        enhanceButton.isEnabled = document != nil && activeID != document?.id && !generating.contains(document!.id)
        if let document {
            if let error = saveErrors[document.id] { status.stringValue = error }
            else if let message = messages[document.id] { status.stringValue = message }
            else if generating.contains(document.id) { status.stringValue = "Enhancing locally… Your transcript and notes are saved." }
            else if activeID == document.id { status.stringValue = "Recording · Notes save automatically" }
            else if document.endedAt == nil { status.stringValue = "Interrupted meeting · Saved content recovered" }
            else { status.stringValue = "Saved locally · \(document.entries.count) transcript segments" }
            if let warnings = document.captureWarnings, !warnings.isEmpty {
                status.stringValue += " · " + warnings.joined(separator: " ")
            }
        } else { status.stringValue = "Start a meeting to take notes while LocalFlow transcribes." }
        if !store.loadErrors.isEmpty {
            status.stringValue += " · Some saved files could not be loaded; originals kept."
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !displaying, let id = selectedID, var document = documents[id] else { return }
        if tabs.selectedSegment == 0 { document.rawNotes = editor.string }
        else if tabs.selectedSegment == 1 { document.enhancedNotes = editor.string }
        persist(document)
        if messages[id] != nil || saveErrors[id] != nil { render() }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !displaying, let id = selectedID, var document = documents[id] else { return }
        document.title = titleField.stringValue
        persist(document)
        refreshPicker()
    }

    @objc private func selectMeeting() {
        editor.undoManager?.removeAllActions()
        selectedID = picker.selectedItem?.representedObject as? UUID
        render()
    }

    @objc private func selectTab() { editor.undoManager?.removeAllActions(); render() }
    @objc private func toggleRecording() { onToggleMeeting?() }
    @objc private func enhanceSelected() { if let selectedID { enhance(selectedID) } }
    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editor.string, forType: .string)
    }

    private func enhance(_ id: UUID) {
        guard let snapshot = documents[id], activeID != id, !generating.contains(id) else { return }
        guard !snapshot.transcript.isEmpty || !snapshot.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            messages[id] = "No speech or notes captured. You can write notes and enhance them later."
            render()
            return
        }
        generating.insert(id)
        messages[id] = nil
        render()
        let input = snapshot.notesInput
        if input.hasOverlappingChannels {
            report(message: "Repeated speech appears in both audio channels; speaker ownership needs review.", for: id)
        }
        MeetingNotesGenerator.generate(transcript: input.transcript, rawNotes: snapshot.rawNotes) { [weak self] notes in
            guard let self, var current = self.documents[id] else { return }
            self.generating.remove(id)
            if current.rawNotes != snapshot.rawNotes || current.entries != snapshot.entries {
                self.messages[id] = "Notes changed during enhancement. Click Enhance notes to use your latest edits."
            } else if let notes {
                current.enhancedNotes = notes
                self.persist(current)
                if self.selectedID == id {
                    self.editor.undoManager?.removeAllActions()
                    self.tabs.selectedSegment = 1
                }
            } else {
                self.messages[id] = "Could not generate a quoted draft. Check Ollama and the \(Config.summaryModel) model, then retry. Your notes and transcript are preserved."
            }
            self.render()
        }
    }

    private func build() {
        // AppKit resolves standard editing shortcuts through the application menu.
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        if !mainMenu.items.contains(where: { $0.submenu?.title == "Edit" }) {
            let edit = NSMenu(title: "Edit")
            for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                         ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                         ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
                edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
            }
            let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            item.submenu = edit
            mainMenu.addItem(item)
            NSApp.mainMenu = mainMenu
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 640),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "LocalFlow Meetings"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 680, height: 450)
        win.center()
        guard let content = win.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        picker.target = self
        picker.action = #selector(selectMeeting)
        picker.setAccessibilityLabel("Saved meetings")
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        let top = NSStackView(views: [picker, recordButton])
        top.orientation = .horizontal
        top.spacing = 12
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.placeholderString = "Meeting title"
        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.delegate = self
        titleField.setAccessibilityLabel("Meeting title")
        stack.addArrangedSubview(titleField)
        titleField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(selectTab)
        stack.addArrangedSubview(tabs)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 15)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self
        editor.setAccessibilityLabel("Meeting content")
        scroll.documentView = editor
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        enhanceButton.target = self
        enhanceButton.action = #selector(enhanceSelected)
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        let actions = NSStackView(views: [enhanceButton, copy])
        actions.spacing = 10
        stack.addArrangedSubview(actions)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window = win
    }
}
