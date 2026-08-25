import CmuxCore
import CMUXAgentLaunch
import Darwin
import Foundation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Agent reconciliation final review", .serialized)
struct AgentReconciliationFinalReviewTests {
    @Test func retargetingMultipleStatusKeysPreservesEntryIdentity() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let sourcePaneID = try #require(
            workspace.bonsplitController.focusedPaneId
        )
        let movedPanelID = try #require(
            workspace.newTerminalSurface(
                inPane: sourcePaneID,
                focus: false
            )?.id
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        let dockPaneID = try #require(
            dock.bonsplitController.allPaneIds.first
        )
        let coordinator = FeedCoordinator.shared
        var targets: [FeedAttentionTarget] = []
        defer {
            targets.forEach {
                coordinator.concludeBlockingDecisionAttention($0)
            }
            dock.closeAllPanels()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        for source in ["codex", "claude"] {
            targets.append(
                try #require(
                    coordinator.surfaceBlockingDecisionAttention(
                        event: WorkstreamEvent(
                            sessionId: "retarget-\(source)",
                            hookEventName: .permissionRequest,
                            source: source,
                            requestId: "retarget-\(source)-request"
                        ),
                        resolved: (workspace.id, movedPanelID)
                    )
                )
            )
        }

        let transfer = try #require(
            workspace.detachSurface(panelId: movedPanelID)
        )
        #expect(
            dock.attachDetachedSurface(
                transfer,
                inPane: dockPaneID,
                focus: false
            ) == movedPanelID
        )

        let owner = ControlSidebarPanelOwner.dock(dock)
        for statusKey in ["codex", "claude_code"] {
            let entry = try #require(
                owner.statusEntry(key: statusKey, panelId: movedPanelID)
            )
            #expect(
                entry.key == statusKey,
                "A retargeted entry's stored key and intrinsic key must agree."
            )
        }
    }

    @Test func malformedOptionalAttentionEndIdentifiersFailClosed() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_007,
            relayID: "malformed-attention-end-test",
            relayToken: String(repeating: "m", count: 64),
            localSocketPath: "/tmp/cmux-malformed-attention-end-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: workspace.id,
                panelId: panelID
            )
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let generation = AgentPIDProcessIdentity(
            pid: 7_777,
            startSeconds: 700,
            startMicroseconds: 70
        )
        for malformedField in ["observation_id", "scope_id"] {
            let sessionID = "malformed-\(malformedField)-session"
            let observationID = "malformed-\(malformedField)-observation"
            let scopeID = "malformed-\(malformedField)-scope"
            #expect(
                FeedCoordinator.shared.beginObservedAgentAttention(
                    source: "amp",
                    sessionId: sessionID,
                    observationId: observationID,
                    scopeId: scopeID,
                    workspaceId: workspace.id,
                    surfaceId: panelID,
                    processGeneration: generation
                )
            )

            var params: [String: Any] = [
                "source": "amp",
                "session_id": sessionID,
                "observation_id": observationID,
                "scope_id": scopeID,
                "pid": String(generation.pid),
                "pid_start_seconds": String(generation.startSeconds),
                "pid_start_microseconds": String(
                    generation.startMicroseconds
                ),
            ]
            params[malformedField] = " "
            let result = TerminalController.shared.v2AgentAttentionEnd(
                params: params
            )
            guard case .err(let code, _, _) = result else {
                Issue.record(
                    "A present malformed \(malformedField) must be rejected."
                )
                continue
            }
            #expect(code == "invalid_params")
            #expect(
                workspace.sidebarAgentRuntimeObservation
                    .hasAgentFeedAttention(key: "amp", panelId: panelID),
                "Malformed identifiers must not become wildcard conclusions."
            )
            #expect(
                FeedCoordinator.shared.endObservedAgentAttention(
                    source: "amp",
                    sessionId: sessionID,
                    observationId: observationID,
                    scopeId: scopeID,
                    processGeneration: generation
                ) == 1
            )
        }
    }

    @Test func malformedAndCrossWorkspaceAttentionBeginTargetsFailClosed() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let foreignWorkspace = tabManager.addWorkspace(select: false)
        let panelID = try #require(workspace.focusedPanelId)
        let foreignPanelID = try #require(foreignWorkspace.focusedPanelId)
        defer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: workspace.id,
                panelId: panelID
            )
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: foreignWorkspace.id,
                panelId: foreignPanelID
            )
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            if tabManager.tabs.contains(where: { $0.id == foreignWorkspace.id }) {
                tabManager.closeWorkspace(foreignWorkspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let generation = AgentPIDProcessIdentity(
            pid: 7_778,
            startSeconds: 701,
            startMicroseconds: 71
        )
        let base: [String: Any] = [
            "source": "amp",
            "session_id": "attention-begin-target-validation",
            "observation_id": "attention-begin-target-validation-observation",
            "scope_id": "attention-begin-target-validation-scope",
            "workspace_id": workspace.id.uuidString,
            "pid": String(generation.pid),
            "pid_start_seconds": String(generation.startSeconds),
            "pid_start_microseconds": String(generation.startMicroseconds),
        ]

        var malformed = base
        malformed["surface_id"] = "not-a-surface-uuid"
        guard case .err(let malformedCode, _, _) =
            TerminalController.shared.v2AgentAttentionBegin(params: malformed)
        else {
            Issue.record("A present malformed surface_id must be rejected.")
            return
        }
        #expect(malformedCode == "invalid_params")

        let missingSurfaceResult =
            TerminalController.shared.v2AgentAttentionBegin(params: base)
        guard case .ok(let missingSurfacePayload) = missingSurfaceResult else {
            Issue.record("A missing surface should be ignored without retargeting.")
            return
        }
        #expect(missingSurfacePayload["status"] as? String == "ignored")
        #expect(
            !workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: panelID
            )
        )

        var foreign = base
        foreign["observation_id"] = "attention-begin-foreign-observation"
        foreign["scope_id"] = "attention-begin-foreign-scope"
        foreign["surface_id"] = foreignPanelID.uuidString
        let foreignResult = TerminalController.shared.v2AgentAttentionBegin(
            params: foreign
        )
        guard case .ok(let foreignPayload) = foreignResult else {
            Issue.record("A cross-workspace surface should be ignored safely.")
            return
        }
        #expect(foreignPayload["status"] as? String == "ignored")
        #expect(
            !workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: panelID
            )
        )
        #expect(
            !foreignWorkspace.sidebarAgentRuntimeObservation
                .hasAgentFeedAttention(key: "amp", panelId: foreignPanelID)
        )
    }
}
