import AppKit
import WebKit

/// A reusable native window that renders an HTML report with a WKWebView, so
/// reports (History, Voice Profile) open in-app rather than the default
/// browser. One instance per report; reused (and re-loaded) on each show.
final class HTMLReportWindow: NSObject {

    private let windowTitle: String
    private let defaultSize: NSSize
    private var window: NSWindow?
    private var webView: WKWebView?

    init(title: String, size: NSSize) {
        self.windowTitle = title
        self.defaultSize = size
    }

    func show(html: String) {
        if window == nil {
            build()
        }
        webView?.loadHTMLString(html, baseURL: nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let frame = NSRect(origin: .zero, size: defaultSize)
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = windowTitle
        win.isReleasedWhenClosed = false
        win.center()
        win.minSize = NSSize(width: 420, height: 320)

        let wv = WKWebView(frame: frame)
        wv.autoresizingMask = [.width, .height]
        win.contentView = wv

        window = win
        webView = wv
    }
}
