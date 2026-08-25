import CMUXAgentLaunch
import CmuxControlSocket
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    private func generatedRuntimeBinding(
        statusKey: String,
        sessionID: String,
        generation: TimeInterval
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: statusKey,
            kind: statusKey,
            command: "\(statusKey) --resume \(sessionID)",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            runtimeGeneration: generation
        )
    }

    private func publishGeneratedRuntime(
        ownerID: UUID,
        panelID: UUID,
        statusKey: String,
        runtimeKeys: [String],
        generation: TimeInterval
    ) {
        guard let authorityKey = runtimeKeys.first else { return }
        for runtimeKey in runtimeKeys {
            TerminalController.shared.controlSidebarScheduleAgentPIDRecord(
                target: .workspace(ownerID),
                key: runtimeKey,
                pid: getpid(),
                panelID: panelID,
                runtimeKey: authorityKey,
                runtimeGeneration: generation
            )
        }
        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(ownerID),
            key: statusKey,
            value: "Current",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            panelID: panelID,
            pid: nil,
            runtimeKey: authorityKey,
            runtimeGeneration: generation
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(ownerID),
            key: statusKey,
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: panelID,
            runtimeKey: authorityKey,
            runtimeGeneration: generation
        )
    }

    private func clearGeneratedRuntimeAlias(
        ownerID: UUID,
        panelID: UUID,
        runtimeKey: String,
        authorityKey: String,
        generation: TimeInterval
    ) {
        TerminalController.shared.controlSidebarScheduleAgentPIDClear(
            target: .workspace(ownerID),
            key: runtimeKey,
            panelID: panelID,
            clearStatus: true,
            requireOwnedKey: true,
            runtimeKey: authorityKey,
            runtimeGeneration: generation
        )
    }

    @Test("Workspace cleanup remains authorized across generated runtime aliases")
    func workspaceCleanupRemainsAuthorizedAcrossGeneratedRuntimeAliases() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        defer { bus.drainForTesting() }
        let statusKey = "omp"
        let sessionID = "workspace-alias-cleanup"
        let generation: TimeInterval = 200
        let binding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: sessionID,
            generation: generation
        )
        let runtimeKeys = AgentRuntimeSessionKey(
            statusKey: statusKey,
            sessionID: sessionID
        ).compatibleRawValues

        #expect(fixture.source.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        publishGeneratedRuntime(
            ownerID: fixture.source.id,
            panelID: fixture.panelId,
            statusKey: statusKey,
            runtimeKeys: runtimeKeys,
            generation: generation
        )
        bus.drainForTesting()
        #expect(runtimeKeys.allSatisfy {
            fixture.source.agentPIDKeysByPanelId[fixture.panelId]?.contains($0) == true
        })

        #expect(fixture.source.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: binding,
            agentSessionEnded: true
        ))
        clearGeneratedRuntimeAlias(
            ownerID: fixture.source.id,
            panelID: fixture.panelId,
            runtimeKey: runtimeKeys[0],
            authorityKey: runtimeKeys[0],
            generation: generation
        )
        bus.drainForTesting()
        #expect(fixture.source.agentPIDKeysByPanelId[fixture.panelId]?.contains(runtimeKeys[0]) != true)
        #expect(fixture.source.agentPIDKeysByPanelId[fixture.panelId]?.contains(runtimeKeys[1]) == true)
        #expect(fixture.source.statusEntries[statusKey]?.value == "Current")
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?[statusKey] == .running)

        clearGeneratedRuntimeAlias(
            ownerID: fixture.source.id,
            panelID: fixture.panelId,
            runtimeKey: runtimeKeys[1],
            authorityKey: runtimeKeys[0],
            generation: generation
        )
        bus.drainForTesting()
        #expect(runtimeKeys.allSatisfy {
            fixture.source.agentPIDKeysByPanelId[fixture.panelId]?.contains($0) != true
        })
        #expect(fixture.source.statusEntries[statusKey] == nil)
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?[statusKey] == nil)
    }

    @Test("Dock cleanup remains authorized across generated runtime aliases")
    func dockCleanupRemainsAuthorizedAcrossGeneratedRuntimeAliases() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        defer { bus.drainForTesting() }
        let dockOwnerID = UUID()
        let dock = DockSplitStore(workspaceId: dockOwnerID, baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)

        let statusKey = "omp"
        let sessionID = "dock-alias-cleanup"
        let generation: TimeInterval = 200
        let binding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: sessionID,
            generation: generation
        )
        let runtimeKeys = AgentRuntimeSessionKey(
            statusKey: statusKey,
            sessionID: sessionID
        ).compatibleRawValues

        #expect(dock.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        publishGeneratedRuntime(
            ownerID: dockOwnerID,
            panelID: fixture.panelId,
            statusKey: statusKey,
            runtimeKeys: runtimeKeys,
            generation: generation
        )
        bus.drainForTesting()
        #expect(runtimeKeys.allSatisfy {
            dock.agentRuntimeByPanelId[fixture.panelId]?.agentPIDKeys.contains($0) == true
        })

        #expect(dock.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: binding,
            agentSessionEnded: true
        ))
        clearGeneratedRuntimeAlias(
            ownerID: dockOwnerID,
            panelID: fixture.panelId,
            runtimeKey: runtimeKeys[0],
            authorityKey: runtimeKeys[0],
            generation: generation
        )
        bus.drainForTesting()
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentPIDKeys.contains(runtimeKeys[0]) != true)
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentPIDKeys.contains(runtimeKeys[1]) == true)
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.statusEntries[statusKey]?.value == "Current")
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentLifecycleStates[statusKey] == .running)

        clearGeneratedRuntimeAlias(
            ownerID: dockOwnerID,
            panelID: fixture.panelId,
            runtimeKey: runtimeKeys[1],
            authorityKey: runtimeKeys[0],
            generation: generation
        )
        bus.drainForTesting()
        #expect(runtimeKeys.allSatisfy {
            dock.agentRuntimeByPanelId[fixture.panelId]?.agentPIDKeys.contains($0) != true
        })
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.statusEntries[statusKey] == nil)
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentLifecycleStates[statusKey] == nil)
    }

    @Test("A missing Workspace-owned key cannot consume generated cleanup authority")
    func missingWorkspaceOwnedKeyCannotConsumeGeneratedCleanupAuthority() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        defer { bus.drainForTesting() }
        let statusKey = "omp"
        let generation: TimeInterval = 200
        let sessionKey = AgentRuntimeSessionKey(
            statusKey: statusKey,
            sessionID: "workspace-missing-owned-key"
        )
        let binding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: sessionKey.sessionID,
            generation: generation
        )
        let structuredKey = sessionKey.rawValue
        let missingLegacyKey = sessionKey.compatibleRawValues[1]

        #expect(fixture.source.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        publishGeneratedRuntime(
            ownerID: fixture.source.id,
            panelID: fixture.panelId,
            statusKey: statusKey,
            runtimeKeys: [structuredKey],
            generation: generation
        )
        bus.drainForTesting()

        clearGeneratedRuntimeAlias(
            ownerID: fixture.source.id,
            panelID: fixture.panelId,
            runtimeKey: missingLegacyKey,
            authorityKey: structuredKey,
            generation: generation
        )
        bus.drainForTesting()
        #expect(fixture.source.agentPIDKeysByPanelId[fixture.panelId]?.contains(missingLegacyKey) != true)

        TerminalController.shared.controlSidebarScheduleAgentPIDRecord(
            target: .workspace(fixture.source.id),
            key: missingLegacyKey,
            pid: getpid(),
            panelID: fixture.panelId,
            runtimeKey: structuredKey,
            runtimeGeneration: generation
        )
        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: statusKey,
            value: "Still current",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil,
            runtimeKey: structuredKey,
            runtimeGeneration: generation
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: statusKey,
            lifecycleRawValue: AgentHibernationLifecycleState.needsInput.rawValue,
            panelID: fixture.panelId,
            runtimeKey: structuredKey,
            runtimeGeneration: generation
        )
        bus.drainForTesting()

        #expect(fixture.source.agentPIDKeysByPanelId[fixture.panelId]?.contains(missingLegacyKey) == true)
        #expect(fixture.source.statusEntries[statusKey]?.value == "Still current")
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?[statusKey] == .needsInput)
    }

    @Test("A missing Dock-owned key cannot consume generated cleanup authority")
    func missingDockOwnedKeyCannotConsumeGeneratedCleanupAuthority() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        defer { bus.drainForTesting() }
        let dockOwnerID = UUID()
        let dock = DockSplitStore(workspaceId: dockOwnerID, baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)
        let statusKey = "omp"
        let generation: TimeInterval = 200
        let sessionKey = AgentRuntimeSessionKey(
            statusKey: statusKey,
            sessionID: "dock-missing-owned-key"
        )
        let binding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: sessionKey.sessionID,
            generation: generation
        )
        let structuredKey = sessionKey.rawValue
        let missingLegacyKey = sessionKey.compatibleRawValues[1]

        #expect(dock.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        publishGeneratedRuntime(
            ownerID: dockOwnerID,
            panelID: fixture.panelId,
            statusKey: statusKey,
            runtimeKeys: [structuredKey],
            generation: generation
        )
        bus.drainForTesting()

        clearGeneratedRuntimeAlias(
            ownerID: dockOwnerID,
            panelID: fixture.panelId,
            runtimeKey: missingLegacyKey,
            authorityKey: structuredKey,
            generation: generation
        )
        bus.drainForTesting()
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentPIDKeys.contains(missingLegacyKey) != true)

        TerminalController.shared.controlSidebarScheduleAgentPIDRecord(
            target: .workspace(dockOwnerID),
            key: missingLegacyKey,
            pid: getpid(),
            panelID: fixture.panelId,
            runtimeKey: structuredKey,
            runtimeGeneration: generation
        )
        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(dockOwnerID),
            key: statusKey,
            value: "Still current",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil,
            runtimeKey: structuredKey,
            runtimeGeneration: generation
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(dockOwnerID),
            key: statusKey,
            lifecycleRawValue: AgentHibernationLifecycleState.needsInput.rawValue,
            panelID: fixture.panelId,
            runtimeKey: structuredKey,
            runtimeGeneration: generation
        )
        bus.drainForTesting()

        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentPIDKeys.contains(missingLegacyKey) == true)
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.statusEntries[statusKey]?.value == "Still current")
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentLifecycleStates[statusKey] == .needsInput)
    }

    @Test("A queued SessionEnd notification clear accepts its retired runtime authority")
    func queuedSessionEndNotificationClearAcceptsRetiredAuthority() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }
        let statusKey = "codex"
        let generation: TimeInterval = 200
        let sessionID = "retired-notification-clear"
        let binding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: sessionID,
            generation: generation
        )
        let runtimeKey = AgentRuntimeSessionKey(
            statusKey: statusKey,
            sessionID: sessionID
        ).rawValue

        #expect(fixture.source.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Codex",
            subtitle: "Completed",
            body: "Ended runtime",
            runtimeKey: runtimeKey,
            runtimeGeneration: generation
        )
        bus.drainForTesting()
        #expect(fixture.store.notifications.map(\.body) == ["Ended runtime"])

        bus.setDrainsSuspendedForTesting(true)
        bus.enqueueClearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            runtimeKey: runtimeKey,
            runtimeGeneration: generation
        )
        #expect(fixture.source.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: binding,
            agentSessionEnded: true
        ))
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.store.notifications.isEmpty)
    }

    @Test("A retired runtime cannot clear a replacement runtime notification")
    func retiredRuntimeCannotClearReplacementNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }
        let statusKey = "codex"
        let retiredGeneration: TimeInterval = 200
        let replacementGeneration: TimeInterval = 201
        let retiredBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "retired-notification-runtime",
            generation: retiredGeneration
        )
        let replacementBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "replacement-notification-runtime",
            generation: replacementGeneration
        )
        let retiredRuntimeKey = AgentRuntimeSessionKey(
            statusKey: statusKey,
            sessionID: "retired-notification-runtime"
        ).rawValue
        let replacementRuntimeKey = AgentRuntimeSessionKey(
            statusKey: statusKey,
            sessionID: "replacement-notification-runtime"
        ).rawValue

        #expect(fixture.source.setSurfaceResumeBinding(retiredBinding, panelId: fixture.panelId))
        #expect(fixture.source.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: retiredBinding,
            agentSessionEnded: true
        ))
        #expect(fixture.source.setSurfaceResumeBinding(replacementBinding, panelId: fixture.panelId))
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Codex",
            subtitle: "Completed",
            body: "Replacement runtime",
            runtimeKey: replacementRuntimeKey,
            runtimeGeneration: replacementGeneration
        )
        bus.drainForTesting()
        #expect(fixture.store.notifications.map(\.body) == ["Replacement runtime"])

        bus.enqueueClearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            runtimeKey: retiredRuntimeKey,
            runtimeGeneration: retiredGeneration
        )
        bus.drainForTesting()

        #expect(fixture.store.notifications.map(\.body) == ["Replacement runtime"])
    }

    @Test("A runtime replaced during policy evaluation cannot deliver late effects")
    func policyDelayedNotificationReauthorizesAfterRuntimeReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-policy-runtime-replacement-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let startedURL = root.appendingPathComponent("started")
        let proceedURL = root.appendingPathComponent("proceed")
        let completedURL = root.appendingPathComponent("completed")
        let command = "touch '\(startedURL.path)'; while [ ! -e '\(proceedURL.path)' ]; do sleep 0.05; done; cat; touch '\(completedURL.path)'"
        let fixture = try makeFixture(
            policyHookCommand: command,
            policyHookTimeoutSeconds: 60
        )
        defer {
            fixture.restore()
            try? FileManager.default.removeItem(at: root)
        }

        let statusKey = "codex"
        let staleGeneration: TimeInterval = 200
        let replacementGeneration: TimeInterval = 201
        let staleBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "policy-stale-runtime",
            generation: staleGeneration
        )
        let replacementBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "policy-replacement-runtime",
            generation: replacementGeneration
        )
        let staleRuntimeKey = try #require(staleBinding.agentRuntimeSessionKey).rawValue

        #expect(fixture.source.setSurfaceResumeBinding(staleBinding, panelId: fixture.panelId))
        TerminalController.shared.deliverNotificationSynchronously(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Codex",
            subtitle: "Completed",
            body: "Must not survive replacement",
            runtimeKey: staleRuntimeKey,
            runtimeGeneration: staleGeneration
        )
        #expect(await waitForMarker(at: startedURL))

        #expect(fixture.source.setSurfaceResumeBinding(
            replacementBinding,
            panelId: fixture.panelId
        ))
        _ = FileManager.default.createFile(atPath: proceedURL.path, contents: nil)
        #expect(await waitForMarker(at: completedURL))
        for _ in 0..<100 { await Task.yield() }

        #expect(
            fixture.store.notifications.isEmpty,
            "Final apply must reauthorize after asynchronous policy work"
        )
    }

    @Test("Independent agent generation sequences do not block each other")
    func runtimeHighWaterMarksAreScopedByStatusKey() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let codex = generatedRuntimeBinding(
            statusKey: "codex",
            sessionID: "high-codex-generation",
            generation: 500
        )
        let omp = generatedRuntimeBinding(
            statusKey: "omp",
            sessionID: "low-omp-generation",
            generation: 1
        )

        #expect(fixture.source.setSurfaceResumeBinding(codex, panelId: fixture.panelId))
        #expect(fixture.source.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: codex,
            agentSessionEnded: true
        ))
        #expect(
            fixture.source.setSurfaceResumeBinding(omp, panelId: fixture.panelId),
            "A different status key owns an independent store sequence"
        )
    }

    @Test("A delayed clear cannot remove another agent's replacement runtime")
    func delayedCrossAgentClearPreservesReplacement() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let checkpointID = "shared-checkpoint"
        let generation: TimeInterval = 1
        let retired = generatedRuntimeBinding(
            statusKey: "codex",
            sessionID: checkpointID,
            generation: generation
        )
        let replacement = generatedRuntimeBinding(
            statusKey: "omp",
            sessionID: checkpointID,
            generation: generation
        )

        #expect(fixture.source.setSurfaceResumeBinding(retired, panelId: fixture.panelId))
        #expect(fixture.source.setSurfaceResumeBinding(replacement, panelId: fixture.panelId))

        let resolution = TerminalController.shared.controlSurfaceResumeClear(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: fixture.source.id,
                surfaceID: fixture.panelId,
                paneID: nil
            ),
            explicitTargetID: fixture.panelId,
            hasResolvedWindowID: false,
            expectedCheckpointID: checkpointID,
            expectedSource: "agent-hook",
            runtimeStatusKey: "codex",
            runtimeGeneration: generation,
            agentSessionEnded: true
        )

        guard case .result(let snapshot) = resolution else {
            Issue.record("Expected a successful guarded clear, got \(resolution)")
            return
        }
        #expect(snapshot.cleared)
        #expect(fixture.source.surfaceResumeBinding(panelId: fixture.panelId) == replacement)
        #expect(snapshot.binding?.kind == "omp")
    }

    @Test("The app reports a runtime generation floor after binding teardown")
    func clearedBindingRetainsQueryableRuntimeGenerationFloor() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let generation: TimeInterval = 500
        let binding = generatedRuntimeBinding(
            statusKey: "codex",
            sessionID: "cleared-floor",
            generation: generation
        )

        #expect(fixture.source.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        #expect(fixture.source.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: binding,
            agentSessionEnded: true
        ))

        let resolution = TerminalController.shared.controlSurfaceResumeGet(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: fixture.source.id,
                surfaceID: fixture.panelId,
                paneID: nil
            ),
            explicitTargetID: fixture.panelId,
            hasResolvedWindowID: false,
            runtimeStatusKey: "codex"
        )

        guard case .result(let snapshot) = resolution else {
            Issue.record("Expected a resume snapshot, got \(resolution)")
            return
        }
        #expect(snapshot.binding == nil)
        #expect(snapshot.runtimeGenerationFloor == generation)
    }

    @Test("Runtime generation floors survive a session snapshot restore")
    func runtimeGenerationFloorSurvivesSessionSnapshotRestore() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let generation: TimeInterval = 500
        let binding = generatedRuntimeBinding(
            statusKey: "codex",
            sessionID: "persisted-floor",
            generation: generation
        )
        #expect(fixture.source.setSurfaceResumeBinding(binding, panelId: fixture.panelId))
        #expect(fixture.source.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: binding,
            agentSessionEnded: true
        ))

        let persisted = fixture.source.sessionSnapshot(includeScrollback: false)
        let terminalSnapshot = try #require(
            persisted.panels.first(where: { $0.id == fixture.panelId })?.terminal
        )
        #expect(
            terminalSnapshot.runtimeGenerationHighWaterMarksByStatusKey?["codex"] == generation
        )

        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        _ = restored.restoreSessionSnapshot(persisted)
        let restoredPanelID = try #require(restored.focusedPanelId)
        #expect(
            restored.restoredAgentLifecycle.agentRuntimeGenerationFloor(
                statusKey: "codex",
                panelId: restoredPanelID
            ) == generation
        )
    }

    @Test("Workspace binding generations remain monotonic after teardown")
    func workspaceBindingGenerationsRemainMonotonicAfterTeardown() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let statusKey = "omp"
        let oldBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "session-b",
            generation: 100
        )
        let currentBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "session-b",
            generation: 200
        )
        let staleBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "session-a",
            generation: 100
        )
        let newerBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "session-c",
            generation: 201
        )

        #expect(fixture.source.setSurfaceResumeBinding(oldBinding, panelId: fixture.panelId))
        #expect(fixture.source.setSurfaceResumeBinding(currentBinding, panelId: fixture.panelId))
        #expect(!fixture.source.setSurfaceResumeBinding(oldBinding, panelId: fixture.panelId))
        #expect(fixture.source.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: oldBinding,
            agentSessionEnded: true
        ))
        #expect(fixture.source.surfaceResumeBinding(panelId: fixture.panelId) == currentBinding)
        #expect(!fixture.source.setSurfaceResumeBinding(staleBinding, panelId: fixture.panelId))

        #expect(fixture.source.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: currentBinding,
            agentSessionEnded: true
        ))
        #expect(!fixture.source.setSurfaceResumeBinding(staleBinding, panelId: fixture.panelId))
        #expect(!fixture.source.setSurfaceResumeBinding(currentBinding, panelId: fixture.panelId))
        #expect(fixture.source.setSurfaceResumeBinding(newerBinding, panelId: fixture.panelId))
        #expect(fixture.source.surfaceResumeBinding(panelId: fixture.panelId) == newerBinding)
    }

    @Test("Dock binding generations remain monotonic after teardown")
    func dockBindingGenerationsRemainMonotonicAfterTeardown() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)

        let statusKey = "omp"
        let oldBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "dock-session-b",
            generation: 100
        )
        let currentBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "dock-session-b",
            generation: 200
        )
        let staleBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "dock-session-a",
            generation: 100
        )
        let newerBinding = generatedRuntimeBinding(
            statusKey: statusKey,
            sessionID: "dock-session-c",
            generation: 201
        )

        #expect(dock.setSurfaceResumeBinding(oldBinding, panelId: fixture.panelId))
        #expect(dock.setSurfaceResumeBinding(currentBinding, panelId: fixture.panelId))
        #expect(!dock.setSurfaceResumeBinding(oldBinding, panelId: fixture.panelId))
        #expect(dock.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: oldBinding,
            agentSessionEnded: true
        ))
        #expect(dock.surfaceResumeBinding(panelId: fixture.panelId) == currentBinding)
        #expect(!dock.setSurfaceResumeBinding(staleBinding, panelId: fixture.panelId))

        #expect(dock.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            binding: currentBinding,
            agentSessionEnded: true
        ))
        #expect(!dock.setSurfaceResumeBinding(staleBinding, panelId: fixture.panelId))
        #expect(!dock.setSurfaceResumeBinding(currentBinding, panelId: fixture.panelId))
        #expect(dock.setSurfaceResumeBinding(newerBinding, panelId: fixture.panelId))
        #expect(dock.surfaceResumeBinding(panelId: fixture.panelId) == newerBinding)
    }
}
