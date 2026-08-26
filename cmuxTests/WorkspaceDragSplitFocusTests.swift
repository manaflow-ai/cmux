import AppKit
import Bonsplit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceDragSplitFocusSwiftTests {
#if DEBUG
    @Test
    func movedTerminalBecomesSoleFocusedCursor() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer { AppDelegate.shared = originalAppDelegate }

        let fixture = try makeFixture()
        defer {
            fixture.window.orderOut(nil)
            fixture.previousKeyWindow?.makeKey()
        }

        fixture.workspace.focusPanel(fixture.originalPanel.id)
        #expect(fixture.originalPanel.surface.debugDesiredFocusState())
        #expect(!fixture.movedPanel.surface.debugDesiredFocusState())
        #expect(fixture.originalPanel.hostedView.isSurfaceViewFirstResponder())

        let newPane = try #require(
            fixture.workspace.bonsplitController.splitPane(
                fixture.sourcePane,
                orientation: .vertical,
                movingTab: fixture.movedTab,
                insertFirst: false
            )
        )

        #expect(fixture.workspace.bonsplitController.focusedPaneId == newPane)
        #expect(fixture.workspace.focusedPanelId == fixture.movedPanel.id)
        #expect(!fixture.originalPanel.surface.debugDesiredFocusState())
        #expect(fixture.movedPanel.surface.debugDesiredFocusState())
        #expect(fixture.movedPanel.hostedView.isSurfaceViewFirstResponder())

        fixture.workspace.debugAttemptEventDrivenLayoutFollowUpForTesting()

        #expect(!fixture.originalPanel.hostedView.debugIsSuppressingReparentFocusForTesting())
        #expect(fixture.workspace.bonsplitController.focusedPaneId == newPane)
        #expect(fixture.workspace.focusedPanelId == fixture.movedPanel.id)
        #expect(!fixture.originalPanel.surface.debugDesiredFocusState())
        #expect(fixture.movedPanel.surface.debugDesiredFocusState())
        #expect(fixture.movedPanel.hostedView.isSurfaceViewFirstResponder())
    }

    @Test
    func activatedSharedSplitReassertsFocusWithoutPreviousTerminalResponder() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager
        AppDelegate.shared = appDelegate
        defer {
            tabManager.tabs.forEach { $0.teardownAllPanels() }
            appDelegate.tabManager = nil
            AppDelegate.shared = originalAppDelegate
        }

        let workspace = try #require(tabManager.selectedWorkspace)
        let fixture = try makeFixture(workspace: workspace)
        defer {
            fixture.window.orderOut(nil)
            fixture.previousKeyWindow?.makeKey()
        }

        fixture.workspace.focusPanel(fixture.originalPanel.id)
        #expect(fixture.window.makeFirstResponder(fixture.focusSink))
        #expect(!fixture.originalPanel.hostedView.isSurfaceViewFirstResponder())
        #expect(!fixture.movedPanel.hostedView.isSurfaceViewFirstResponder())

        let newPane = try #require(
            fixture.workspace.splitPaneMovingTab(
                fixture.sourcePane,
                orientation: .vertical,
                movingTab: fixture.movedTab,
                insertFirst: false,
                focusIntent: .activateMovedTab
            )
        )

        #expect(fixture.workspace.bonsplitController.focusedPaneId == newPane)
        #expect(fixture.workspace.focusedPanelId == fixture.movedPanel.id)
        #expect(fixture.movedPanel.hostedView.isSurfaceViewFirstResponder())
        #expect(!fixture.workspace.debugHasPendingReparentFocusSuppressionsForTesting())

        // Model the responder loss that SwiftUI reparenting can cause after the
        // synchronous split delegate returns, then run its event-driven follow-up.
        #expect(fixture.window.makeFirstResponder(fixture.focusSink))
        #expect(!fixture.movedPanel.hostedView.isSurfaceViewFirstResponder())

        fixture.workspace.debugAttemptEventDrivenLayoutFollowUpForTesting()

        #expect(fixture.workspace.bonsplitController.focusedPaneId == newPane)
        #expect(fixture.workspace.focusedPanelId == fixture.movedPanel.id)
        #expect(!fixture.originalPanel.surface.debugDesiredFocusState())
        #expect(fixture.movedPanel.surface.debugDesiredFocusState())
        #expect(fixture.movedPanel.hostedView.isSurfaceViewFirstResponder())
    }

    @Test
    func nonFocusSplitPreservesCursorAndHibernation() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer { AppDelegate.shared = originalAppDelegate }

        let fixture = try makeFixture()
        defer {
            fixture.window.orderOut(nil)
            fixture.previousKeyWindow?.makeKey()
        }

        fixture.workspace.focusPanel(fixture.originalPanel.id)
        #expect(fixture.originalPanel.hostedView.isSurfaceViewFirstResponder())
        let hibernatedAgent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "issue-9504-non-focus-split",
            workingDirectory: "/tmp/issue-9504",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: "/tmp/issue-9504",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        #expect(
            fixture.workspace.enterAgentHibernation(
                panelId: fixture.movedPanel.id,
                agent: hibernatedAgent,
                lastActivityAt: Date(timeIntervalSince1970: 0)
            )
        )

        let newPane = try #require(
            fixture.workspace.splitPaneMovingTab(
                fixture.sourcePane,
                orientation: .vertical,
                movingTab: fixture.movedTab,
                insertFirst: false,
                focusIntent: .preserveCurrent
            )
        )

        #expect(
            fixture.workspace.bonsplitController.tabs(inPane: newPane)
                .contains { $0.id == fixture.movedTab }
        )
        #expect(fixture.workspace.bonsplitController.focusedPaneId == fixture.sourcePane)
        #expect(fixture.workspace.focusedPanelId == fixture.originalPanel.id)
        #expect(fixture.originalPanel.surface.debugDesiredFocusState())
        #expect(!fixture.movedPanel.surface.debugDesiredFocusState())
        #expect(fixture.movedPanel.isAgentHibernated)
        #expect(fixture.originalPanel.hostedView.isSurfaceViewFirstResponder())
    }
