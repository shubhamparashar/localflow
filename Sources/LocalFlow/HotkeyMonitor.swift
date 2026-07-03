import AppKit

/// Watches for a bare-modifier hold (right Option or Fn) using NSEvent
/// flagsChanged monitors. Global monitors require the Accessibility grant,
/// which the app needs anyway for paste injection.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Command mode: same modifier held together with Shift.
    var onCommandPress: (() -> Void)?
    var onCommandRelease: (() -> Void)?

    private enum Session { case none, normal, command }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var session: Session = .none

    private static let rightOptionKeyCode: UInt16 = 61
    private static let fnKeyCode: UInt16 = 63

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
        Log.info("HotkeyMonitor started (hotkey=\(Config.hotkey.rawValue))")
    }

    func stop() {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let pressed: Bool
        switch Config.hotkey {
        case .rightOption:
            guard event.keyCode == Self.rightOptionKeyCode else { return }
            pressed = event.modifierFlags.contains(.option)
        case .fn:
            guard event.keyCode == Self.fnKeyCode else { return }
            pressed = event.modifierFlags.contains(.function)
        }
        if pressed && session == .none {
            if event.modifierFlags.contains(.shift) {
                session = .command
                onCommandPress?()
            } else {
                session = .normal
                onPress?()
            }
        } else if !pressed && session != .none {
            let ended = session
            session = .none
            if ended == .command {
                onCommandRelease?()
            } else {
                onRelease?()
            }
        }
    }
}
