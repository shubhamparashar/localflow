import AppKit
import Foundation

enum HUDState {
    case idle
    case recording(handsFree: Bool)
    case transcribing
    case cleaning
}

/// Borderless panel that never takes key/main status, so the HUD can float
/// over the focused app without stealing its keyboard focus.
private final class FocuslessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Treats the whole pill as one control: every click, the context menu, and
/// hover tracking route here rather than to the icon/label subviews, so the
/// pill behaves like a single button regardless of where it's clicked.
private final class HUDContentView: NSVisualEffectView {
    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private var trackingAreaRef: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    // The panel never activates the app, so its first click must still register.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) { onClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}

/// Floating Flow-Bar pill (Wispr Flow style): always visible when idle,
/// expanding to show recording / transcribing / cleaning state. Sits
/// bottom-center of the screen the cursor is on, on all Spaces, above
/// full-screen apps, and never steals keyboard focus. Left-click toggles
/// dictation; right-click offers Hide / Quit. All public methods are safe to
/// call from any thread.
final class OverlayHUD: NSObject {

    // MARK: - Layout constants

    private static let pillHeight: CGFloat = 48
    private static let minPillWidth: CGFloat = 200
    private static let minIdleWidth: CGFloat = 52
    private static let cornerRadius: CGFloat = 24
    private static let bottomMargin: CGFloat = 80
    private static let horizontalPadding: CGFloat = 16
    private static let iconSize: CGFloat = 20
    private static let elementGap: CGFloat = 8
    private static let elapsedWidth: CGFloat = 36
    private static let barCount: Int = 5
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 3
    private static let barHeights: [CGFloat] = [8, 11, 14, 17, 20]
    private static let inactiveBarHeight: CGFloat = 4
    // Calibrated to conversational speech through a laptop mic
    // (~-45…-20 dBFS); a square-root curve keeps the bars lively in the
    // quiet half of the range instead of saturating only when shouting.
    private static let minDBFS: Float = -50
    private static let maxDBFS: Float = -18

    /// Below this level for `deadMicTimeout` seconds while recording, the mic
    /// is almost certainly delivering nothing (unplugged, muted, or gain at
    /// zero). Speech reliably clears it, so it won't fire on normal pauses.
    private static let deadMicFloorDBFS: Float = -55
    private static let deadMicTimeout: TimeInterval = 5

    // MARK: - Interaction callbacks (wired by the app)

    var onToggle: (() -> Void)?
    var onHideForOneHour: (() -> Void)?
    var onQuit: (() -> Void)?

    // MARK: - State

    private var panel: NSPanel!
    private var contentView: HUDContentView!
    private var iconView: NSImageView!
    private var textLabel: NSTextField!
    private var elapsedLabel: NSTextField!
    private var barViews: [NSView] = []
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    private var currentState: HUDState?
    private var isHovering = false
    /// Set when the mic has been silent past `deadMicTimeout` during a
    /// recording; restyles the pill to warn and clears on the next real sample.
    private var warningActive = false
    private var lastAboveFloorAt = Date()
    /// Bumped on every show/hide so a stale fade-out completion doesn't
    /// orderOut a panel that has since been re-shown.
    private var hideGeneration: Int = 0

    // MARK: - Public API

    func show(_ state: HUDState) {
        performOnMain { self.showOnMain(state) }
    }

    func hide() {
        performOnMain { self.hideOnMain() }
    }

    func updateLevel(_ dbfs: Float) {
        performOnMain { self.updateLevelOnMain(dbfs) }
    }

    // MARK: - Main-thread implementations

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func showOnMain(_ state: HUDState) {
        if panel == nil {
            buildPanel()
        }
        hideGeneration += 1
        let continuingRecording: Bool = panel.isVisible && isRecording(currentState)
        currentState = state
        applyState(state, continuingRecording: continuingRecording)
        layoutContent()
        if panel.isVisible {
            repositionOnCurrentScreen()
            panel.alphaValue = 1
            return
        }
        positionOnCursorScreen()
        animateIn()
    }

