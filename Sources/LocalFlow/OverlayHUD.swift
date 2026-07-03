import AppKit
import Foundation

enum HUDState {
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

/// Floating recording-indicator pill (Wispr Flow style): shown bottom-center
/// of the screen the cursor is on, on all Spaces, above full-screen apps.
/// All public methods are safe to call from any thread.
final class OverlayHUD {

    // MARK: - Layout constants

    private static let pillHeight: CGFloat = 48
    private static let minPillWidth: CGFloat = 200
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

    // MARK: - State

    private var panel: NSPanel!
    private var iconView: NSImageView!
    private var textLabel: NSTextField!
    private var elapsedLabel: NSTextField!
    private var barViews: [NSView] = []
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    private var currentState: HUDState?
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
        newPanel.ignoresMouseEvents = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.animationBehavior = .none

        let effect: NSVisualEffectView = NSVisualEffectView(frame: contentRect)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.maskImage = Self.roundedRectMask(cornerRadius: Self.cornerRadius)
        effect.autoresizingMask = [.width, .height]

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

    // MARK: - State application

    private func applyState(_ state: HUDState, continuingRecording: Bool) {
        let symbolName: String
        let iconColor: NSColor
        let text: String
        switch state {
        case .recording(let handsFree):
            symbolName = "mic.fill"
            iconColor = .systemRed
            text = handsFree ? "Recording (hands-free)…" : "Recording…"
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
        textLabel.stringValue = text

        let recording: Bool = isRecording(state)
        elapsedLabel.isHidden = !recording
        for bar in barViews {
            bar.isHidden = !recording
        }
        if recording {
            if !continuingRecording || recordingStartedAt == nil {
                recordingStartedAt = Date()
            }
            startTimerIfNeeded()
            updateElapsedText()
        } else {
            stopTimer()
            recordingStartedAt = nil
            resetBars()
        }
    }

    private func isRecording(_ state: HUDState?) -> Bool {
        guard let state: HUDState = state else { return false }
        if case .recording = state {
            return true
        }
        return false
    }

    // MARK: - Layout

    private func layoutContent() {
        textLabel.sizeToFit()
        elapsedLabel.sizeToFit()
        let recording: Bool = isRecording(currentState)
        let meterWidth: CGFloat = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing

        var width: CGFloat = Self.horizontalPadding + Self.iconSize + Self.elementGap + textLabel.frame.width
        if recording {
            width += Self.elementGap + Self.elapsedWidth + Self.elementGap + meterWidth
        }
        width += Self.horizontalPadding
        width = max(width, Self.minPillWidth)

        var panelFrame: NSRect = panel.frame
        panelFrame.size = NSSize(width: width, height: Self.pillHeight)
        panel.setFrame(panelFrame, display: false)

        let midY: CGFloat = Self.pillHeight / 2
        iconView.frame = NSRect(
            x: Self.horizontalPadding,
            y: midY - Self.iconSize / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        let labelX: CGFloat = Self.horizontalPadding + Self.iconSize + Self.elementGap
        let labelHeight: CGFloat = textLabel.frame.height
        textLabel.frame = NSRect(
            x: labelX,
            y: midY - labelHeight / 2,
            width: textLabel.frame.width,
            height: labelHeight
        )

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

    // MARK: - Elapsed timer

    private func startTimerIfNeeded() {
        guard elapsedTimer == nil else { return }
        let timer: Timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] (_: Timer) in
            self?.updateElapsedText()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateElapsedText() {
        guard let startedAt: Date = recordingStartedAt else { return }
        let seconds: Int = max(0, Int(Date().timeIntervalSince(startedAt)))
        elapsedLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
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
}
