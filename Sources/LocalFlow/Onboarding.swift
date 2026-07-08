import AppKit
import ApplicationServices
import AVFoundation

/// First-run welcome window. Explains the core gesture, points out the
/// draggable Flow-Bar, and surfaces live status for the two permissions the app
/// needs (Microphone to hear you, Accessibility to type into other apps) with
/// buttons to grant them. Shown once; re-openable from the menu.
final class OnboardingController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var micStatus: NSTextField?
    private var micButton: NSButton?
    private var axStatus: NSTextField?
    private var axButton: NSButton?
    private var refreshTimer: Timer?

    func show() {
        if window == nil {
            build()
        }
        refreshPermissions()
        startRefreshTimer()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(title("Welcome to LocalFlow"))
        stack.addArrangedSubview(subtitle("Fully-local voice dictation — your audio never leaves this Mac."))
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(header("How it works"))
        stack.addArrangedSubview(step("1.", "Hold Right ⌥ (Option) and speak."))
        stack.addArrangedSubview(step("2.", "Release — your words are transcribed on-device and typed wherever the cursor is."))
        stack.addArrangedSubview(step("3.", "Quick-tap Right ⌥ for hands-free; it stops when you stop talking."))
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(header("The Flow-Bar"))
        stack.addArrangedSubview(subtitle("The pill at the bottom of the screen shows status. Click it to start or stop, and drag it anywhere — it stays where you leave it."))
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(header("Permissions"))
        let mic = permissionRow(
            label: "Microphone — to hear you",
            action: #selector(enableMicrophone),
            statusOut: { self.micStatus = $0 },
            buttonOut: { self.micButton = $0 }
        )
        stack.addArrangedSubview(mic)
        let ax = permissionRow(
            label: "Accessibility — to type into other apps",
            action: #selector(openAccessibilitySettings),
            statusOut: { self.axStatus = $0 },
            buttonOut: { self.axButton = $0 }
        )
        stack.addArrangedSubview(ax)
        stack.addArrangedSubview(note("AI cleanup is optional — install Ollama later to auto-tidy dictations. You can skip it."))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        let getStarted = NSButton(title: "Get Started", target: self, action: #selector(finish))
        getStarted.bezelStyle = .push
        getStarted.controlSize = .large
        getStarted.keyEquivalent = "\r"
        stack.addArrangedSubview(getStarted)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalToConstant: 460),
        ])

        let fitting = stack.fittingSize
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: fitting.width + 48, height: fitting.height + 48),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to LocalFlow"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = content
        win.center()
        window = win
    }

    // MARK: - Row builders

    private func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        return label
    }

    private func subtitle(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// A small circled badge (number or SF Symbol) used as a step marker.
    private func circledBadge(_ content: NSView) -> NSView {
        let circle = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        circle.layer?.cornerRadius = 12
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.widthAnchor.constraint(equalToConstant: 24).isActive = true
        circle.heightAnchor.constraint(equalToConstant: 24).isActive = true
        content.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        return circle
    }

    private func step(_ number: String, _ text: String) -> NSStackView {
        let numberLabel = NSTextField(labelWithString: number)
        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        numberLabel.textColor = .controlAccentColor
        let badge = circledBadge(numberLabel)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = NSFont.systemFont(ofSize: 13)
        let row = NSStackView(views: [badge, body])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func permissionRow(
        label: String,
        action: Selector,
        statusOut: (NSTextField) -> Void,
        buttonOut: (NSButton) -> Void
    ) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = NSFont.systemFont(ofSize: 13)
        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusOut(status)
        let button = NSButton(title: "Enable…", target: self, action: action)
        button.bezelStyle = .rounded
        buttonOut(button)
        let row = NSStackView(views: [name, status, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        return card
    }

    // MARK: - Permission state

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refreshPermissions() {
        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        apply(status: micStatus, button: micButton, granted: micGranted)
        let axGranted = AXIsProcessTrusted()
        apply(status: axStatus, button: axButton, granted: axGranted)
    }

    private func apply(status: NSTextField?, button: NSButton?, granted: Bool) {
        status?.stringValue = granted ? "✓ Granted" : "Not granted"
        status?.textColor = granted ? .systemGreen : .systemOrange
        button?.isHidden = granted
    }

    // MARK: - Actions

    @objc private func enableMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPermissions() }
        }
    }

    @objc private func openAccessibilitySettings() {
        // Prompt macOS to add the app to the Accessibility list, then open the pane.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func finish() {
        Log.info("Onboarding completed")
        window?.close()
    }

    /// Any dismissal — Get Started, the red button, or ⌘W — marks onboarding
    /// seen and stops the permission-refresh timer, so it neither nags on the
    /// next launch nor leaks a 1 Hz timer for the app's lifetime.
    func windowWillClose(_ notification: Notification) {
        Config.hasCompletedOnboarding = true
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
