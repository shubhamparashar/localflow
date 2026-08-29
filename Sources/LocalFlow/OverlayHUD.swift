import AppKit
import Foundation

enum HUDState {
    case idle
    case recording(handsFree: Bool)
    case transcribing
    case cleaning
    case warning(String)
    /// Meeting Mode is on and the mic is between takes — the pill must keep
    /// signalling "recording your meeting" so system-audio capture is never
    /// invisible.
    case meeting
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
    /// Fires with the pill's new center (screen coords) once a drag settles.
    var onDragEnded: ((CGPoint) -> Void)?
    /// Fires when a click lands inside `badgeHitFrame` instead of toggling dictation.
    var onBadgeClick: (() -> Void)?
    /// The language badge's frame in this view's coordinates, updated by layout.
    /// `nil` (or a click outside it) falls through to the plain-pill toggle.
    var badgeHitFrame: NSRect?
    /// Docked hover stack: clicks inside these route to language cycling /
    /// the scratchpad instead of toggling dictation.
    var globeHitFrame: NSRect?
    var notesHitFrame: NSRect?
    var meetingHitFrame: NSRect?
    var onGlobeClick: (() -> Void)?
    var onNotesClick: (() -> Void)?
    var onMeetingClick: (() -> Void)?
    /// When set, the plain-pill toggle only fires inside this frame (docked
    /// hover stack: the panel is mostly transparent canvas and stray clicks
    /// must not start a dictation).
    var micHitFrame: NSRect?
    /// Reports cursor movement in local coordinates while inside the view.
    var onMouseMoved: ((NSPoint) -> Void)?

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        onMouseMoved?(local)
    }
    /// Fires true when a drag begins and false when it ends, so the HUD can stop
    /// repositioning the pill (e.g. on an idle→recording change) mid-drag.
    var onDragStateChanged: ((Bool) -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    /// Movement (points) below which a press-and-release is a click, not a drag.
    private static let dragThreshold: CGFloat = 4
    private var mouseDownScreen: NSPoint?
    private var windowCenterAtMouseDown: NSPoint?
    private var isDragging = false

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
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreen = NSEvent.mouseLocation
        if let window = window {
            windowCenterAtMouseDown = NSPoint(x: window.frame.midX, y: window.frame.midY)
        }
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownScreen,
              let startCenter = windowCenterAtMouseDown,
              let window = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !isDragging && hypot(dx, dy) < Self.dragThreshold { return }
        if !isDragging {
            isDragging = true
            onDragStateChanged?(true)
        }
        // Track the center (not the origin) so a width change mid-drag — e.g. a
        // dictation starting — can't slide the pill out from under the cursor.
        let center = NSPoint(x: startCenter.x + dx, y: startCenter.y + dy)
        window.setFrameOrigin(NSPoint(
            x: center.x - window.frame.width / 2,
            y: center.y - window.frame.height / 2
        ))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownScreen = nil
            windowCenterAtMouseDown = nil
            isDragging = false
        }
        // If the panel was ordered out mid-gesture (a state change hid it), the
        // release is neither a move nor a click — drop it without persisting a
        // position or toggling dictation.
        guard window?.isVisible == true else {
            if isDragging { onDragStateChanged?(false) }
            return
        }
        if isDragging {
            onDragStateChanged?(false)
            if let window = window {
                onDragEnded?(CGPoint(x: window.frame.midX, y: window.frame.midY))
            }
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if let badgeHitFrame, badgeHitFrame.contains(local) {
            onBadgeClick?()
            return
        }
        if let globeHitFrame, globeHitFrame.contains(local) {
            onGlobeClick?()
            return
        }
        if let notesHitFrame, notesHitFrame.contains(local) {
            onNotesClick?()
            return
        }
        if let meetingHitFrame, meetingHitFrame.contains(local) {
            onMeetingClick?()
            return
        }
        if let micHitFrame {
            if micHitFrame.contains(local) { onClick?() }
            return
        }
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

    private static let pillHeight: CGFloat = 26
    private static let minPillWidth: CGFloat = 200
    private static let minIdleWidth: CGFloat = 30
    private static let cornerRadius: CGFloat = 13
    private static let bottomMargin: CGFloat = 80
    private static let horizontalPadding: CGFloat = 10
    private static let iconSize: CGFloat = 13
    private static let elementGap: CGFloat = 8
    private static let elapsedWidth: CGFloat = 36
    private static let barCount: Int = 16
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 12
    private static let meterWidth: CGFloat =
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    /// Longest a live caption is allowed to render before the pill truncates
    /// its head, keeping the newest (most relevant) words on screen.
    private static let maxCaptionWidth: CGFloat = 360
    private static let handsFreeDotDiameter: CGFloat = 6
    // Side-dock (vertical) geometry, Wispr Flow style: idle is a hairline
    // capsule hugging the edge; active states are a narrow vertical pill with
    // the waveform stacked as a column of horizontally-scaling bars.
    private static let dockIdleWidth: CGFloat = 8
    private static let dockIdleHoverWidth: CGFloat = 22
    private static let dockIdleHeight: CGFloat = 44
    private static let dockActiveWidth: CGFloat = 22
    private static let dockPadding: CGFloat = 8
    /// Vertical spacing between hover-stack button centers (globe / mic / notes).
    private static let dockButtonPitch: CGFloat = 38
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
    /// Fires with a whisper language code when the pill's Language submenu or
    /// badge-click cycling picks one; the app applies it the same way the
    /// status-bar menu would (Parakeet prepare, recents, badge refresh).
    var onSelectLanguage: ((String) -> Void)?
    /// Supplies the "More Languages" submenu content, shared with the
    /// status-bar menu so the two surfaces don't diverge.
    var moreLanguagesMenuProvider: (() -> NSMenu)?
    /// Fires when "Dictate to Claude" is picked from the pill's right-click
    /// menu; only shown when `Config.claudePipeEnabled`.
    var onDictateToClaude: (() -> Void)?

    /// Fires when "Capture Mode" is toggled from the pill's right-click menu.
    var onToggleCapture: (() -> Void)?

    /// Supplies whether capture mode is currently on (for the menu checkmark).
    var captureModeIsActive: (() -> Bool)?

    /// Fires when the docked hover stack's notes button is clicked; opens the
    /// Scratchpad.
    var onOpenScratchpad: (() -> Void)?

    /// Fires when "Meeting Notes" is toggled from the pill's right-click menu.
    var onToggleMeeting: (() -> Void)?

    /// Supplies whether Meeting Mode is currently on (for the menu checkmark).
    var meetingModeIsActive: (() -> Bool)?

    // MARK: - State

    private var panel: NSPanel!
    private var contentView: HUDContentView!
    private var washView: NSView!
    private var borderView: NSView!
    private var iconView: NSImageView!
    private var globeIconView: NSImageView!
    private var notesIconView: NSImageView!
    private var meetingIconView: NSImageView!
    /// Dark circle backgrounds behind the docked hover-stack buttons, in
    /// stack order: globe, mic, notes, meeting.
    private var stackCircleViews: [NSView] = []
    private var tooltipView: NSView!
    private var tooltipLabel: NSTextField!
    /// Which hover-stack button the cursor is over (0 globe, 1 mic, 2 notes,
    /// 3 meeting).
    private var hoveredStackIndex: Int?
    private static let stackTooltips: [String] = ["Change language", "Dictate ⌥", "Scratchpad", "Meeting notes"]
    private static let dockCircleDiameter: CGFloat = 30
    private var textLabel: NSTextField!
    private var elapsedLabel: NSTextField!
    private var badgeChip: NSView!
    private var badgeLabel: NSTextField!
    private var handsFreeDotView: NSView!
    private var shimmerView: NSView!
    private var barViews: [NSView] = []
    /// Ring buffer of the last `barCount` mapped bar heights, oldest first —
    /// each `updateLevel` call shifts it, producing a scrolling waveform
    /// rather than every bar mirroring the instantaneous level.
    private var levelHistory: [CGFloat] = Array(repeating: OverlayHUD.minBarHeight, count: OverlayHUD.barCount)
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    private var currentState: HUDState?
    private var isHovering = false
    /// Set when the mic has been silent past `deadMicTimeout` during a
    /// recording; restyles the pill to warn and clears on the next real sample.
    private var warningActive = false
    private var lastAboveFloorAt = Date()
    /// Live caption text for the current recording, set by `updateCaption`.
    /// Replaces (never appends to) the pill's status text while recording.
    private var recordingCaption = ""
    /// Bumped on every show/hide so a stale fade-out completion doesn't
    /// orderOut a panel that has since been re-shown.
    private var hideGeneration: Int = 0
    /// True while the user is physically dragging the pill; suppresses automatic
    /// repositioning so a state change can't yank it away from the cursor.
    private var isDraggingPill = false

    /// System-wide "reduce motion" preference: swaps animated transitions for
    /// instant ones and disables the shimmer/waveform animations.
    private var reducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

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

    /// Replaces the recording pill's caption text (e.g. a live partial
    /// transcript). No-op outside the recording state.
    func updateCaption(_ text: String) {
        performOnMain { self.updateCaptionOnMain(text) }
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
        layoutContent(animated: false)
        if panel.isVisible {
            positionPanel(initial: false, animated: false)
            panel.alphaValue = 1
            logShown(state)
            return
        }
        positionPanel(initial: true, animated: false)
        animateIn()
        logShown(state)
    }

    private func hideOnMain() {
        stopTimer()
        stopShimmer()
        recordingStartedAt = nil
        currentState = nil
        isHovering = false
        warningActive = false
        // Clear any drag flag stranded by a gesture interrupted while hiding, so
        // the next show can reposition normally.
        isDraggingPill = false
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

    private func updateCaptionOnMain(_ text: String) {
        guard isRecording(currentState) else { return }
        recordingCaption = text
        applyVisuals()
        relayout()
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
        let height: CGFloat = WaveformMapping.barHeight(
            dbfs: dbfs,
            minDBFS: Self.minDBFS,
            maxDBFS: Self.maxDBFS,
            minHeight: Self.minBarHeight,
            maxHeight: Self.maxBarHeight
        )
        levelHistory.removeFirst()
        levelHistory.append(height)
        guard !warningActive else { return }
        paintBars(animated: !reducedMotion)
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
        // Semi-transparent so the pill obscures as little of the screen
        // beneath it as possible.
        effect.alphaValue = 0.55
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.maskImage = Self.roundedRectMask(cornerRadius: Self.cornerRadius)
        // Views don't clip subviews by default on macOS 14 — without this the
        // badge/label can render outside the capsule as detached fragments
        // while the panel frame animates.
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.autoresizingMask = [.width, .height]
        effect.onClick = { [weak self] in self?.onToggle?() }
        effect.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        effect.menuProvider = { [weak self] in self?.buildContextMenu() }
        effect.onDragEnded = { [weak self] center in self?.handleDragEnded(center) }
        effect.onDragStateChanged = { [weak self] dragging in self?.isDraggingPill = dragging }
        effect.onBadgeClick = { [weak self] in self?.cycleLanguageBadge() }

        // Bottom-most: a color wash (only visible during the warning state)
        // sitting directly on the blur, beneath every other element.
        washView = NSView(frame: contentRect)
        washView.wantsLayer = true
        washView.autoresizingMask = [.width, .height]
        washView.layer?.cornerRadius = Self.cornerRadius
        washView.layer?.masksToBounds = true
        washView.layer?.backgroundColor = NSColor.clear.cgColor
        effect.addSubview(washView)

        iconView = NSImageView(frame: .zero)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(iconView)

        globeIconView = NSImageView(frame: .zero)
        globeIconView.imageScaling = .scaleProportionallyUpOrDown
        globeIconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Language")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        globeIconView.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        globeIconView.isHidden = true
        effect.addSubview(globeIconView)

        notesIconView = NSImageView(frame: .zero)
        notesIconView.imageScaling = .scaleProportionallyUpOrDown
        notesIconView.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Scratchpad")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        notesIconView.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        notesIconView.isHidden = true
        effect.addSubview(notesIconView)

        meetingIconView = NSImageView(frame: .zero)
        meetingIconView.imageScaling = .scaleProportionallyUpOrDown
        meetingIconView.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Meeting notes")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        meetingIconView.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        meetingIconView.isHidden = true
        effect.addSubview(meetingIconView)

        stackCircleViews = (0..<4).map { _ in
            let circle: NSView = NSView(frame: .zero)
            circle.wantsLayer = true
            circle.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            circle.layer?.cornerRadius = Self.dockCircleDiameter / 2
            circle.isHidden = true
            effect.addSubview(circle, positioned: .below, relativeTo: iconView)
            return circle
        }

        tooltipView = NSView(frame: .zero)
        tooltipView.wantsLayer = true
        tooltipView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        tooltipView.layer?.cornerRadius = 14
        tooltipView.isHidden = true
        effect.addSubview(tooltipView)
        tooltipLabel = NSTextField(labelWithString: "")
        tooltipLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        tooltipLabel.textColor = .white
        tooltipView.addSubview(tooltipLabel)

        effect.onGlobeClick = { [weak self] in self?.cycleLanguageBadge() }
        effect.onNotesClick = { [weak self] in self?.onOpenScratchpad?() }
        effect.onMeetingClick = { [weak self] in self?.onToggleMeeting?() }
        effect.onMouseMoved = { [weak self] point in self?.stackMouseMoved(point) }

        handsFreeDotView = NSView(frame: .zero)
        handsFreeDotView.wantsLayer = true
        handsFreeDotView.layer?.cornerRadius = Self.handsFreeDotDiameter / 2
        handsFreeDotView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        handsFreeDotView.isHidden = true
        effect.addSubview(handsFreeDotView)

        textLabel = NSTextField(labelWithString: "")
        textLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        textLabel.textColor = .white
        textLabel.cell?.lineBreakMode = .byTruncatingHead
        effect.addSubview(textLabel)

        elapsedLabel = NSTextField(labelWithString: "0:00")
        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        elapsedLabel.alignment = .right
        effect.addSubview(elapsedLabel)

        badgeChip = NSView(frame: .zero)
        badgeChip.wantsLayer = true
        badgeChip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        badgeChip.layer?.cornerRadius = 9
        effect.addSubview(badgeChip)
        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        badgeLabel.alignment = .center
        badgeChip.addSubview(badgeLabel)

        barViews = (0..<Self.barCount).map { (index: Int) -> NSView in
            let bar: NSView = NSView(frame: .zero)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = Self.barTint(atFraction: CGFloat(index) / CGFloat(max(Self.barCount - 1, 1))).cgColor
            bar.layer?.cornerRadius = Self.barWidth / 2
            bar.alphaValue = 1.0
            effect.addSubview(bar)
            return bar
        }

        // A single soft strip that stands in for the waveform while
        // transcribing/cleaning — a working pulse instead of a spinner.
        shimmerView = NSView(frame: .zero)
        shimmerView.wantsLayer = true
        shimmerView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        shimmerView.layer?.cornerRadius = 2
        shimmerView.isHidden = true
        effect.addSubview(shimmerView)

        // Top-most: a hairline border. Kept as a separate, non-blurred view
        // (rather than styling `effect`'s own layer) so the visual-effect
        // view's translucency is untouched.
        borderView = NSView(frame: contentRect)
        borderView.wantsLayer = true
        borderView.autoresizingMask = [.width, .height]
        borderView.layer?.cornerRadius = Self.cornerRadius
        borderView.layer?.borderWidth = 1
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        effect.addSubview(borderView)

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

    /// Linear blend between systemBlue and systemIndigo across the bar index,
    /// giving the waveform a subtle accent gradient instead of flat white.
    private static func barTint(atFraction fraction: CGFloat) -> NSColor {
        let start: NSColor = NSColor.systemBlue.usingColorSpace(.deviceRGB) ?? .white
        let end: NSColor = NSColor.systemIndigo.usingColorSpace(.deviceRGB) ?? .white
        let t: CGFloat = min(max(fraction, 0), 1)
        return NSColor(
            red: start.redComponent + (end.redComponent - start.redComponent) * t,
            green: start.greenComponent + (end.greenComponent - start.greenComponent) * t,
            blue: start.blueComponent + (end.blueComponent - start.blueComponent) * t,
            alpha: 0.9
        )
    }

    // MARK: - Context menu

    private func buildContextMenu() -> NSMenu {
        let menu: NSMenu = NSMenu()
        if Config.hudHasCustomPosition {
            let resetItem: NSMenuItem = NSMenuItem(
                title: "Reset Flow-Bar Position",
                action: #selector(menuResetPosition),
                keyEquivalent: ""
            )
            resetItem.target = self
            menu.addItem(resetItem)
            menu.addItem(.separator())
        }
        let languageRoot: NSMenuItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.addItem(languageRoot)
        menu.setSubmenu(buildLanguageMenu(), for: languageRoot)
        menu.addItem(.separator())
        if Config.claudePipeEnabled {
            let dictateToClaude: NSMenuItem = NSMenuItem(
                title: "Dictate to Claude",
                action: #selector(menuDictateToClaude),
                keyEquivalent: ""
            )
            dictateToClaude.target = self
            menu.addItem(dictateToClaude)
            menu.addItem(.separator())
        }
        let captureItem: NSMenuItem = NSMenuItem(
            title: "Capture Mode",
            action: #selector(menuToggleCapture),
            keyEquivalent: ""
        )
        captureItem.target = self
        captureItem.state = (captureModeIsActive?() ?? false) ? .on : .off
        menu.addItem(captureItem)
        let meetingItem: NSMenuItem = NSMenuItem(
            title: "Meeting Notes",
            action: #selector(menuToggleMeeting),
            keyEquivalent: ""
        )
        meetingItem.target = self
        meetingItem.state = (meetingModeIsActive?() ?? false) ? .on : .off
        menu.addItem(meetingItem)
        menu.addItem(.separator())
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
    @objc private func menuDictateToClaude() { onDictateToClaude?() }
    @objc private func menuToggleCapture() { onToggleCapture?() }
    @objc private func menuToggleMeeting() { onToggleMeeting?() }
    @objc private func menuResetPosition() { resetPosition() }
    @objc private func menuSelectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        onSelectLanguage?(code)
    }

    /// The 3 most recent languages + Auto, then a "More Languages" submenu
    /// (supplied by `moreLanguagesMenuProvider`) for everything else.
    private func buildLanguageMenu() -> NSMenu {
        let sub: NSMenu = NSMenu()
        var codes: [String] = Array(Config.languageRecents.prefix(3))
        if !codes.contains("auto") {
            codes.append("auto")
        }
        for code in codes {
            let item: NSMenuItem = NSMenuItem(
                title: languageDisplayName(code),
                action: #selector(menuSelectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = code
            item.state = Config.whisperLanguage == code ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let moreRoot: NSMenuItem = NSMenuItem(title: "More Languages", action: nil, keyEquivalent: "")
        sub.addItem(moreRoot)
        sub.setSubmenu(moreLanguagesMenuProvider?() ?? NSMenu(), for: moreRoot)
        return sub
    }

    private func languageDisplayName(_ code: String) -> String {
        switch code {
        case "auto": return "Auto-detect"
        case "hinglish": return "Hinglish (Roman mix)"
        default: return Config.whisperLanguages.first { $0.code == code }?.name ?? code.uppercased()
        }
    }

    // MARK: - Hover

    /// Pops the language menu at the badge — visible feedback beats the old
    /// silent cycle-through-recents, which read as "nothing happened".
    private func cycleLanguageBadge() {
        let menu: NSMenu = buildLanguageMenu()
        let origin: NSPoint = NSPoint(x: badgeChip.frame.minX, y: badgeChip.frame.minY - 4)
        menu.popUp(positioning: nil, at: origin, in: contentView)
    }

    private var hoverCollapseWork: DispatchWorkItem?

    /// Hover-in applies immediately; hover-out is debounced. The animated
    /// resize moves the tracking rect under the cursor, which can fire
    /// spurious exit/enter pairs mid-animation — without the delay those
    /// re-trigger the resize and the pill visibly jitters.
    /// Tracks which hover-stack button the cursor is over, highlighting its
    /// circle and showing the Wispr-style tooltip pill beside it.
    private func stackMouseMoved(_ point: NSPoint) {
        guard !globeIconView.isHidden else { return }
        let frames: [NSRect?] = [
            contentView.globeHitFrame,
            contentView.micHitFrame,
            contentView.notesHitFrame,
            contentView.meetingHitFrame,
        ]
        let hit: Int? = frames.firstIndex { $0?.contains(point) == true }
        if hit != hoveredStackIndex {
            hoveredStackIndex = hit
            updateStackHoverAndMask()
        }
    }

    private func updateStackHover() {
        for (index, circle) in stackCircleViews.enumerated() {
            let highlighted: Bool = index == hoveredStackIndex
            circle.layer?.backgroundColor = highlighted
                ? NSColor(white: 0.25, alpha: 0.95).cgColor
                : NSColor.black.withAlphaComponent(0.85).cgColor
        }
        guard let index = hoveredStackIndex else {
            tooltipView.isHidden = true
            return
        }
        tooltipLabel.stringValue = Self.stackTooltips[index]
        tooltipLabel.sizeToFit()
        let textSize: NSSize = tooltipLabel.frame.size
        let tooltipSize: NSSize = NSSize(width: textSize.width + 24, height: 28)
        let circleFrame: NSRect = stackCircleViews[index].frame
        if stackAxisVertical {
            let onRight: Bool = Config.hudDockSide != "left"
            let tooltipX: CGFloat = onRight
                ? circleFrame.minX - 8 - tooltipSize.width
                : circleFrame.maxX + 8
            tooltipView.frame = NSRect(
                x: tooltipX,
                y: circleFrame.midY - tooltipSize.height / 2,
                width: tooltipSize.width,
                height: tooltipSize.height
            )
        } else {
            let bounds: NSRect = contentView.bounds
            let clampedX: CGFloat = min(
                max(circleFrame.midX - tooltipSize.width / 2, 2),
                bounds.width - tooltipSize.width - 2
            )
            tooltipView.frame = NSRect(
                x: clampedX,
                y: circleFrame.maxY + 8,
                width: tooltipSize.width,
                height: tooltipSize.height
            )
        }
        tooltipLabel.frame = NSRect(
            x: (tooltipSize.width - textSize.width) / 2,
            y: (tooltipSize.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        tooltipView.isHidden = false
    }

    private func updateStackHoverAndMask() {
        updateStackHover()
        refreshStackMask()
    }

    private func hoverChanged(_ hovering: Bool) {
        hoverCollapseWork?.cancel()
        hoverCollapseWork = nil
        if hovering {
            applyHover(true)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.applyHover(false) }
            hoverCollapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    private func applyHover(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        // Only the idle/meeting pill changes shape on hover (collapsed icon
        // ↔ hint). Instant relayout: an animated panel resize leaves the
        // (already target-positioned) content misaligned mid-animation.
        guard isIdle(currentState) || isMeeting(currentState) else { return }
        applyVisuals()
        relayout(animated: false)
    }

    // MARK: - State application

    private func applyState(_ state: HUDState, continuingRecording: Bool) {
        let recording: Bool = isRecording(state)
        let busy: Bool = isBusy(state)
        if recording {
            if !continuingRecording || recordingStartedAt == nil {
                recordingStartedAt = Date()
                recordingCaption = ""
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
            recordingCaption = ""
            resetBars()
        }
        elapsedLabel.isHidden = true
        for bar in barViews {
            bar.isHidden = !recording
        }
        shimmerView.isHidden = !busy
        if busy {
            startShimmer()
        } else {
            stopShimmer()
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
            iconColor = NSColor.white.withAlphaComponent(isHovering ? 0.85 : 0.6)
            text = "Hold ⌥ or click to dictate"
            showText = false
        case .recording:
            if warningActive {
                symbolName = "exclamationmark.triangle.fill"
                iconColor = .systemOrange
                text = "No mic input — check input volume"
            } else {
                symbolName = "mic.fill"
                iconColor = .systemRed
                text = ""
                showText = false
            }
        case .transcribing:
            symbolName = "waveform"
            iconColor = .white
            text = "Transcribing…"
            showText = false
        case .cleaning:
            symbolName = "sparkles"
            iconColor = .white
            text = "Cleaning…"
            showText = false
        case .warning(let message):
            symbolName = "exclamationmark.triangle.fill"
            iconColor = .systemOrange
            text = message
        case .meeting:
            symbolName = "record.circle"
            iconColor = .systemRed
            text = "Meeting notes on — click to stop"
            showText = isHovering
        }
        let config: NSImage.SymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image: NSImage? = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)
        iconView.image = image?.withSymbolConfiguration(config)
        iconView.contentTintColor = iconColor
        // Recording is signalled by the waveform and busy by the shimmer, so
        // the glyph only earns its space when the pill is idle or warning.
        // A side-docked idle sliver has no room for it until hovered.
        let docked: Bool = isDockedVertical
        switch state {
        case .recording: iconView.isHidden = !warningActive
        case .transcribing, .cleaning: iconView.isHidden = true
        case .idle: iconView.isHidden = !isHovering
        default: iconView.isHidden = false
        }
        if docked {
            textLabel.isHidden = true
            badgeLabel.isHidden = true
            badgeChip.isHidden = true
            handsFreeDotView.isHidden = true
        }
        // Also shown during a meeting so the red meeting button can stop it.
        let showHoverStack: Bool = (isIdle(state) || isMeeting(state)) && isHovering
        globeIconView.isHidden = !showHoverStack
        notesIconView.isHidden = !showHoverStack
        meetingIconView.isHidden = !showHoverStack
        let meetingOn: Bool = meetingModeIsActive?() ?? false
        meetingIconView.contentTintColor = meetingOn
            ? .systemRed
            : NSColor.white.withAlphaComponent(0.8)
        for circle in stackCircleViews {
            circle.isHidden = !showHoverStack
        }
        if !showHoverStack {
            hoveredStackIndex = nil
            tooltipView.isHidden = true
        }
        textLabel.stringValue = showText ? text : ""
        textLabel.isHidden = !showText
        // The hover stack's globe button replaced the language badge.
        let showBadge: Bool = false
        badgeLabel.stringValue = showBadge ? Config.languageBadge(for: Config.whisperLanguage) : ""
        badgeLabel.isHidden = !showBadge
        badgeChip.isHidden = !showBadge
        badgeChip.alphaValue = (showBadge && !isHovering) ? 0.7 : 1.0
        handsFreeDotView.isHidden = !isHandsFree(state)

        let isWarningWash: Bool
        switch state {
        case .warning: isWarningWash = true
        case .recording: isWarningWash = warningActive
        default: isWarningWash = false
        }
        washView.layer?.backgroundColor = isWarningWash
            ? NSColor.systemOrange.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
    }

    private func isRecording(_ state: HUDState?) -> Bool {
        guard let state: HUDState = state else { return false }
        if case .recording = state {
            return true
        }
        return false
    }

    private func isMeeting(_ state: HUDState?) -> Bool {
        guard let state: HUDState = state else { return false }
        if case .meeting = state {
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

    /// Transcribing/cleaning are both a "the pill is working, no input" state
    /// that shows the shimmer strip instead of the waveform.
    private func isBusy(_ state: HUDState?) -> Bool {
        guard let state: HUDState = state else { return false }
        switch state {
        case .transcribing, .cleaning: return true
        default: return false
        }
    }

    private func isHandsFree(_ state: HUDState?) -> Bool {
        if case .recording(let handsFree) = state { return handsFree }
        return false
    }

    // MARK: - Layout

    private func relayout(animated: Bool = false) {
        guard let panel: NSPanel = panel, panel.isVisible else { return }
        let shouldAnimate: Bool = animated && !reducedMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { (context: NSAnimationContext) in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.layoutContent(animated: true)
                self.positionPanel(initial: false, animated: true)
            }
        } else {
            layoutContent(animated: false)
            positionPanel(initial: false, animated: false)
        }
    }

    /// Assigns `frame` to `view`, going through the animator proxy (so it
    /// participates in an enclosing `NSAnimationContext` group) only when
    /// `animated` is true; otherwise it's an instant, unanimated set.
    /// Subviews always jump straight to their target frame — animating them
    /// on a separate track from the panel-frame animation is what tore the
    /// pill apart visually. The panel resize is the only animated element.
    private func setFrame(_ frame: NSRect, on view: NSView, animated: Bool) {
        view.frame = frame
    }

    /// The mask image doubles as the layer mask for every subview, so the
    /// hover stack's mask must be the union of its visible shapes (circles +
    /// tooltip), not empty: an empty mask blanks the buttons themselves.
    private func refreshStackMask() {
        let size: NSSize = contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let circleFrames: [NSRect] = stackCircleViews.map { $0.frame }
        let tooltipFrame: NSRect? = tooltipView.isHidden ? nil : tooltipView.frame
        let mask: NSImage = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for frame in circleFrames {
                NSBezierPath(ovalIn: frame).fill()
            }
            if let tooltipFrame {
                NSBezierPath(roundedRect: tooltipFrame, xRadius: 14, yRadius: 14).fill()
            }
            return true
        }
        contentView.maskImage = mask
    }

    /// Capsule rounding must track the pill's smallest dimension: the docked
    /// sliver is far narrower than the resting corner radius, and a stale wide
    /// radius renders it as a blob instead of a capsule.
    private func applyCornerRadius(for size: NSSize) {
        let radius: CGFloat = min(Self.cornerRadius, size.width / 2, size.height / 2)
        contentView.maskImage = Self.roundedRectMask(cornerRadius: radius)
        contentView.layer?.cornerRadius = radius
        washView.layer?.cornerRadius = radius
        borderView.layer?.cornerRadius = radius
    }

    private var isDockedVertical: Bool {
        let side: String = Config.hudDockSide
        return side == "left" || side == "right"
    }

    /// True while the visible hover stack is the side-dock column (tooltips
    /// beside the buttons); false for the horizontal row (tooltips above).
    private var stackAxisVertical = false

    /// Places the four stack circles + icons and hit frames. Vertical axis:
    /// a column flush to the docked edge. Horizontal axis: a centered row
    /// along the bottom of the panel, tooltip space above.
    private func layoutStackButtons(size: NSSize, verticalAxis: Bool) {
        stackAxisVertical = verticalAxis
        contentView.layer?.cornerRadius = 0
        contentView.alphaValue = 1
        borderView.isHidden = true
        let diameter: CGFloat = Self.dockCircleDiameter
        let pitch: CGFloat = Self.dockButtonPitch
        let icons: [NSImageView] = [globeIconView, iconView, notesIconView, meetingIconView]
        for index in 0..<4 {
            let offset: CGFloat = (1.5 - CGFloat(index)) * pitch
            let center: NSPoint
            if verticalAxis {
                let onRight: Bool = Config.hudDockSide != "left"
                let x: CGFloat = onRight
                    ? size.width - Self.dockPadding - diameter / 2
                    : Self.dockPadding + diameter / 2
                center = NSPoint(x: x, y: size.height / 2 + offset)
            } else {
                center = NSPoint(x: size.width / 2 - offset, y: Self.dockPadding + diameter / 2)
            }
            setFrame(
                NSRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ),
                on: stackCircleViews[index],
                animated: false
            )
            setFrame(
                NSRect(
                    x: center.x - Self.iconSize / 2,
                    y: center.y - Self.iconSize / 2,
                    width: Self.iconSize,
                    height: Self.iconSize
                ),
                on: icons[index],
                animated: false
            )
        }
        contentView.globeHitFrame = stackCircleViews[0].frame.insetBy(dx: -4, dy: -4)
        contentView.micHitFrame = stackCircleViews[1].frame.insetBy(dx: -4, dy: -4)
        contentView.notesHitFrame = stackCircleViews[2].frame.insetBy(dx: -4, dy: -4)
        contentView.meetingHitFrame = stackCircleViews[3].frame.insetBy(dx: -4, dy: -4)
        updateStackHoverAndMask()
    }

    /// Side-docked layout: everything renders as a narrow vertical pill.
    private func layoutVertical(animated: Bool) {
        let recording: Bool = isRecording(currentState)
        let busy: Bool = isBusy(currentState)
        let showIcon: Bool = !iconView.isHidden
        let meterLength: CGFloat = Self.meterWidth

        let hoverStack: Bool = !globeIconView.isHidden

        let size: NSSize
        if recording && !warningActive {
            size = NSSize(width: Self.dockActiveWidth, height: meterLength + Self.dockPadding * 2)
        } else if busy {
            size = NSSize(width: Self.dockActiveWidth, height: meterLength + Self.dockPadding * 2)
        } else if hoverStack {
            // Wide transparent canvas: a column of circles flush to the docked
            // edge plus room for the tooltip pill beside the hovered button.
            size = NSSize(width: 190, height: Self.dockButtonPitch * 4 + Self.dockPadding * 2)
        } else if showIcon {
            size = NSSize(width: Self.dockIdleHoverWidth + 4, height: Self.dockIdleHoverWidth + 4)
        } else {
            size = NSSize(width: Self.dockIdleWidth, height: Self.dockIdleHeight)
        }

        let center: NSPoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var panelFrame: NSRect = panel.frame
        panelFrame.size = size
        panelFrame.origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if animated {
            panel.animator().setFrame(panelFrame, display: true)
        } else {
            panel.setFrame(panelFrame, display: false)
        }
        applyCornerRadius(for: size)

        // The idle sliver reads as a bright outline (like Wispr's docked tab);
        // every other state keeps the standard faint hairline.
        let sliver: Bool = !recording && !busy && !showIcon && !hoverStack
        borderView.layer?.borderColor = NSColor.white
            .withAlphaComponent(sliver ? 0.7 : 0.08).cgColor

        contentView.badgeHitFrame = nil
        contentView.globeHitFrame = nil
        contentView.notesHitFrame = nil
        contentView.meetingHitFrame = nil
        contentView.micHitFrame = nil
        // The stack renders as free-floating circles on a transparent canvas;
        // every other docked state is the usual blurred capsule.
        contentView.alphaValue = hoverStack ? 1 : 0.55
        borderView.isHidden = hoverStack
        let midX: CGFloat = size.width / 2
        if hoverStack {
            layoutStackButtons(size: size, verticalAxis: true)
        } else if showIcon {
            setFrame(
                NSRect(
                    x: midX - Self.iconSize / 2,
                    y: size.height / 2 - Self.iconSize / 2,
                    width: Self.iconSize,
                    height: Self.iconSize
                ),
                on: iconView,
                animated: animated
            )
        }
        if recording {
            let topY: CGFloat = (size.height - meterLength) / 2
            for (index, bar) in barViews.enumerated() {
                let barLength: CGFloat = max(bar.frame.width, Self.minBarHeight)
                setFrame(
                    NSRect(
                        x: midX - barLength / 2,
                        y: topY + CGFloat(index) * (Self.barWidth + Self.barSpacing),
                        width: barLength,
                        height: Self.barWidth
                    ),
                    on: bar,
                    animated: animated
                )
            }
        } else if busy {
            setFrame(
                NSRect(x: midX - 2, y: (size.height - meterLength) / 2, width: 4, height: meterLength),
                on: shimmerView,
                animated: animated
            )
        }
    }

    private func layoutContent(animated: Bool) {
        if isDockedVertical {
            layoutVertical(animated: animated)
            return
        }
        borderView.isHidden = false
        contentView.alphaValue = 0.55
        contentView.globeHitFrame = nil
        contentView.notesHitFrame = nil
        contentView.meetingHitFrame = nil
        contentView.micHitFrame = nil
        contentView.badgeHitFrame = nil

        // Untouched idle pill minimizes to a thin Wispr-style bar; hovering
        // (or any active state) restores the full capsule.
        if isIdle(currentState) && !isHovering {
            let size: NSSize = NSSize(width: 44, height: 8)
            let center: NSPoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            var panelFrame: NSRect = panel.frame
            panelFrame.size = size
            panelFrame.origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
            if animated {
                panel.animator().setFrame(panelFrame, display: true)
            } else {
                panel.setFrame(panelFrame, display: false)
            }
            applyCornerRadius(for: size)
            borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
            return
        }

        // Idle/meeting + hovering (not side-docked): the option buttons as a
        // horizontal row, tooltip space above.
        if (isIdle(currentState) || isMeeting(currentState)) && isHovering {
            let size: NSSize = NSSize(
                width: Self.dockButtonPitch * 4 + Self.dockPadding * 2,
                height: Self.dockPadding + Self.dockCircleDiameter + 44
            )
            let center: NSPoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            var panelFrame: NSRect = panel.frame
            panelFrame.size = size
            panelFrame.origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
            if animated {
                panel.animator().setFrame(panelFrame, display: true)
            } else {
                panel.setFrame(panelFrame, display: false)
            }
            layoutStackButtons(size: size, verticalAxis: false)
            return
        }
        applyCornerRadius(for: NSSize(width: Self.minPillWidth, height: Self.pillHeight))
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        textLabel.sizeToFit()
        elapsedLabel.sizeToFit()
        badgeLabel.sizeToFit()
        let recording: Bool = isRecording(currentState)
        let busy: Bool = isBusy(currentState)
        let showText: Bool = !textLabel.isHidden && !textLabel.stringValue.isEmpty
        let showBadge: Bool = !badgeLabel.isHidden && !badgeLabel.stringValue.isEmpty
        let idleCollapsed: Bool = isIdle(currentState) && !showText
        let captionMode: Bool = recording && !recordingCaption.isEmpty
        let textWidth: CGFloat = captionMode
            ? min(textLabel.frame.width, Self.maxCaptionWidth)
            : textLabel.frame.width

        let showIcon: Bool = !iconView.isHidden
        var width: CGFloat = Self.horizontalPadding
        if showIcon {
            width += Self.iconSize
        }
        if showText {
            width += (showIcon ? Self.elementGap : 0) + textWidth
        }
        if recording || busy {
            width += ((showIcon || showText) ? Self.elementGap : 0) + Self.meterWidth
        }
        if showBadge {
            width += Self.elementGap + badgeLabel.frame.width + 12
        }
        width += Self.horizontalPadding
        width = max(width, Self.minIdleWidth)

        // Resize about the pill's center so a width change (idle↔recording or
        // hover-expand) grows symmetrically instead of from the bottom-left
        // corner — this keeps a dragged pill under the cursor even if it resizes
        // mid-gesture, and centers the growth for everyone else.
        let center: NSPoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var panelFrame: NSRect = panel.frame
        panelFrame.size = NSSize(width: width, height: Self.pillHeight)
        panelFrame.origin = NSPoint(x: center.x - width / 2, y: center.y - Self.pillHeight / 2)
        if animated {
            panel.animator().setFrame(panelFrame, display: true)
        } else {
            panel.setFrame(panelFrame, display: false)
        }

        let midY: CGFloat = Self.pillHeight / 2

        // Idle-collapsed pill is just a centered mic glyph plus the badge.
        if idleCollapsed {
            let chipWidth: CGFloat = badgeLabel.frame.width + 12
            let iconWidth: CGFloat = showBadge ? Self.iconSize + Self.elementGap + chipWidth : Self.iconSize
            let iconX: CGFloat = (width - iconWidth) / 2
            setFrame(
                NSRect(x: iconX, y: midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize),
                on: iconView,
                animated: animated
            )
            positionHandsFreeDot(animated: animated)
            layoutBadge(showBadge: showBadge, x: iconX + Self.iconSize + Self.elementGap, midY: midY, animated: animated)
            return
        }

        setFrame(
            NSRect(x: Self.horizontalPadding, y: midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize),
            on: iconView,
            animated: animated
        )
        positionHandsFreeDot(animated: animated)

        if showText {
            let labelX: CGFloat = Self.horizontalPadding + Self.iconSize + Self.elementGap
            let labelHeight: CGFloat = textLabel.frame.height
            setFrame(
                NSRect(x: labelX, y: midY - labelHeight / 2, width: textWidth, height: labelHeight),
                on: textLabel,
                animated: animated
            )
        }

        let badgeX: CGFloat = width - Self.horizontalPadding - (badgeLabel.frame.width + 12)
        layoutBadge(showBadge: showBadge, x: badgeX, midY: midY, animated: animated)

        if recording {
            let meterX: CGFloat = width - Self.horizontalPadding - Self.meterWidth
            for (index, bar) in barViews.enumerated() {
                let barHeight: CGFloat = max(bar.frame.height, Self.minBarHeight)
                setFrame(
                    NSRect(
                        x: meterX + CGFloat(index) * (Self.barWidth + Self.barSpacing),
                        y: midY - barHeight / 2,
                        width: Self.barWidth,
                        height: barHeight
                    ),
                    on: bar,
                    animated: animated
                )
            }
            let elapsedHeight: CGFloat = elapsedLabel.frame.height
            setFrame(
                NSRect(
                    x: meterX - Self.elementGap - Self.elapsedWidth,
                    y: midY - elapsedHeight / 2,
                    width: Self.elapsedWidth,
                    height: elapsedHeight
                ),
                on: elapsedLabel,
                animated: animated
            )
        } else if busy {
            let shimmerX: CGFloat = width - Self.horizontalPadding - Self.meterWidth
            setFrame(
                NSRect(x: shimmerX, y: midY - 2, width: Self.meterWidth, height: 4),
                on: shimmerView,
                animated: animated
            )
        }
    }

    /// Positions the language badge and updates the click hit-target the
    /// content view checks before falling back to the plain-pill toggle.
    /// Padded a few points beyond the visible glyph so it's easy to tap.
    private func layoutBadge(showBadge: Bool, x: CGFloat, midY: CGFloat, animated: Bool) {
        guard showBadge else {
            contentView.badgeHitFrame = nil
            return
        }
        let textSize: NSSize = badgeLabel.frame.size
        let chipHeight: CGFloat = 18
        let chipWidth: CGFloat = textSize.width + 12
        let chipFrame: NSRect = NSRect(x: x, y: midY - chipHeight / 2, width: chipWidth, height: chipHeight)
        setFrame(chipFrame, on: badgeChip, animated: animated)
        badgeLabel.frame = NSRect(
            x: (chipWidth - textSize.width) / 2,
            y: (chipHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        contentView.badgeHitFrame = chipFrame.insetBy(dx: -6, dy: -6)
    }

    /// A small dot overlaid on the mic glyph's corner, shown only while
    /// hands-free recording is active — doesn't need its own layout slot.
    private func positionHandsFreeDot(animated: Bool) {
        let frame: NSRect = NSRect(
            x: iconView.frame.maxX - Self.handsFreeDotDiameter * 0.6,
            y: iconView.frame.maxY - Self.handsFreeDotDiameter * 0.6,
            width: Self.handsFreeDotDiameter,
            height: Self.handsFreeDotDiameter
        )
        setFrame(frame, on: handsFreeDotView, animated: animated)
    }

    // MARK: - Positioning

    /// Restores the user's dragged position when one is saved; otherwise snaps
    /// to bottom-center of the cursor's screen (first show) or the pill's
    /// current screen (subsequent relayouts).
    private func positionPanel(initial: Bool, animated: Bool) {
        guard !isDraggingPill else { return }
        if Config.hudHasCustomPosition {
            var center: CGPoint = clampOnScreen(Config.hudCenter)
            // A docked pill re-derives its x from the edge on every pass, so a
            // state-change width difference can't peel it off the edge.
            let dock: String = Config.hudDockSide
            if !dock.isEmpty,
               let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
                let frame: NSRect = screen.visibleFrame
                let halfW: CGFloat = panel.frame.width / 2
                switch dock {
                case "left": center.x = frame.minX + Self.edgeInset + halfW
                case "right": center.x = frame.maxX - Self.edgeInset - halfW
                case "bottom": center.y = screen.frame.minY + Self.edgeInset + panel.frame.height / 2
                default: break
                }
            }
            setCenter(center, animated: animated)
            return
        }
        let target: NSScreen? = initial ? cursorScreen() : (panel.screen ?? NSScreen.main)
        guard let screen: NSScreen = target else { return }
        setOrigin(bottomCenteredOn: screen, animated: animated)
    }

    private func cursorScreen() -> NSScreen? {
        let mouse: NSPoint = NSEvent.mouseLocation
        let hit: NSScreen? = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        return hit ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func setOrigin(bottomCenteredOn screen: NSScreen, animated: Bool) {
        let screenFrame: NSRect = screen.frame
        let origin: NSPoint = NSPoint(
            x: screenFrame.midX - panel.frame.width / 2,
            y: screenFrame.minY + Self.bottomMargin
        )
        if animated {
            panel.animator().setFrameOrigin(origin)
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    private func setCenter(_ center: CGPoint, animated: Bool) {
        let origin: NSPoint = NSPoint(
            x: center.x - panel.frame.width / 2,
            y: center.y - panel.frame.height / 2
        )
        if animated {
            panel.animator().setFrameOrigin(origin)
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    /// Keeps a saved center inside some screen's visible area so a position
    /// saved on a now-disconnected display (or nudged past an edge) can't
    /// strand the pill off-screen. Prefers the screen containing the point,
    /// else the nearest one.
    private func clampOnScreen(_ center: CGPoint) -> CGPoint {
        let screens: [NSScreen] = NSScreen.screens
        guard !screens.isEmpty else { return center }
        let host: NSScreen? = screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? screens.min { squaredDistance(from: center, to: $0.frame) < squaredDistance(from: center, to: $1.frame) }
            ?? NSScreen.main
        guard let frame: NSRect = host?.visibleFrame else { return center }
        let halfW: CGFloat = panel.frame.width / 2
        let halfH: CGFloat = panel.frame.height / 2
        let x: CGFloat = min(max(center.x, frame.minX + halfW), frame.maxX - halfW)
        let y: CGFloat = min(max(center.y, frame.minY + halfH), frame.maxY - halfH)
        return CGPoint(x: x, y: y)
    }

    private func squaredDistance(from point: CGPoint, to rect: NSRect) -> CGFloat {
        let nx: CGFloat = min(max(point.x, rect.minX), rect.maxX)
        let ny: CGFloat = min(max(point.y, rect.minY), rect.maxY)
        return (point.x - nx) * (point.x - nx) + (point.y - ny) * (point.y - ny)
    }

    // MARK: - Drag persistence

    /// Release within this distance of a screen's left/right edge docks the
    /// pill flush to that edge.
    private static let edgeSnapMargin: CGFloat = 48
    private static let bottomSnapMargin: CGFloat = 120
    private static let edgeInset: CGFloat = 4

    private func handleDragEnded(_ center: CGPoint) {
        var snapped: CGPoint = center
        var dock: String = ""
        // Nearest-screen fallback: edge drops routinely overshoot the screen
        // bounds by a few points, and a containment-only lookup then skips
        // snapping entirely.
        let dropScreen: NSScreen? = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.screens.min {
                squaredDistance(from: center, to: $0.frame) < squaredDistance(from: center, to: $1.frame)
            }
        if let screen = dropScreen {
            let frame: NSRect = screen.visibleFrame
            let halfW: CGFloat = panel.frame.width / 2
            if center.x - halfW < frame.minX + Self.edgeSnapMargin {
                snapped.x = frame.minX + Self.edgeInset + halfW
                dock = "left"
            } else if center.x + halfW > frame.maxX - Self.edgeSnapMargin {
                snapped.x = frame.maxX - Self.edgeInset - halfW
                dock = "right"
            } else if center.y - panel.frame.height / 2 < frame.minY + Self.bottomSnapMargin {
                // Bottom snap pins flush to the PHYSICAL screen edge (not the
                // visible frame): the panel floats above the Dock, and sitting
                // at visibleFrame.minY reads as "won't stay at the bottom".
                // The zone is deliberately generous: drops aimed at "the
                // bottom" land tens of points above the actual edge.
                snapped.y = screen.frame.minY + Self.edgeInset + panel.frame.height / 2
                dock = "bottom"
            }
        }
        let dockChanged: Bool = dock != Config.hudDockSide
        Config.hudHasCustomPosition = true
        Config.hudCenter = snapped
        Config.hudDockSide = dock
        if dockChanged {
            applyVisuals()
            relayout(animated: true)
        } else if snapped != center {
            setCenter(snapped, animated: true)
        }
        Log.info("Flow-Bar moved to (\(Int(snapped.x)), \(Int(snapped.y))) dock=\(dock.isEmpty ? "none" : dock)")
    }

    /// Clears the saved position and snaps the pill back to bottom-center.
    func resetPosition() {
        performOnMain {
            Config.hudHasCustomPosition = false
            Config.hudDockSide = ""
            guard let panel: NSPanel = self.panel, panel.isVisible else { return }
            self.positionPanel(initial: false, animated: false)
            Log.info("Flow-Bar position reset to default")
        }
    }

    private func logShown(_ state: HUDState) {
        // Only the resting/active states carry a meaningful position; the
        // transcribing/cleaning frames are transient and same-place, so skip
        // them to keep one-or-two lines per dictation rather than a burst.
        switch state {
        case .transcribing, .cleaning, .warning:
            return
        case .idle, .recording, .meeting:
            break
        }
        let f: NSRect = panel.frame
        Log.info("Flow-Bar \(stateLabel(state)) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))) visible=\(panel.isVisible) custom=\(Config.hudHasCustomPosition)")
    }

    private func stateLabel(_ state: HUDState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .cleaning: return "cleaning"
        case .warning: return "warning"
        case .meeting: return "meeting"
        }
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

    // MARK: - Waveform

    /// Paints all bars from `levelHistory` in one pass. Animated updates run
    /// through a short `NSAnimationContext` group so consecutive samples blend
    /// into a smooth waveform instead of snapping bar-to-bar.
    private func paintBars(animated: Bool) {
        let vertical: Bool = isDockedVertical
        let midY: CGFloat = Self.pillHeight / 2
        let midX: CGFloat = (panel?.frame.width ?? Self.dockActiveWidth) / 2
        let applyHeights: () -> Void = {
            for (index, level) in self.levelHistory.enumerated() where index < self.barViews.count {
                let bar: NSView = self.barViews[index]
                var frame: NSRect = bar.frame
                if vertical {
                    frame.origin.x = midX - level / 2
                    frame.size.width = level
                } else {
                    frame.origin.y = midY - level / 2
                    frame.size.height = level
                }
                self.setFrame(frame, on: bar, animated: animated)
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { (context: NSAnimationContext) in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                applyHeights()
            }
        } else {
            applyHeights()
        }
    }

    private func resetBars() {
        levelHistory = Array(repeating: Self.minBarHeight, count: Self.barCount)
        paintBars(animated: false)
    }

    // MARK: - Shimmer (transcribing/cleaning "working" pulse)

    private static let shimmerAnimationKey = "flowbar.shimmer"

    private func startShimmer() {
        guard !reducedMotion else {
            shimmerView.layer?.removeAnimation(forKey: Self.shimmerAnimationKey)
            shimmerView.alphaValue = 0.6
            return
        }
        guard shimmerView.layer?.animation(forKey: Self.shimmerAnimationKey) == nil else { return }
        let pulse: CABasicAnimation = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3
        pulse.toValue = 0.9
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmerView.layer?.add(pulse, forKey: Self.shimmerAnimationKey)
    }

    private func stopShimmer() {
        // hide() can run before the panel (and thus shimmerView) is built.
        shimmerView?.layer?.removeAnimation(forKey: Self.shimmerAnimationKey)
    }

    deinit {
        stopTimer()
    }
}
