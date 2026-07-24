import CMUXAgentLaunch
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent status closeout regressions")
struct AgentStatusCloseoutRegressionTests {
    @Test("Codex permission revisions remain monotonic across prompt turns")
    @MainActor
    func codexPermissionRevisionSurvivesPromptTurnReset() {
        let runtime = CodexPermissionRuntimeGeneration(
            pid: 4_242,
            pidStartSeconds: 10,
            pidStartMicroseconds: 20
        )
        let firstIdentity = CodexPermissionSignalIdentity(
            turnID: "turn-1",
            requestID: "call-1"
        )
        let sessionID = "monotonic-revision-session"
        let firstPermission = CodexPermissionTransitionMachine.reduce(
            current: nil,
            event: .permissionRequested,
            identity: firstIdentity,
            runtime: runtime
        )
        let firstCompletion = CodexPermissionTransitionMachine.reduce(
            current: firstPermission.state,
            event: .toolCompleted,
            identity: firstIdentity,
            runtime: runtime
        )
        let secondPermission = CodexPermissionTransitionMachine.reduce(
            current: nil,
            event: .permissionRequested,
            identity: CodexPermissionSignalIdentity(
                turnID: "turn-2",
                requestID: "call-2"
            ),
            runtime: runtime,
            revisionWatermark: firstCompletion.state.revision
        )

        #expect(firstCompletion.state.revision > firstPermission.state.revision)
        #expect(secondPermission.state.revision > firstCompletion.state.revision)

        let ledger = AgentStatusRuntimeLedger()
        let panelID = UUID()
        let runtimeIdentity = AgentPIDProcessIdentity(pid: getpid())
        #expect(ledger.recordLifecycle(
            .running,
            panelId: panelID,
            statusKey: "codex",
            observedAt: .now,
            runtimePIDKey: "codex.\(sessionID)",
            runtimeProcessIdentity: runtimeIdentity,
            revision: firstCompletion.state.revision
        ))
        #expect(ledger.recordLifecycle(
            .needsInput,
            panelId: panelID,
            statusKey: "codex",
            observedAt: .now,
            runtimePIDKey: "codex.\(sessionID)",
            runtimeProcessIdentity: runtimeIdentity,
            revision: secondPermission.state.revision
        ))
        #expect(ledger.evidenceForPanel(panelID)["codex"]?.lifecycle == .needsInput)
    }

    @Test("A new Codex runtime generation resets the permission revision watermark")
    func newCodexRuntimeResetsPermissionRevision() {
        let firstRuntime = CodexPermissionRuntimeGeneration(
            pid: 4_242,
            pidStartSeconds: 10,
            pidStartMicroseconds: 20
        )
        let replacementRuntime = CodexPermissionRuntimeGeneration(
            pid: 4_243,
            pidStartSeconds: 30,
            pidStartMicroseconds: 40
        )
        let identity = CodexPermissionSignalIdentity(
            turnID: "turn-1",
            requestID: "call-1"
        )
        let firstPermission = CodexPermissionTransitionMachine.reduce(
            current: nil,
            event: .permissionRequested,
            identity: identity,
            runtime: firstRuntime
        )
        #expect(firstPermission.state.revision == 1)

        let replacementPermission = CodexPermissionTransitionMachine.reduce(
            current: nil,
            event: .permissionRequested,
            identity: identity,
            runtime: replacementRuntime,
            revisionWatermark: nil
        )

        #expect(replacementPermission.state.revision == 1)
    }

    @Test("A delayed resume advances ordering without reviving Running from Idle")
    @MainActor
    func delayedResumeAfterIdleIsOrderingOnly() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let pid = getpid()
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: "codex.session",
            pid: pid,
            panelId: panelID,
            refreshPorts: false
        )
        let runtimeIdentity = try #require(
            workspace.agentPIDProcessIdentitiesByKey["codex.session"]
        )
        #expect(workspace.setAgentLifecycle(
            key: "codex",
            panelId: panelID,
            lifecycle: .idle,
            runtimePIDKey: "codex.session",
            runtimePID: Int(pid),
            runtimeProcessIdentity: runtimeIdentity,
            revision: 2
        ))

        #expect(workspace.resumeAgentLifecycleIfNeedsInput(
            key: "codex",
            panelId: panelID,
            runtimePIDKey: "codex.session",
            runtimePID: Int(pid),
            runtimeProcessIdentity: runtimeIdentity,
            revision: 3
        ))

        let evidence = workspace.sidebarAgentRuntimeObservation.agentStatusLedger
            .evidenceForPanel(panelID)["codex"]
        #expect(evidence?.lifecycle == .idle)
        #expect(evidence?.lifecycleRevision == 3)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .idle)
    }

    @Test("Resolving a newer overlapping Codex approval preserves the older approval")
    func overlappingCodexApprovalsResolveIndependently() {
        let runtime = CodexPermissionRuntimeGeneration(
            pid: 4_242,
            pidStartSeconds: 10,
            pidStartMicroseconds: 20
        )
        let olderIdentity = CodexPermissionSignalIdentity(
            turnID: "turn-1",
            requestID: "call-1"
        )
        let newerIdentity = CodexPermissionSignalIdentity(
            turnID: "turn-1",
            requestID: "call-2"
        )
        let olderNotificationID = UUID()
        let older = CodexPermissionTransitionMachine.reduce(
            current: nil,
            event: .permissionRequested,
            identity: olderIdentity,
            runtime: runtime,
            notificationID: olderNotificationID
        )
        let newer = CodexPermissionTransitionMachine.reduce(
            current: older.state,
            event: .permissionRequested,
            identity: newerIdentity,
            runtime: runtime,
            notificationID: UUID()
        )

        let newerCompleted = CodexPermissionTransitionMachine.reduce(
            current: newer.state,
            event: .toolCompleted,
            identity: newerIdentity,
            runtime: runtime
        )

        #expect(newerCompleted.state.phase == .needsInput)
        #expect(newerCompleted.state.identity == olderIdentity)
        #expect(newerCompleted.state.notificationID == olderNotificationID)
    }
}

