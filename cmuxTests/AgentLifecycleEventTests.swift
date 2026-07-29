import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentLifecycleEventTests {
    @Test
    func lifecycleMutationPublishesSemanticStateWithSessionIdentity() throws {
        let fixture = try Fixture()

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-one"
        )

        let event = try #require(fixture.agentEvents().only)
        let payload = try #require(event["payload"] as? [String: Any])
        #expect(event["name"] as? String == "agent.state.changed")
        #expect(event["category"] as? String == "agent")
        #expect(event["source"] as? String == "agent.lifecycle")
        #expect(event["workspace_id"] as? String == fixture.workspace.id.uuidString)
        #expect(event["surface_id"] as? String == fixture.surfaceID.uuidString)
        #expect(payload["agent"] as? String == "codex")
        #expect(payload["state"] as? String == "running")
        #expect(payload["session_id"] as? String == "session-one")
        #expect(CmuxEventBus.int64(payload["revision"]) == 1)
    }

    @Test
    func verifiedReplacementStartPublishesOldExitBeforeNewOccupantState() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old",
            startsNewOccupant: true
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-new",
            startsNewOccupant: true
        )

        let payloads = fixture.agentEvents(after: baselineSequence)
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(payloads.count == 2)
        #expect(payloads.compactMap { $0["state"] as? String } == ["exit", "idle"])
        #expect(payloads.compactMap { $0["session_id"] as? String } == ["session-old", "session-new"])
        #expect(payloads.compactMap { CmuxEventBus.int64($0["revision"]) } == [1, 2])
    }

    @Test
    func anonymousSessionStartRotatesOccupantGeneration() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            startsNewOccupant: true
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .needsInput
        )
        let updated = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        #expect(updated.revision == original.revision)

        let baselineSequence = CmuxEventBus.shared.latestSequence
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            startsNewOccupant: true
        )

        let replacement = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let payloads = fixture.agentEvents(after: baselineSequence)
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(payloads.compactMap { $0["state"] as? String } == ["exit", "idle"])
        #expect(payloads.allSatisfy { $0["session_id"] is NSNull })
        #expect(replacement.revision > original.revision)
        #expect(!replacement.identifiesSameOccupant(as: original))
    }

    @Test
    func authoritativeSessionStartReplacesAnonymousOccupantAndSatisfiesPinnedExitWait() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            startsNewOccupant: true
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence
        var didReplaceOccupant = false
        let coordinator = AgentWaitCoordinator(
            eventBus: .shared,
            shouldContinue: {
                if !didReplaceOccupant {
                    didReplaceOccupant = true
                    fixture.workspace.setAgentLifecycle(
                        key: "codex",
                        panelId: fixture.surfaceID,
                        lifecycle: .running,
                        sessionID: "session-known",
                        startsNewOccupant: true
                    )
                }
                return true
            }
        )

        let result = coordinator.wait(
            surfaceID: fixture.surfaceID,
            until: .exit,
            timeoutMilliseconds: 1_000,
            snapshot: {
                fixture.workspace.agentWaitSurfaceSnapshot(surfaceID: fixture.surfaceID)
            }
        )

        let value = try result.get()
        let replacement = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let payloads = fixture.agentEvents(after: baselineSequence)
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(value.status == .satisfied)
        #expect(value.state == .exit)
        #expect(value.sessionID == nil)
        #expect(payloads.compactMap { $0["state"] as? String } == ["exit", "running"])
        #expect(payloads.first?["session_id"] is NSNull)
        #expect(payloads.last?["session_id"] as? String == "session-known")
        #expect(replacement.revision > original.revision)
        #expect(!replacement.identifiesSameOccupant(as: original))
    }

    @Test
    func duplicateAuthoritativeSessionStartPreservesOccupantGeneration() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-known",
            startsNewOccupant: true
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-known",
            startsNewOccupant: true
        )

        let duplicate = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        #expect(duplicate.revision == original.revision)
        #expect(duplicate.identifiesSameOccupant(as: original))
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    @Test
    func staleAuthoritativeUpdateCannotReplaceCurrentOccupant() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old",
            startsNewOccupant: true
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-current",
            startsNewOccupant: true
        )
        let current = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-old"
        )

        let retained = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        #expect(retained == current)
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    @Test
    func ambiguousAgentRecordsDoNotSelectAWaitOccupant() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "codex-session",
            startsNewOccupant: true
        )
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "claude-session",
            startsNewOccupant: true
        )

        let snapshot = try #require(
            fixture.workspace.agentWaitSurfaceSnapshot(surfaceID: fixture.surfaceID)
        )
        #expect(snapshot.occupant == nil)
    }

    @Test
    func socketNewOccupantFlagRotatesAnonymousGeneration() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let target = "--tab=\(workspace.id.uuidString) --panel=\(surfaceID.uuidString)"

        let firstResponse = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle codex running \(target) --new-occupant"
        )
        #expect(firstResponse == "OK")
        TerminalMutationBus.shared.drainForTesting()
        let original = try #require(
            workspace.agentLifecycleRecordsByPanelId[surfaceID]?["codex"]
        )

        let replacementResponse = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle codex idle \(target) --new-occupant"
        )
        #expect(replacementResponse == "OK")
        TerminalMutationBus.shared.drainForTesting()
        let replacement = try #require(
            workspace.agentLifecycleRecordsByPanelId[surfaceID]?["codex"]
        )

        #expect(original.sessionID == nil)
        #expect(replacement.sessionID == nil)
        #expect(replacement.revision > original.revision)
        #expect(!replacement.identifiesSameOccupant(as: original))
    }

    @Test
    func staleSessionTeardownCannotClearReplacementLifecycle() throws {
        let fixture = try Fixture()
        fixture.workspace.recordAgentPID(
            key: "codex.session-old",
            pid: getpid(),
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old"
        )
        fixture.workspace.recordAgentPID(
            key: "codex.session-new",
            pid: getpid(),
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-new",
            startsNewOccupant: true
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        let didClear = fixture.workspace.clearAgentPID(
            key: "codex.session-old",
            panelId: fixture.surfaceID,
            clearStatus: true,
            refreshPorts: false,
            expectedLifecycleSessionID: "session-old"
        )

        #expect(!didClear)
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]?.sessionID
                == "session-new"
        )
        #expect(
            fixture.workspace.agentLifecycleStatesByPanelId[fixture.surfaceID]?["codex"] == .idle
        )
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    @Test
    func liveDetachAndReattachPreservesLifecycleWithoutExit() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-live"
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        let detached = try #require(
            fixture.workspace.detachSurface(panelId: fixture.surfaceID)
        )

        #expect(detached.agentLifecycleRecords["codex"] == original)
        #expect(fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID] == nil)
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)

        let destination = Workspace()
        let destinationPane = try #require(
            destination.bonsplitController.allPaneIds.first
        )
        let attachedPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        )

        #expect(attachedPanelID == fixture.surfaceID)
        #expect(
            destination.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
                == original
        )
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    @Test
    func surfaceTreeAliasResolvesToLifecycleOwningPanel() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-alias"
        )
        let surfaceTreeID = try #require(
            fixture.workspace.surfaceIdFromPanelId(fixture.surfaceID)?.uuid
        )

        let snapshot = try #require(
            fixture.workspace.agentWaitSurfaceSnapshot(surfaceID: surfaceTreeID)
        )

        #expect(snapshot.surfaceID == fixture.surfaceID)
        #expect(snapshot.occupant?.sessionID == "session-alias")
    }

    @Test
    func dockSurfaceSnapshotUsesTransferredLifecycleOwner() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-dock"
        )
        let detached = try #require(
            fixture.workspace.detachSurface(panelId: fixture.surfaceID)
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(
            dock.attachDetachedSurface(detached, inPane: paneID, focus: false)
        )

        let snapshot = try #require(
            dock.agentWaitSurfaceSnapshot(panelID: fixture.surfaceID)
        )

        #expect(snapshot.workspaceID == dock.workspaceId)
        #expect(snapshot.surfaceID == fixture.surfaceID)
        #expect(snapshot.paneID == paneID.id)
        #expect(snapshot.occupant?.sessionID == "session-dock")
        #expect(snapshot.occupant?.state == .idle)
    }

    private struct Fixture {
        let workspace: Workspace
        let surfaceID: UUID

        @MainActor
        init() throws {
            workspace = Workspace()
            surfaceID = try #require(workspace.focusedPanelId)
        }

        func agentEvents(after sequence: Int64? = nil) -> [[String: Any]] {
            CmuxEventBus.shared.retainedSnapshot().filter { event in
                event["name"] as? String == "agent.state.changed"
                    && event["surface_id"] as? String == surfaceID.uuidString
                    && sequence.map {
                        (CmuxEventBus.int64(event["seq"]) ?? 0) > $0
                    } != false
            }
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
