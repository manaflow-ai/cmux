import Foundation
import Testing
import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceProgramStatusTests {
    @Test func projectsMostUrgentPanelRecord() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "cargo", message: "Building"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .permission, id: "deploy", message: "Approve?"),
            panelId: panelId
        )
        let entry = try #require(workspace.statusEntries[Workspace.programStatusKey])
        #expect(entry.icon == "bell.fill")
        #expect(entry.value.contains("Approve?"))
        #expect(workspace.programStatusStoresByPanelId[panelId]?.mostUrgentRecord()?.state == .blocked)
    }

    @Test func programStatusIsNotAgentLifecycleState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .auth, app: "brew"),
            panelId: panelId
        )
        #expect(workspace.agentLifecycleStatesByPanelId[panelId] == nil)
        #expect(workspace.agentRuntimeState(forPanelId: panelId) == nil)
        #expect(workspace.statusEntries[Workspace.programStatusKey]?.value == "brew · Needs sign-in")
    }

    @Test func workingShowsPercentAndPromptDropsTransientRecords() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "lint", app: "cargo", message: "Lint clean"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, progress: 40, app: "cargo", message: "Building"),
            panelId: panelId
        )
        #expect(workspace.statusEntries[Workspace.programStatusKey]?.value == "cargo · Building · 40%")

        workspace.applyProgramStatus(ProgramStatusReport(event: .promptStart, state: .idle), panelId: panelId)
        let entry = try #require(workspace.statusEntries[Workspace.programStatusKey])
        #expect(entry.icon == "checkmark.circle.fill")
        #expect(entry.value == "cargo · Lint clean")

        workspace.dismissCompletedProgramStatus(panelId: panelId)
        #expect(workspace.statusEntries[Workspace.programStatusKey] == nil)
    }

    @Test func closingPaneRemovesItsProgramStatusRow() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let blockedPanel = try #require(
            workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false)
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .permission, app: "terraform"),
            panelId: blockedPanel.id
        )
        #expect(workspace.statusEntries[Workspace.programStatusKey] != nil)

        workspace.discardClosedPanelLifecycleState(
            panelId: blockedPanel.id,
            paneId: nil,
            panel: blockedPanel,
            origin: "program_status_test",
            closePanel: false,
            publishSurfaceClosedEvent: false,
            clearSurfaceNotifications: false,
            requestTransferredRemoteCleanup: false
        )

        #expect(workspace.statusEntries[Workspace.programStatusKey] == nil)
        #expect(workspace.programStatusStoresByPanelId[blockedPanel.id] == nil)
    }

    @Test func promptStartOrClearWithoutRecordsDoesNotCreateState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(ProgramStatusReport(event: .promptStart, state: .idle), panelId: panelId)
        #expect(workspace.programStatusStoresByPanelId[panelId] == nil)
        workspace.applyProgramStatus(ProgramStatusReport(state: .clear), panelId: panelId)
        #expect(workspace.programStatusStoresByPanelId[panelId] == nil)
        #expect(workspace.statusEntries[Workspace.programStatusKey] == nil)
    }

    @Test func programStatusChangesReachTheMacEventStream() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "lint", app: "cargo"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, id: "build", app: "cargo"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(event: .promptStart, state: .idle),
            panelId: panelId
        )
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 3)
        let promptPayload = try #require(events.last?["payload"] as? [String: Any])
        #expect(promptPayload["event"] as? String == "prompt_start")
        let records = try #require(promptPayload["records"] as? [[String: Any]])
        #expect(records.map { $0["id"] as? String } == ["lint"])
    }

    @Test func programStatusClearReachesTheMacEventStream() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, id: "build", app: "cargo"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .clear, id: "build"),
            panelId: panelId
        )
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 2)
        let clearPayload = try #require(events.last?["payload"] as? [String: Any])
        #expect(clearPayload["event"] as? String == "clear")
        #expect(clearPayload["id"] as? String == "build")
        #expect(clearPayload["record"] is NSNull)
        let records = try #require(clearPayload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
    }

    @Test func transientCleanupPublishesOnceBeforePromptStartNoOp() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .permission, id: "deploy"),
            panelId: panelId
        )
        workspace.dropTransientProgramStatus(panelId: panelId)
        // Shell integration can deliver this after prompt-idle cleanup. It is
        // intentionally a no-op because the snapshot was already published.
        workspace.applyProgramStatus(
            ProgramStatusReport(event: .promptStart, state: .idle),
            panelId: panelId
        )
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 2)
        let cleanupPayload = try #require(events.last?["payload"] as? [String: Any])
        #expect(cleanupPayload["event"] as? String == "transient_drop")
        let records = try #require(cleanupPayload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
    }

    @Test func dismissingCompletedStatusPublishesUpdatedSnapshot() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "build"),
            panelId: panelId
        )
        workspace.dismissCompletedProgramStatus(panelId: panelId)
        workspace.dismissCompletedProgramStatus(panelId: panelId)
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 2)
        let dismissedPayload = try #require(events.last?["payload"] as? [String: Any])
        #expect(dismissedPayload["event"] as? String == "dismissed")
        let records = try #require(dismissedPayload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
    }

    @Test func movedPaneKeepsItsProgramStatusRecords() throws {
        let source = Workspace()
        let destination = Workspace()
        let firstPanelId = try #require(source.focusedPanelId)
        let movedPanel = try #require(
            source.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false)
        )
        source.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .question, app: "deploy", message: "Region?"),
            panelId: movedPanel.id
        )

        let detached = try #require(source.detachSurface(panelId: movedPanel.id))
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        _ = try #require(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false))

        #expect(source.statusEntries[Workspace.programStatusKey] == nil)
        #expect(destination.programStatusStoresByPanelId[movedPanel.id]?.mostUrgentRecord()?.state == .blocked)
        #expect(destination.statusEntries[Workspace.programStatusKey]?.value == "deploy · Region?")
    }

    @Test func closingTerminalsPublishesRemovedSnapshotOnlyForReportingPanes() throws {
        let workspace = Workspace()
        let reportingPanelId = try #require(workspace.focusedPanelId)
        let quietPanel = try #require(
            workspace.newTerminalSplit(from: reportingPanelId, orientation: .horizontal, focus: false)
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "lint", app: "cargo"),
            panelId: reportingPanelId
        )
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.teardownAllPanels()
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 1)
        let removed = try #require(events.first)
        #expect(removed["workspace_id"] as? String == workspace.id.uuidString)
        #expect(removed["surface_id"] as? String == reportingPanelId.uuidString)
        #expect(removed["surface_id"] as? String != quietPanel.id.uuidString)
        let payload = try #require(removed["payload"] as? [String: Any])
        #expect(payload["event"] as? String == "removed")
        #expect(payload["record"] is NSNull)
        #expect(payload["records_total"] as? Int == 0)
        let records = try #require(payload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
    }

    @Test func movedPanePublishesRemovalAndAdoptionUnderEachWorkspace() throws {
        let source = Workspace()
        let destination = Workspace()
        let firstPanelId = try #require(source.focusedPanelId)
        let movedPanel = try #require(
            source.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false)
        )
        source.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .question, id: "deploy", app: "deploy"),
            panelId: movedPanel.id
        )
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let detached = try #require(source.detachSurface(panelId: movedPanel.id))
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        _ = try #require(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false))
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 2)
        let removed = try #require(events.first)
        #expect(removed["workspace_id"] as? String == source.id.uuidString)
        #expect(removed["surface_id"] as? String == movedPanel.id.uuidString)
        let removedPayload = try #require(removed["payload"] as? [String: Any])
        #expect(removedPayload["event"] as? String == "removed")
        #expect((removedPayload["records"] as? [[String: Any]])?.isEmpty == true)

        let adopted = try #require(events.last)
        #expect(adopted["workspace_id"] as? String == destination.id.uuidString)
        #expect(adopted["surface_id"] as? String == movedPanel.id.uuidString)
        let adoptedPayload = try #require(adopted["payload"] as? [String: Any])
        #expect(adoptedPayload["event"] as? String == "adopted")
        #expect(adoptedPayload["record"] is NSNull)
        let records = try #require(adoptedPayload["records"] as? [[String: Any]])
        #expect(records.map { $0["id"] as? String } == ["deploy"])
        #expect(records.first?["state"] as? String == "blocked")
        #expect(records.first?["kind"] as? String == "question")
    }

    @Test func sidebarResetPublishesClearForReportingPanes() throws {
        let workspace = Workspace()
        let reportingPanelId = try #require(workspace.focusedPanelId)
        _ = try #require(
            workspace.newTerminalSplit(from: reportingPanelId, orientation: .horizontal, focus: false)
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, id: "build", app: "cargo"),
            panelId: reportingPanelId
        )
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        workspace.resetSidebarContext(reason: "test")
        CmuxEventBus.shared.flushEventLogForTesting()

        let events = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "program_status.changed"
        }
        #expect(events.count == 1)
        let cleared = try #require(events.first)
        #expect(cleared["workspace_id"] as? String == workspace.id.uuidString)
        #expect(cleared["surface_id"] as? String == reportingPanelId.uuidString)
        let payload = try #require(cleared["payload"] as? [String: Any])
        #expect(payload["event"] as? String == "clear")
        #expect(payload["id"] is NSNull)
        let records = try #require(payload["records"] as? [[String: Any]])
        #expect(records.isEmpty)
        #expect(workspace.programStatusStoresByPanelId.isEmpty)
    }

    @Test func sanitizesInvisibleFormattingAndCapsDisplay() {
        let workspace = Workspace()
        let value = workspace.sanitizedProgramStatusText("hello\u{202E}world")
        #expect(value == "helloworld")
        #expect(workspace.sanitizedProgramStatusText(String(repeating: "x", count: 600))?.count == 512)
    }
}
