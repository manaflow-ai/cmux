import Foundation
import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Resuming hibernated terminals
extension AgentHibernationTests {
    @MainActor
    func testFocusingHibernatedTerminalAutomaticallyPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-auto-resume-on-visit",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        workspace.focusPanel(panelId)

        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testVisibleHibernatedTerminalAutomaticallyPreparesResumeWithoutFocus() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-visible-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        XCTAssertTrue(workspace.resumeVisibleAgentHibernationPanels(panelIds: [panelId]))

        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testHiddenMountedWorkspaceDoesNotAutoResumeHibernatedTerminal() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-hidden-mounted-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        workspace.setAgentHibernationAutoResumePresentationVisible(false)
        XCTAssertEqual(workspace.agentHibernationVisiblePanelIdsForCurrentLayout(), [])

        _ = workspace.debugReconcileTerminalPortalVisibilityForTesting()
        XCTAssertTrue(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        workspace.setAgentHibernationAutoResumePresentationVisible(true)

        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testAutosaveFingerprintTracksHibernationTransitions() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-autosave-hibernation",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        let liveFingerprint = manager.sessionAutosaveFingerprint()
        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        let hibernatedFingerprint = manager.sessionAutosaveFingerprint()

        XCTAssertNotEqual(liveFingerprint, hibernatedFingerprint)
        XCTAssertTrue(workspace.resumeAgentHibernation(panelId: panelId, focus: false))
        XCTAssertNotEqual(hibernatedFingerprint, manager.sessionAutosaveFingerprint())
    }

    @MainActor
    func testResumeClearsStaleLifecycleState() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-clear-lifecycle-on-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(workspace.resumeAgentHibernation(panelId: panelId, focus: false))
        XCTAssertEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .unknown)
    }

    @MainActor
    func testDirectFocusOnHibernatedTerminalPreparesResumeWithoutHiddenFocus() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-direct-focus-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        panel.focus()

        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testExplicitInputToHibernatedTerminalQueuesAndPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-explicit-input-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        let result = panel.sendInputResult("pwd\r")

        XCTAssertEqual(result, .queued)
        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testMovedHibernatedTerminalResumesThroughDestinationWorkspace() throws {
        let source = Workspace()
        let panelId = try XCTUnwrap(source.focusedPanelId)
        let panel = try XCTUnwrap(source.panels[panelId] as? TerminalPanel)
        let detached = try XCTUnwrap(source.detachSurface(panelId: panelId))

        let destination = Workspace()
        let destinationPaneId = try XCTUnwrap(destination.bonsplitController.focusedPaneId)
        XCTAssertEqual(
            destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false),
            panelId
        )

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-moved-explicit-input-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )
        destination.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        let result = panel.sendInputResult("pwd\r")

        XCTAssertEqual(result, .queued)
        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertNil(source.restoredAgentResumeStatesByPanelId[panelId])
        XCTAssertEqual(destination.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testExplicitNamedKeyToHibernatedTerminalQueuesAndPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-explicit-key-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        let result = panel.sendNamedKeyResult("enter")

        XCTAssertEqual(result, .queued)
        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testResumePreparationWithoutStartupInputStillLeavesHibernation() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("manual-agent"),
            sessionId: "manual-agent-session",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: nil
        )

        panel.enterAgentHibernation(
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        let preparation = panel.prepareAgentHibernationResume()

        XCTAssertEqual(preparation, .resumed(queuedStartupInput: false))
        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertFalse(panel.surface.debugInitialInputMetadata().hasInitialInput)
    }

}
