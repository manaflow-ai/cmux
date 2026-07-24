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
    func codexPermissionRevisionSurvivesPromptTurnReset() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "cmux-codex-permission-watermark-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appending(path: "sessions.json").path
            ]
        )
        let sessionID = "monotonic-revision-session"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pid = Int(getpid())

        #expect(try store.upsertCodexSessionStartIfFresh(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            pid: pid
        ))
        let firstPermission = try #require(store.recordCodexPermissionNeedsInput(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            turnId: "turn-1",
            requestId: "call-1",
            pid: pid
        ))
        let firstCompletion = try #require(store.recordCodexToolCompleted(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            turnId: "turn-1",
            requestId: "call-1",
            pid: pid
        ))
        #expect(try store.upsertCodexPromptRunningIfFresh(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            turnId: "turn-2",
            pid: pid
        ))
        let secondPermission = try #require(store.recordCodexPermissionNeedsInput(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            turnId: "turn-2",
            requestId: "call-2",
            pid: pid
        ))

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
    func newCodexRuntimeResetsPermissionRevision() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "cmux-codex-permission-runtime-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appending(path: "sessions.json").path
            ]
        )
        let sessionID = "replacement-runtime-session"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString

        #expect(try store.upsertCodexSessionStartIfFresh(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            pid: Int(getpid())
        ))
        let firstPermission = try #require(store.recordCodexPermissionNeedsInput(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            turnId: "turn-1",
            requestId: "call-1",
            pid: Int(getpid())
        ))
        #expect(firstPermission.state.revision == 1)

        #expect(try store.upsertCodexSessionStartIfFresh(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            pid: Int(getppid())
        ))
        let replacementPermission = try #require(store.recordCodexPermissionNeedsInput(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: nil,
            turnId: "turn-1",
            requestId: "call-1",
            pid: Int(getppid())
        ))

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
