import XCTest
import AppKit
import WebKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class InactivePaneFirstClickFocusTests: XCTestCase {
    private let settingsKey = "paneFirstClickFocus.enabled"
    private var surfacesToRelease: [TerminalSurface] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: settingsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: settingsKey)
        for surface in surfacesToRelease.reversed() {
            TerminalWindowPortalRegistry.detach(hostedView: surface.hostedView)
            surface.releaseSurfaceForTesting()
        }
        surfacesToRelease.removeAll()
        super.tearDown()
    }

    func testTerminalViewAcceptsFirstMouseWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let view = GhosttyNSView(frame: .zero)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testTerminalViewRejectsFirstMouseWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testBrowserViewAcceptsFirstMouseWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let view = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testBrowserViewRejectsFirstMouseWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let view = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testMarkdownWebViewAcceptsFirstMouseWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let view = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testMarkdownWebViewRejectsFirstMouseWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let view = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testPaneBodyPointerPreflightRunsForActiveWindowAndHonorsFirstClickSetting() {
        XCTAssertFalse(shouldRunPaneBodyPointerFocusPreflight(
            windowIsKey: false,
            appIsActive: false,
            paneFirstClickFocusEnabled: false
        ))
        XCTAssertFalse(shouldRunPaneBodyPointerFocusPreflight(
            windowIsKey: false,
            appIsActive: true,
            paneFirstClickFocusEnabled: false
        ))
        XCTAssertTrue(shouldRunPaneBodyPointerFocusPreflight(
            windowIsKey: true,
            appIsActive: true,
            paneFirstClickFocusEnabled: false
        ))
        XCTAssertTrue(shouldRunPaneBodyPointerFocusPreflight(
            windowIsKey: false,
            appIsActive: false,
            paneFirstClickFocusEnabled: true
        ))
    }

    func testMainPanelKeyboardFocusIntentTracksActivation() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: nil
        )
        let workspaceId = UUID()
        let panelId = UUID()

        // No intent recorded yet → a pane-body click must not be treated as satisfied.
        XCTAssertFalse(
            controller.hasMainPanelKeyboardFocusIntent(workspaceId: workspaceId, panelId: panelId)
        )

        // A stale right-sidebar intent must never count as a satisfied main-panel focus,
        // even while Bonsplit focus and the AppKit first responder still point at the pane.
        // Otherwise the pane-body preflight would skip restoring keyboard routing (#5269).
        controller.noteRightSidebarInteraction(mode: .dock)
        XCTAssertFalse(
            controller.hasMainPanelKeyboardFocusIntent(workspaceId: workspaceId, panelId: panelId)
        )

        // Main-panel intent for this pane → satisfied.
        controller.noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
        XCTAssertTrue(
            controller.hasMainPanelKeyboardFocusIntent(workspaceId: workspaceId, panelId: panelId)
        )

        // Main-panel intent for a different pane → not satisfied.
        XCTAssertFalse(
            controller.hasMainPanelKeyboardFocusIntent(workspaceId: workspaceId, panelId: UUID())
        )

        // Returning focus to the right sidebar clears the satisfied state again.
        controller.noteRightSidebarInteraction(mode: .files)
        XCTAssertFalse(
            controller.hasMainPanelKeyboardFocusIntent(workspaceId: workspaceId, panelId: panelId)
        )
    }

    func testTerminalPointerFocusUsesPortalRegistryWhenHitTestMisses() throws {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try XCTUnwrap(window.contentView)
        let windowId = UUID()
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: TabManager(),
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        // Seed non-terminal focus ownership so terminal first-responder acquisition depends on the
        // pointer-hit allowance exercised by this regression test.
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)

        let anchor = NSView(frame: NSRect(x: 80, y: 60, width: 480, height: 260))
        contentView.addSubview(anchor)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        surfacesToRelease.append(surface)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        TerminalWindowPortalRegistry.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)

        defer {
            AppDelegate.clearWindowFirstResponderGuardTesting()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        let pointInAnchor = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let pointInWindow = anchor.convert(pointInAnchor, to: nil)
        let terminalView = try XCTUnwrap(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(pointInWindow, in: window)
        )
        XCTAssertTrue(terminalView === surface.hostedView.terminalViewForDrop(at: pointInAnchor))

        let pointerDownEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ))

        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: pointerDownEvent, hitView: nil)
        _ = window.makeFirstResponder(nil)

        XCTAssertTrue(
            window.makeFirstResponder(terminalView),
            "Pointer-initiated terminal focus should use the window portal when AppKit hit testing misses"
        )
    }
}