    private func hideOnMain() {
        stopTimer()
        recordingStartedAt = nil
        currentState = nil
        isHovering = false
        warningActive = false
        guard let panel: NSPanel = panel, panel.isVisible else { return }
        hideGeneration += 1
        let generation: Int = hideGeneration
        NSAnimationContext.runAnimationGroup({ (context: NSAnimationContext) in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    private func updateLevelOnMain(_ dbfs: Float) {
        guard panel != nil, isRecording(currentState) else { return }
        if dbfs > Self.deadMicFloorDBFS {
            lastAboveFloorAt = Date()
            if warningActive {
                warningActive = false
                applyVisuals()
                relayout()
            }
        }
        let clamped: Float = min(max(dbfs, Self.minDBFS), Self.maxDBFS)
        let fraction: Float = sqrt((clamped - Self.minDBFS) / (Self.maxDBFS - Self.minDBFS))
        let activeBars: Int = Int((fraction * Float(Self.barCount)).rounded())
        for (index, bar) in barViews.enumerated() {
            setBar(bar, index: index, active: index < activeBars)
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let contentRect: NSRect = NSRect(x: 0, y: 0, width: Self.minPillWidth, height: Self.pillHeight)
        let newPanel: FocuslessPanel = FocuslessPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.ignoresMouseEvents = false
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.animationBehavior = .none

        let effect: HUDContentView = HUDContentView(frame: contentRect)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.maskImage = Self.roundedRectMask(cornerRadius: Self.cornerRadius)
        effect.autoresizingMask = [.width, .height]
        effect.onClick = { [weak self] in self?.onToggle?() }
        effect.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        effect.menuProvider = { [weak self] in self?.buildContextMenu() }

        iconView = NSImageView(frame: .zero)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(iconView)

        textLabel = NSTextField(labelWithString: "")
        textLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        textLabel.textColor = .white
        effect.addSubview(textLabel)

        elapsedLabel = NSTextField(labelWithString: "0:00")
        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        elapsedLabel.alignment = .right
        effect.addSubview(elapsedLabel)

        barViews = (0..<Self.barCount).map { (_: Int) -> NSView in
            let bar: NSView = NSView(frame: .zero)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.white.cgColor
            bar.layer?.cornerRadius = Self.barWidth / 2
            bar.alphaValue = 0.3
            effect.addSubview(bar)
            return bar
        }

        newPanel.contentView = effect
        contentView = effect
        panel = newPanel
    }

    /// Resizable rounded-rect mask; NSVisualEffectView needs a maskImage
    /// (not layer cornerRadius) to clip its blur correctly.
    private static func roundedRectMask(cornerRadius: CGFloat) -> NSImage {
        let edge: CGFloat = cornerRadius * 2 + 1
        let size: NSSize = NSSize(width: edge, height: edge)
        let image: NSImage = NSImage(size: size, flipped: false) { (rect: NSRect) -> Bool in
            NSColor.black.setFill()
            let path: NSBezierPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Context menu

    private func buildContextMenu() -> NSMenu {
        let menu: NSMenu = NSMenu()
        let hideItem: NSMenuItem = NSMenuItem(
            title: "Hide Flow-Bar for 1 hour",
            action: #selector(menuHideForOneHour),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(.separator())
        let quitItem: NSMenuItem = NSMenuItem(
            title: "Quit LocalFlow",
            action: #selector(menuQuit),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func menuHideForOneHour() { onHideForOneHour?() }
    @objc private func menuQuit() { onQuit?() }

    // MARK: - Hover

    private func hoverChanged(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        // Only the idle pill changes shape on hover (collapsed icon ↔ hint).
        guard isIdle(currentState) else { return }
        applyVisuals()
        relayout()
    }

    // MARK: - State application

    private func applyState(_ state: HUDState, continuingRecording: Bool) {
        let recording: Bool = isRecording(state)
        if recording {
            if !continuingRecording || recordingStartedAt == nil {
                recordingStartedAt = Date()
            }
            // Every recording starts with a clean dead-mic watch, so a warning
            // from a prior take can't carry over.
            lastAboveFloorAt = Date()
            warningActive = false
            startTimerIfNeeded()
        } else {
            stopTimer()
            recordingStartedAt = nil
            warningActive = false
            resetBars()
        }
        elapsedLabel.isHidden = !recording
        for bar in barViews {
            bar.isHidden = !recording
        }
        applyVisuals()
        if recording {
            updateElapsedText()
        }
    }

    /// Sets the icon, colour, and label text for the current state (and the
    /// dead-mic warning / idle-hover variants). Does not resize the panel.
    private func applyVisuals() {
        guard let state: HUDState = currentState else { return }
        let symbolName: String
        let iconColor: NSColor
        let text: String
        var showText: Bool = true
        switch state {
        case .idle:
            symbolName = "mic"
            iconColor = NSColor.white.withAlphaComponent(0.85)
            text = "Hold ⌥ or click to dictate"
            showText = isHovering
        case .recording(let handsFree):
            if warningActive {
                symbolName = "exclamationmark.triangle.fill"
                iconColor = .systemOrange
                text = "No mic input — check input volume"
            } else {
                symbolName = "mic.fill"
                iconColor = .systemRed
                text = handsFree ? "Recording (hands-free)…" : "Recording…"
            }
        case .transcribing:
            symbolName = "waveform"
            iconColor = .white
            text = "Transcribing…"
        case .cleaning:
            symbolName = "sparkles"
            iconColor = .white
            text = "Cleaning…"
        }
        let config: NSImage.SymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let image: NSImage? = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)
        iconView.image = image?.withSymbolConfiguration(config)
        iconView.contentTintColor = iconColor
        textLabel.stringValue = showText ? text : ""
        textLabel.isHidden = !showText
    }

    private func isRecording(_ state: HUDState?) -> Bool {
        guard let state: HUDState = state else { return false }
        if case .recording = state {
            return true
        }
        return false
    }

    private func isIdle(_ state: HUDState?) -> Bool {
        guard let state: HUDState = state else { return false }
        if case .idle = state {
            return true
        }
        return false
    }

    // MARK: - Layout

    private func relayout() {
        guard let panel: NSPanel = panel, panel.isVisible else { return }
        layoutContent()
        repositionOnCurrentScreen()
    }

    private func layoutContent() {
        textLabel.sizeToFit()
        elapsedLabel.sizeToFit()
        let recording: Bool = isRecording(currentState)
        let showText: Bool = !textLabel.isHidden && !textLabel.stringValue.isEmpty
        let idleCollapsed: Bool = isIdle(currentState) && !showText
        let meterWidth: CGFloat = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing

        var width: CGFloat = Self.horizontalPadding + Self.iconSize
        if showText {
            width += Self.elementGap + textLabel.frame.width
        }
        if recording {
            width += Self.elementGap + Self.elapsedWidth + Self.elementGap + meterWidth
        }
        width += Self.horizontalPadding
        width = max(width, idleCollapsed ? Self.minIdleWidth : Self.minPillWidth)

        var panelFrame: NSRect = panel.frame
        panelFrame.size = NSSize(width: width, height: Self.pillHeight)
        panel.setFrame(panelFrame, display: false)

        let midY: CGFloat = Self.pillHeight / 2

        // Idle-collapsed pill is just a centered mic glyph.
        if idleCollapsed {
            iconView.frame = NSRect(
                x: (width - Self.iconSize) / 2,
                y: midY - Self.iconSize / 2,
                width: Self.iconSize,
                height: Self.iconSize
            )
            return
        }

        iconView.frame = NSRect(
            x: Self.horizontalPadding,
            y: midY - Self.iconSize / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )

        if showText {
            let labelX: CGFloat = Self.horizontalPadding + Self.iconSize + Self.elementGap
            let labelHeight: CGFloat = textLabel.frame.height
            textLabel.frame = NSRect(
                x: labelX,
                y: midY - labelHeight / 2,
                width: textLabel.frame.width,
                height: labelHeight
            )
        }

        guard recording else { return }
        let meterX: CGFloat = width - Self.horizontalPadding - meterWidth
        for (index, bar) in barViews.enumerated() {
            let barHeight: CGFloat = max(bar.frame.height, Self.inactiveBarHeight)
            bar.frame = NSRect(
                x: meterX + CGFloat(index) * (Self.barWidth + Self.barSpacing),
                y: midY - barHeight / 2,
                width: Self.barWidth,
                height: barHeight
            )
        }
        let elapsedHeight: CGFloat = elapsedLabel.frame.height
        elapsedLabel.frame = NSRect(
            x: meterX - Self.elementGap - Self.elapsedWidth,
            y: midY - elapsedHeight / 2,
            width: Self.elapsedWidth,
            height: elapsedHeight
        )
    }

    // MARK: - Positioning

    private func positionOnCursorScreen() {
        let mouse: NSPoint = NSEvent.mouseLocation
        let cursorScreen: NSScreen? = NSScreen.screens.first { (screen: NSScreen) -> Bool in
            NSMouseInRect(mouse, screen.frame, false)
        }
        guard let target: NSScreen = cursorScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        setOrigin(bottomCenteredOn: target)
    }

    private func repositionOnCurrentScreen() {
        guard let target: NSScreen = panel.screen ?? NSScreen.main else { return }
        setOrigin(bottomCenteredOn: target)
    }

    private func setOrigin(bottomCenteredOn screen: NSScreen) {
        let screenFrame: NSRect = screen.frame
        let origin: NSPoint = NSPoint(
            x: screenFrame.midX - panel.frame.width / 2,
            y: screenFrame.minY + Self.bottomMargin
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Animation

    private func animateIn() {
        let target: NSRect = panel.frame
        panel.setFrameOrigin(NSPoint(x: target.origin.x, y: target.origin.y - 12))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { (context: NSAnimationContext) in
            context.duration = 0.2
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Elapsed timer / dead-mic watch

    private func startTimerIfNeeded() {
        guard elapsedTimer == nil else { return }
        let timer: Timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] (_: Timer) in
            self?.onTimerTick()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func onTimerTick() {
        updateElapsedText()
        checkDeadMic()
    }

    private func updateElapsedText() {
        guard let startedAt: Date = recordingStartedAt else { return }
        let seconds: Int = max(0, Int(Date().timeIntervalSince(startedAt)))
        elapsedLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func checkDeadMic() {
        guard isRecording(currentState), !warningActive else { return }
        if Date().timeIntervalSince(lastAboveFloorAt) >= Self.deadMicTimeout {
            warningActive = true
            applyVisuals()
            relayout()
        }
    }

    // MARK: - Level meter

    private func setBar(_ bar: NSView, index: Int, active: Bool) {
        let barHeight: CGFloat = active ? Self.barHeights[index] : Self.inactiveBarHeight
        var frame: NSRect = bar.frame
        frame.origin.y = (Self.pillHeight - barHeight) / 2
        frame.size.height = barHeight
        bar.frame = frame
        bar.alphaValue = active ? 1.0 : 0.3
    }

    private func resetBars() {
        for (index, bar) in barViews.enumerated() {
            setBar(bar, index: index, active: false)
        }
    }

    deinit {
        stopTimer()
    }
}