#endif

    private struct Fixture {
        let workspace: Workspace
        let originalPanel: TerminalPanel
        let movedPanel: TerminalPanel
        let sourcePane: PaneID
        let movedTab: TabID
        let window: NSWindow
        let previousKeyWindow: NSWindow?
        let focusSink: FocusSinkView
    }

    private func makeFixture(workspace: Workspace? = nil) throws -> Fixture {
        let workspace = workspace ?? Workspace()
        let originalPanelId = try #require(workspace.focusedPanelId)
        let originalPanel = try #require(workspace.terminalPanel(for: originalPanelId))
        let sourcePane = try #require(workspace.paneId(forPanelId: originalPanelId))
        let movedPanel = try #require(
            workspace.newTerminalSurface(inPane: sourcePane, focus: false)
        )
        let movedTab = try #require(workspace.surfaceIdFromPanelId(movedPanel.id))
        let previousKeyWindow = NSApp.keyWindow
        let window = makeWindow()
        var didBuildFixture = false
        defer {
            if !didBuildFixture {
                window.orderOut(nil)
                previousKeyWindow?.makeKey()
            }
        }
        let contentView = try #require(window.contentView, "Expected content view")
        let focusSink = FocusSinkView(frame: .zero)

        originalPanel.hostedView.frame = contentView.bounds
        movedPanel.hostedView.frame = contentView.bounds
        contentView.addSubview(originalPanel.hostedView)
        contentView.addSubview(movedPanel.hostedView)
        contentView.addSubview(focusSink)
        originalPanel.hostedView.setVisibleInUI(true)
        movedPanel.hostedView.setVisibleInUI(true)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        originalPanel.hostedView.layoutSubtreeIfNeeded()
        movedPanel.hostedView.layoutSubtreeIfNeeded()

        didBuildFixture = true
        return Fixture(
            workspace: workspace,
            originalPanel: originalPanel,
            movedPanel: movedPanel,
            sourcePane: sourcePane,
            movedTab: movedTab,
            window: window,
            previousKeyWindow: previousKeyWindow,
            focusSink: focusSink
        )
    }

    private final class FocusSinkView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}
