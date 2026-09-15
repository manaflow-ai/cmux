import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SurfaceResumeAgentBindingGenerationTests {
    @Test("A stale cached session cannot authorize the current binding")
    func staleCachedSessionCannotAuthorizeCurrentBinding() throws {
        try withFixture { source, defaults, index in
            let currentSessionID = "codex-current-dead-session"
            let bindingIndex = codexBindingIndex(
                sessionID: currentSessionID,
                workspaceID: source.id,
                panelID: try #require(source.focusedPanelId)
            )

            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: index,
                surfaceResumeBindingIndex: bindingIndex
            )

            #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)
            try expectNoResumeLaunch(snapshot: snapshot, defaults: defaults)
        }
    }

    @Test("Remote shell activity cannot authorize a mismatched hook binding")
    func remoteShellActivityCannotAuthorizeMismatchedHookBinding() throws {
        let defaultsName = "cmux-remote-binding-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)

        // Model an authenticated remote terminal whose shell is busy, while
        // the persisted agent snapshot belongs to an older session. The
        // incoming hook binding is therefore not authorized by that activity.
        workspace.activeRemoteTerminalSurfaceIds.insert(panelID)
        workspace.updatePanelShellActivityState(
            panelId: panelID,
            state: .commandRunning
        )
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "codex-stale-remote-session",
                workingDirectory: "/tmp/stale-remote",
                launchCommand: nil
            ),
            panelId: panelID
        )
        let currentSessionID = "codex-current-remote-session"
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(
                workspaceId: workspace.id,
                panelId: panelID
            ): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume \(currentSessionID)",
                cwd: "/tmp/current-remote",
                checkpointId: currentSessionID,
                source: "agent-hook",
                autoResume: true
            ),
        ])

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: bindingIndex
        )

        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)
    }

    @Test("A definitive exited observation outranks remote shell activity")
    func definitiveExitedRemoteObservationOutranksShellActivity() throws {
        try withFixture { source, _, index in
            let panelID = try #require(source.focusedPanelId)
            source.activeRemoteTerminalSurfaceIds.insert(panelID)
            source.updatePanelShellActivityState(
                panelId: panelID,
                state: .commandRunning
            )

            // The fixture's matching hook record has a PID that the loader
            // confirms exited. A stale command-running shell report must not
            // revive that binding during snapshot projection.
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: index,
                surfaceResumeBindingIndex: codexBindingIndex(
                    sessionID: "codex-stale-cached-session",
                    workspaceID: source.id,
                    panelID: panelID
                )
            )

            #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)
        }
    }

    @Test("An identity-matched remote binding retains shell activity evidence")
    func identityMatchedRemoteBindingRetainsShellActivityEvidence() throws {
        let defaultsName = "cmux-remote-binding-evidence-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "codex-current-remote-session"
        workspace.activeRemoteTerminalSurfaceIds.insert(panelID)
        workspace.updatePanelShellActivityState(
            panelId: panelID,
            state: .commandRunning
        )
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionID,
                workingDirectory: "/tmp/current-remote",
                launchCommand: nil
            ),
            panelId: panelID
        )

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: codexBindingIndex(
                sessionID: sessionID,
                workspaceID: workspace.id,
                panelID: panelID
            )
        )

        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == true)
    }

    @Test("A contradictory panel-only observation blocks remote shell evidence")
    func contradictoryPanelObservationBlocksRemoteShellEvidence() throws {
        try withFixture { source, _, index in
            let panelID = try #require(source.focusedPanelId)
            let sessionID = "codex-current-remote-session"
            source.activeRemoteTerminalSurfaceIds.insert(panelID)
            source.updatePanelShellActivityState(
                panelId: panelID,
                state: .commandRunning
            )
            source.setRestoredAgentSnapshotForTesting(
                SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: sessionID,
                    workingDirectory: "/tmp/current-remote",
                    launchCommand: nil
                ),
                panelId: panelID
            )
            // Keep the retained snapshot as the queued restore identity so
            // the panel-only observation below is genuinely contradictory,
            // rather than being allowed to replace it during projection.
            source.restoredAgentLifecycle.setResumeState(
                .awaitingAutoResumeCommand,
                panelId: panelID
            )

            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: index,
                surfaceResumeBindingIndex: codexBindingIndex(
                    sessionID: sessionID,
                    workspaceID: source.id,
                    panelID: panelID
                )
            )

            #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)
        }
    }

}
