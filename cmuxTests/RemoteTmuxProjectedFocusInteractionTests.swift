import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class RemoteTmuxPanePortalTestHarness {
    private final class KeyStatusTestWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    let window: NSWindow
    private let originalWindow: NSWindow?
    private let appDelegate: AppDelegate?
    private let contentView: NSView
    private let portal: WindowTerminalPortal
    private var hostedViews: [ObjectIdentifier: GhosttySurfaceScrollView] = [:]

    init(
        panels: [TerminalPanel] = [],
        appDelegate: AppDelegate? = nil,
        windowID: UUID? = nil
    ) throws {
        let identifier = windowID.map {
            NSUserInterfaceItemIdentifier("cmux.main.\($0.uuidString)")
        }
        originalWindow = identifier.flatMap { identifier in
            NSApp.windows.first { $0.identifier == identifier }
        }
        self.appDelegate = appDelegate

        let window = KeyStatusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.identifier = identifier
        let contentView = NSView(frame: window.contentLayoutRect)
        window.contentView = contentView
        self.window = window
        self.contentView = contentView
        self.portal = WindowTerminalPortal(window: window)

        window.makeKeyAndOrderFront(nil)
        if let appDelegate {
            _ = try #require(appDelegate.contextForMainTerminalWindow(window))
        }

        let panelWidth = contentView.bounds.width / CGFloat(max(panels.count, 1))
        for (index, panel) in panels.enumerated() {
            mount(
                panel,
                frame: NSRect(
                    x: CGFloat(index) * panelWidth,
                    y: 0,
                    width: panelWidth,
                    height: contentView.bounds.height
                ),
                detachFromRegisteredPortal: true
            )
        }
    }

    func mount(
        _ panel: TerminalPanel,
        frame: NSRect,
        detachFromRegisteredPortal: Bool = false
    ) {
        if detachFromRegisteredPortal {
            TerminalWindowPortalRegistry.detach(hostedView: panel.hostedView)
        }
        let anchor = NSView(frame: frame)
        contentView.addSubview(anchor)
        portal.bind(hostedView: panel.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        hostedViews[ObjectIdentifier(panel.hostedView)] = panel.hostedView
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        _ = window.makeFirstResponder(nil)
        for (hostedID, hostedView) in hostedViews {
            portal.detachHostedView(withId: hostedID)
            hostedView.setVisibleInUI(false)
        }
        window.identifier = nil
        if let originalWindow, let appDelegate {
            _ = appDelegate.contextForMainTerminalWindow(originalWindow)
        }
        window.orderOut(nil)
    }
}

/// Behavior coverage for AppKit interactions with a projected tmux pane.
@MainActor
@Suite(.serialized)
struct RemoteTmuxProjectedFocusInteractionTests {
    typealias Harness = RemoteTmuxMirrorPaneInputMappingTests.Harness

    @Test
    func splitPaneForwardsPointerActivationThroughProjectedFocus() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let mirror = try splitInitiallySinglePaneWindow(in: harness)

        let inactivePane = try #require(mirror.panel(forPane: 4))
        let activePane = try #require(mirror.panel(forPane: 5))
        #expect(harness.workspace.focusedPanelId != activePane.id)
        #expect(harness.workspace.isFocusedTerminalInputSurface(activePane.id))

        activePane.hostedView.surfaceView.desiredFocus = true
        inactivePane.hostedView.surfaceView.desiredFocus = true

        #expect(activePane.hostedView.surfaceView.terminalPointerShouldForwardActivation())
        #expect(!inactivePane.hostedView.surfaceView.terminalPointerShouldForwardActivation())
    }

    @Test
    func splitPaneSearchFieldReceivesProjectedFocusAuthority() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let mirror = try splitInitiallySinglePaneWindow(in: harness)
        let activePane = try #require(mirror.panel(forPane: 5))
        let hostedView = activePane.hostedView
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)

        #expect(
            hostedView.debugCanApplyMountedSearchFieldFocusRequest(),
            "The search field must accept focus authority for the projected active pane"
        )
    }

    @Test
    func commandEquivalentRepairsStalePaneFirstResponder() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let mirror = try splitInitiallySinglePaneWindow(in: harness)
        let stalePane = try #require(mirror.panel(forPane: 4))
        let activePane = try #require(mirror.panel(forPane: 5))
        let appDelegate = try #require(AppDelegate.shared)
        let mountedPortal = try RemoteTmuxPanePortalTestHarness(
            panels: [stalePane, activePane],
            appDelegate: appDelegate,
            windowID: harness.windowId
        )
        defer { mountedPortal.tearDown() }
        let window = mountedPortal.window
        stalePane.hostedView.setVisibleInUI(true)
        stalePane.hostedView.setActive(true)
        stalePane.hostedView.moveFocus()
        #expect(stalePane.hostedView.isSurfaceViewFirstResponder())
        let staleResponder = try #require(window.firstResponder)
        stalePane.hostedView.setActive(false)
        activePane.hostedView.setVisibleInUI(true)
        activePane.hostedView.setActive(true)
        let keyDown = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))

        appDelegate.repairFocusedTerminalKeyboardRoutingIfNeeded(
            window: window,
            event: keyDown,
            firstResponderOverride: staleResponder
        )

        #expect(harness.workspace.focusedTerminalInputTarget()?.surfaceID == activePane.id)
        #expect(
            activePane.hostedView.isSurfaceViewFirstResponder(),
            "Key repair must make the tmux-active inner pane the actual AppKit responder"
        )
    }

    @Test
    func workspaceHandoffHidesMirrorOwnedTerminalPortals() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let mirror = try splitInitiallySinglePaneWindow(in: harness)
        let paneFour = try #require(mirror.panel(forPane: 4))
        let paneFive = try #require(mirror.panel(forPane: 5))

        paneFour.hostedView.setVisibleInUI(true)
        paneFive.hostedView.setVisibleInUI(true)
        #expect(paneFour.hostedView.isVisibleInUI)
        #expect(paneFive.hostedView.isVisibleInUI)

        harness.workspace.setPortalRenderingEnabled(false, reason: "workspace-handoff-test")

        #expect(!paneFour.hostedView.isVisibleInUI)
        #expect(!paneFive.hostedView.isVisibleInUI)
    }

    @Test
    func projectedPaneWordPathSnapshotRejectsRemoteFilesystemResolution() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let mirror = try splitInitiallySinglePaneWindow(in: harness)
        let activePane = try #require(mirror.panel(forPane: 5))

        #expect(harness.workspace.panels[activePane.id] == nil)
        #expect(
            activePane.hostedView.surfaceView.debugWordPathSnapshotTerminalPanelID() == nil,
            "Projected SSH-tmux transcripts must not probe the local filesystem"
        )
    }

    private func splitInitiallySinglePaneWindow(
        in harness: Harness
    ) throws -> RemoteTmuxWindowMirror {
        let manager = try #require(AppDelegate.shared?.tabManagerFor(windowId: harness.windowId))
        manager.selectWorkspace(harness.workspace)
        harness.publishListWindows([
            "@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] zsh",
        ])
        try harness.drainThroughPaneRects([
            2: ["%4 0 0 80 24 1 off :0 \"host\""],
        ])
        let initialMirror = try harness.mirror()

        harness.connection.handleMessageForTesting(.layoutChange(
            windowId: 2,
            layout: "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}",
            visibleLayout: nil,
            zoomed: false
        ))
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 0 off :0 \"host\"",
            "%5 61 0 59 40 1 off :1 \"host\"",
        ]])
        harness.connection.handleMessageForTesting(
            .windowPaneChanged(windowId: 2, paneId: 5)
        )

        let mirror = try harness.mirror()
        #expect(mirror === initialMirror)
        #expect(mirror.activePaneId == 5)
        #expect(waitUntil {
            mirror.paneIDsInOrder.allSatisfy {
                mirror.panel(forPane: $0)?.hostedView.window != nil
            }
        })
        return mirror
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.01))
        } while Date.now < deadline
        return condition()
    }
}
