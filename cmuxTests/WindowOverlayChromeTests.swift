import AppKit
import CmuxAppKitSupportUI
import SwiftUI
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WindowOverlayChromeTests {
    @Test("Installing native portals preserves the SwiftUI chrome root and layout contract")
    func portalsPreserveContentOwnership() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let parent = content.superview
        let autoresizing = content.autoresizingMask
        let translates = content.translatesAutoresizingMaskIntoConstraints
        let sidebar = try #require(find("overlay.sidebar", in: content))
        let tabs = try #require(find("overlay.tabs", in: content))
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
        let tabsFrame = tabs.convert(tabs.bounds, to: nil)
        let terminal = WindowTerminalPortal(window: window)
        let browser = WindowBrowserPortal(window: window)
        defer { browser.tearDown(); terminal.tearDown() }

        for _ in 0..<3 {
            _ = terminal.viewAtWindowPoint(.zero)
            _ = browser.webViewAtWindowPoint(.zero)
            content.layoutSubtreeIfNeeded()
        }

        #expect(window.contentView === content)
        #expect(content.superview === parent)
        #expect(content.translatesAutoresizingMaskIntoConstraints == translates)
        #expect(content.autoresizingMask == autoresizing)
        #expect(sidebar.convert(sidebar.bounds, to: nil) == sidebarFrame)
        #expect(tabs.convert(tabs.bounds, to: nil) == tabsFrame)
        #expect(sidebarFrame.width == 240)
        #expect(tabsFrame.height == 28)
    }

    @Test("Browser content stays inside the content hierarchy without covering either chrome strip")
    func browserAndTerminalRespectChrome() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let browserAnchor = try #require(find("overlay.browser", in: content))
        let terminalAnchor = try #require(find("overlay.terminal", in: content))
        let browser = WindowBrowserPortal(window: window)
        let terminal = WindowTerminalPortal(window: window)
        defer { browser.tearDown(); terminal.tearDown() }
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let terminalView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: .zero))
        browser.bind(webView: webView, to: browserAnchor, visibleInUI: true)
        terminal.bind(hostedView: terminalView, to: terminalAnchor, visibleInUI: true)

        for size in [NSSize(width: 1000, height: 700), NSSize(width: 1400, height: 900)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            browser.synchronizeWebViewForAnchor(browserAnchor)
            terminal.synchronizeHostedViewForAnchor(terminalAnchor)
            let root = try #require(window.contentView)
            #expect(webView.isDescendant(of: root))
            for identifier in ["overlay.sidebar", "overlay.tabs"] {
                let chrome = try #require(find(identifier, in: content))
                let chromeFrame = chrome.convert(chrome.bounds, to: nil)
                let webFrame = webView.convert(webView.bounds, to: nil)
                let terminalFrame = terminalView.convert(terminalView.bounds, to: nil)
                #expect(chromeFrame.intersection(webFrame).height <= 0)
                #expect(chromeFrame.intersection(terminalFrame).height <= 0)
                let point = NSPoint(x: chromeFrame.midX, y: chromeFrame.midY)
                #expect(browser.webViewAtWindowPoint(point) == nil)
                #expect(terminal.viewAtWindowPoint(point) == nil)
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = MainWindowHostingView(rootView: chromeFixture)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private var chromeFixture: some View {
        HStack(spacing: 0) {
            Marker(identifier: "overlay.sidebar").frame(width: 240)
            VStack(spacing: 0) {
                Marker(identifier: "overlay.tabs").frame(height: 28)
                HStack(spacing: 0) {
                    Marker(identifier: "overlay.terminal")
                    Marker(identifier: "overlay.browser")
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let found = find(identifier, in: child) { return found }
        }
        return nil
    }

    private struct Marker: NSViewRepresentable {
        let identifier: String

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier(identifier)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
