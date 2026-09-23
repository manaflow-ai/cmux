import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxCommandPalette
import Foundation
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
    @Test("Window hit testing reaches browser children across portal reopen and overlay dismissal")
    func windowHitTestingReachesBrowserContent() throws {
        let window = makeWindow(withBrowserHost: true)
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let anchor = try #require(find("overlay.browser", in: content))
        let browser = WindowBrowserPortal(window: window)
        defer { browser.tearDown() }

        for _ in 0..<3 {
            let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
            browser.bind(webView: webView, to: anchor, visibleInUI: true)
            content.layoutSubtreeIfNeeded()
            browser.synchronizeWebViewForAnchor(anchor)
            let slot = try #require(webView.cmuxBrowserViewportPresentationView.superview as? WindowBrowserSlotView)
            let point = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)

            let zones: [DropZone?] = [nil, .center, nil]
            for zone in zones {
                slot.setDropZoneOverlay(zone: zone)
                let hit = try #require(content.cmuxHitTest(windowPoint: point))
                #expect(hit === webView || hit.isDescendant(of: webView))
            }

            browser.detachWebView(withId: ObjectIdentifier(webView))
            let hitAfterClose = content.cmuxHitTest(windowPoint: point)
            #expect(hitAfterClose !== slot)
            #expect(hitAfterClose?.isDescendant(of: slot) != true)
        }

        for identifier in ["overlay.sidebar", "overlay.tabs", "overlay.terminal"] {
            let chrome = try #require(find(identifier, in: content))
            let point = chrome.convert(NSPoint(x: chrome.bounds.midX, y: chrome.bounds.midY), to: nil)
            #expect(content.cmuxHitTest(windowPoint: point) === chrome)
        }
    }

    @Test("Installing native portals preserves the SwiftUI chrome root and layout contract")
    func portalsPreserveContentOwnership() throws {
        let window = makeWindow(withBrowserHost: true)
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

    @Test("Browser content stays inside the content hierarchy without covering either chrome strip", arguments: [false, true])
    func browserAndTerminalRespectChrome(useGlass: Bool) throws {
        let window = makeWindow(withBrowserHost: true)
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let browserAnchor = try #require(find("overlay.browser", in: content))
        let terminalAnchor = try #require(find("overlay.terminal", in: content))
        if useGlass {
            WindowGlassEffect().apply(to: window)
        }
        let windowRoot = window.contentView
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
            if useGlass {
                #expect(root !== windowRoot)
            } else {
                #expect(root === windowRoot)
            }
            #expect(webView.window === window)
            let browserFrame = browserAnchor.convert(browserAnchor.bounds, to: nil)
            let browserPoint = NSPoint(x: browserFrame.midX, y: browserFrame.midY)
            #expect(browserFrame.width > 100 && browserFrame.height > 100)
            #expect(browser.webViewAtWindowPoint(browserPoint) === webView)
            #expect(terminal.viewAtWindowPoint(browserPoint) == nil)
            let terminalFrame = terminalAnchor.convert(terminalAnchor.bounds, to: nil)
            let terminalPoint = NSPoint(x: terminalFrame.midX, y: terminalFrame.midY)
            let terminalHit = try #require(terminal.viewAtWindowPoint(terminalPoint))
            #expect(terminalHit.isDescendant(of: terminalView))
            #expect(browser.webViewAtWindowPoint(terminalPoint) == nil)
            for identifier in ["overlay.sidebar", "overlay.tabs"] {
                let chrome = try #require(find(identifier, in: content))
                let chromeFrame = chrome.convert(chrome.bounds, to: nil)
                #expect(chromeFrame.width > 0)
                #expect(chromeFrame.height > 0)
            }
        }
    }

    @Test("Native browser hit testing converts flipped parent coordinates exactly once")
    func flippedContentPointerRouting() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        let content = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let host = WindowBrowserHostView(frame: NSRect(x: 30, y: 40, width: 400, height: 240))
        content.addSubview(host)
        let button = NSButton(frame: NSRect(x: 50, y: 160, width: 80, height: 30))
        host.addSubview(button)
        let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: host.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(host.performHitTest(at: point, currentEvent: event, dragPasteboard: pasteboard) === button)
        #expect(host.cmuxHitTest(windowPoint: event.locationInWindow) === button)
    }

    @Test("Pane swap selection keeps source distinct and commits the hovered target")
    func paneSwapSelectionCommitsDistinctHoveredTarget() {
        let sourcePaneID = UUID()
        let targetPaneID = UUID()
        var state = PaneSwapSelectionState(sourcePaneID: sourcePaneID)

        #expect(state.targetPaneID == nil)
        #expect(state.handle(.hover(sourcePaneID)) == .none)
        #expect(state.targetPaneID == nil)
        #expect(state.handle(.hover(targetPaneID)) == .none)
        #expect(state.targetPaneID == targetPaneID)
        #expect(
            state.handle(.primaryClick) == .commit(
                sourcePaneID: sourcePaneID,
                targetPaneID: targetPaneID
            )
        )
        #expect(state.targetPaneID == nil)
    }

    @Test(
        "Pane swap selection cancellation abandons the active target",
        arguments: [
            PaneSwapSelectionCancellationReason.escapeKey,
            .secondaryClick,
            .abandonedInteraction,
            .windowDeactivated,
            .layoutChanged,
        ]
    )
    func paneSwapSelectionCancellation(reason: PaneSwapSelectionCancellationReason) {
        let sourcePaneID = UUID()
        let targetPaneID = UUID()
        var state = PaneSwapSelectionState(sourcePaneID: sourcePaneID)

        _ = state.handle(.hover(targetPaneID))
        #expect(state.targetPaneID == targetPaneID)
        #expect(state.handle(.cancel(reason)) == .cancel(reason))
        #expect(state.targetPaneID == nil)
    }

    @Test("Swap With Session command is terminal-pane scoped and dismisses before selection")
    func swapWithSessionCommandPaletteContract() throws {
        let contribution = try #require(
            ContentView.commandPaletteViewCommandContributions().first {
                $0.commandId == "palette.swapWithSession"
            }
        )

        var terminalPane = CommandPaletteContextSnapshot()
        terminalPane.setBool(CommandPaletteContextKeys.panelIsTerminal, true)
        terminalPane.setBool(CommandPaletteContextKeys.panelHasPane, true)
        #expect(contribution.when(terminalPane))

        var terminalWithoutPane = CommandPaletteContextSnapshot()
        terminalWithoutPane.setBool(CommandPaletteContextKeys.panelIsTerminal, true)
        #expect(!contribution.when(terminalWithoutPane))

        var nonTerminalPane = CommandPaletteContextSnapshot()
        nonTerminalPane.setBool(CommandPaletteContextKeys.panelHasPane, true)
        #expect(!contribution.when(nonTerminalPane))

        #expect(
            ContentView.commandPaletteShouldDismissBeforeRun(
                forCommandId: "palette.swapWithSession"
            )
        )
    }

    private func makeWindow() -> NSWindow {
        makeWindow(withBrowserHost: false)
    }

    private func makeWindow(withBrowserHost: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let fixture = chromeFixture.overlay {
            if withBrowserHost {
                WindowContentOverlayBrowserHost()
            }
        }
        window.contentView = MainWindowHostingView(rootView: fixture)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private var chromeFixture: some View {
        HStack(spacing: 0) {
            Marker(identifier: "overlay.sidebar").frame(width: 240).frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                Marker(identifier: "overlay.tabs").frame(height: 28)
                HStack(spacing: 0) {
                    Marker(identifier: "overlay.terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
                    Marker(identifier: "overlay.browser").frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private final class FlippedContentView: NSView {
        override var isFlipped: Bool { true }
    }
}