extension AgentNotificationRegressionTests {
    @Test("Replacing a stable notification ID does not dismiss that ID")
    func sameNotificationIDReplacementIsAnUpdate() throws {
        let fixture = try makeFixture()
        let defaults = UserDefaults.standard
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = defaults.object(forKey: tombstoneKey)
        defer {
            if let previousTombstones {
                defaults.set(previousTombstones, forKey: tombstoneKey)
            } else {
                defaults.removeObject(forKey: tombstoneKey)
            }
            fixture.store.reloadDismissedTombstonesForTesting()
            fixture.restore()
        }
        defaults.removeObject(forKey: tombstoneKey)
        fixture.store.reloadDismissedTombstonesForTesting()
        AppFocusState.overrideIsFocused = true
        let notificationID = UUID()

        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Codex",
            subtitle: "Needs approval",
            body: "First rendering",
            notificationID: notificationID,
            retargetsToLiveSurfaceOwner: false
        )
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Codex",
            subtitle: "Needs approval",
            body: "Updated rendering",
            notificationID: notificationID,
            retargetsToLiveSurfaceOwner: false
        )

        #expect(fixture.store.notifications.map(\.id) == [notificationID])
        #expect(fixture.store.notifications.first?.body == "Updated rendering")
        fixture.store.replaceNotificationsForTesting([])
        fixture.store.reloadDismissedTombstonesForTesting()
        #expect(fixture.store.reconcileHandledNotificationIDs(deliveredIDs: [notificationID]).isEmpty)
    }

    @Test("A legacy PID-bearing blocking event still surfaces Needs input")
    func legacyBlockingEventWithPIDUsesOverlay() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let pid = getpid()
        fixture.source.recordAgentPID(
            key: "codex.session",
            pid: pid,
            panelId: fixture.panelId,
            refreshPorts: false
        )
        defer { fixture.source.clearAllAgentPIDs(refreshPorts: false) }
        let event = WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .permissionRequest,
            source: "codex",
            workspaceId: fixture.source.id.uuidString,
            surfaceId: fixture.panelId.uuidString,
            requestId: "legacy-approval",
            ppid: Int(pid)
        )

        let target = try #require(FeedCoordinator.shared.surfaceBlockingDecisionAttention(
            event: event,
            resolved: (fixture.source.id, fixture.panelId)
        ))
        defer { FeedCoordinator.shared.concludeBlockingDecisionAttention(target) }

        #expect(target.clearsLifecycleOnConclusion)
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["codex"] == .needsInput)
    }

    @Test(
        "Malformed structured status payloads fail closed",
        arguments: [
            #"{"_cmux_agent_status_signal":7}"#,
            #"{"_cmux_agent_status_disposition":"rejected"}"#,
            "{malformed",
        ]
    )
    func malformedStructuredStatusDoesNotUseLegacyOverlay(extraFieldsJSON: String) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let pid = getpid()
        fixture.source.recordAgentPID(
            key: "codex.session",
            pid: pid,
            panelId: fixture.panelId,
            refreshPorts: false
        )
        defer { fixture.source.clearAllAgentPIDs(refreshPorts: false) }
        fixture.source.setAgentLifecycle(
            key: "codex",
            panelId: fixture.panelId,
            lifecycle: .idle
        )
        let event = WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .permissionRequest,
            source: "codex",
            workspaceId: fixture.source.id.uuidString,
            surfaceId: fixture.panelId.uuidString,
            requestId: "malformed-approval",
            ppid: Int(pid),
            extraFieldsJSON: extraFieldsJSON
        )

        let target = try #require(FeedCoordinator.shared.surfaceBlockingDecisionAttention(
            event: event,
            resolved: (fixture.source.id, fixture.panelId)
        ))
        defer { FeedCoordinator.shared.concludeBlockingDecisionAttention(target) }

        #expect(!target.clearsLifecycleOnConclusion)
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["codex"] == .idle)
    }
}
