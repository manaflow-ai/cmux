import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SessionCardSnapshotTests {
    @Test func modeParsingFallsBackToDefault() {
        #expect(SessionCardSnapshot.Mode(metadataValue: "Plan") == .plan)
        #expect(SessionCardSnapshot.Mode(metadataValue: "permission_edit") == .edit)
        #expect(SessionCardSnapshot.Mode(metadataValue: "anything else") == .defaultMode)
        #expect(SessionCardSnapshot.Mode(metadataValue: nil) == .defaultMode)
    }

    @Test func statusParsingRecognizesAgentLifecycleWords() {
        #expect(SessionCardSnapshot.Status(metadataValue: "working") == .working)
        #expect(SessionCardSnapshot.Status(metadataValue: "needs_input") == .needsInput)
        #expect(SessionCardSnapshot.Status(metadataValue: "ready") == .ready)
        #expect(SessionCardSnapshot.Status(metadataValue: "offline") == .exited)
        #expect(SessionCardSnapshot.Status(metadataValue: "unknown-status") == nil)
    }

    @Test func diffParsingNormalizesSignedCounts() {
        #expect(SessionCardSnapshot.Diff.parseCount("+318") == 318)
        #expect(SessionCardSnapshot.Diff.parseCount("-92") == 92)
        #expect(SessionCardSnapshot.Diff.parseCount("") == 0)
        #expect(
            SessionCardSnapshot.Diff(added: -1, deleted: -2)
                == SessionCardSnapshot.Diff(added: 1, deleted: 2)
        )
    }

    @Test func workspaceNumberClampsToSupportedBadgeRange() {
        #expect(Self.snapshot(workspaceNumber: 0).workspaceNumber == 1)
        #expect(Self.snapshot(workspaceNumber: 7).workspaceNumber == 7)
        #expect(Self.snapshot(workspaceNumber: 42).workspaceNumber == 10)
    }

    @Test func explicitAndDefaultBadgesArePreserved() {
        #expect(Self.snapshot(workspaceNumber: 42).badge == .indexedWorktree(10))
        let snapshot = SessionCardSnapshot(
            workspaceNumber: 7,
            name: "Card",
            colorHex: "#4493F8",
            host: .devbox,
            branchName: "main",
            modelName: "gpt-5",
            mode: .plan,
            status: .working,
            diff: SessionCardSnapshot.Diff(added: 1, deleted: 2),
            badge: .unindexedHost(.devbox)
        )
        #expect(snapshot.badge == .unindexedHost(.devbox))
    }

    @Test func indexedWorktreeParsingRecognizesWorkspaceLaunchers() {
        #expect(SessionCardSnapshot.indexedWorktreeNumber(in: "/projects/service-wk3") == 3)
        #expect(SessionCardSnapshot.indexedWorktreeNumber(in: "~/ws-wk3.sh") == 3)
        #expect(SessionCardSnapshot.indexedWorktreeNumber(in: "[wk10] local") == 10)
        #expect(SessionCardSnapshot.indexedWorktreeNumber(in: "/tmp/wk7") == 7)
        #expect(SessionCardSnapshot.indexedWorktreeNumber(in: "7️⃣ Cmux Test Six") == 7)
        #expect(SessionCardSnapshot.indexedWorktreeNumber(in: "/tmp/wk7-extra") == nil)
    }

    private static func snapshot(workspaceNumber: Int) -> SessionCardSnapshot {
        SessionCardSnapshot(
            workspaceNumber: workspaceNumber,
            name: "Card",
            colorHex: "#4493F8",
            host: .laptop,
            branchName: "main",
            modelName: "gpt-5",
            mode: .plan,
            status: .working,
            diff: SessionCardSnapshot.Diff(added: 1, deleted: 2)
        )
    }

    @Test func lifecycleGroupsPrioritizePinnedAndAttentionStates() {
        #expect(SessionCardGroup.resolveID(status: .working, isPinned: true, configured: []) == "pinned")
        #expect(SessionCardGroup.resolveID(status: .needsInput, isPinned: false, configured: []) == "needsAttention")
        #expect(SessionCardGroup.resolveID(status: .working, isPinned: false, configured: []) == "running")
        #expect(SessionCardGroup.resolveID(status: .done, isPinned: false, configured: []) == "finished")
        #expect(SessionCardGroup.resolveID(status: .exited, isPinned: false, configured: []) == "finished")
    }

    @MainActor
    @Test func sessionListProjectionIncludesHeadersAndHidesCollapsedRows() {
        let pinnedWorkspaceID = UUID()
        let runningWorkspaceID = UUID()
        let rows = [
            SidebarSessionRowSnapshot(
                id: pinnedWorkspaceID,
                status: .working,
                groupID: SessionCardGroup.pinnedID
            ),
            SidebarSessionRowSnapshot(
                id: runningWorkspaceID,
                status: .working,
                groupID: "running"
            ),
        ]

        let items = SidebarSessionListItem.renderItems(
            groups: SessionCardGroup.groups(configured: []),
            rows: rows,
            collapsedGroupIDs: ["running"]
        )

        #expect(items.map(\.id) == [
            .group(SessionCardGroup.pinnedID),
            .workspace(pinnedWorkspaceID),
            .group("running"),
        ])
        #expect(items.visibleWorkspaceIDs == [pinnedWorkspaceID])
    }

    @Test func appKitSidebarPreservesCustomSessionCardPresentation() {
        let sessionCard = SidebarWorkspaceRowPresentation.resolve(hasSessionCard: true)
        let nativeWorkspace = SidebarWorkspaceRowPresentation.resolve(hasSessionCard: false)

        #expect(sessionCard == .hostedSessionCard)
        #expect(!sessionCard.usesNativeChrome)
        #expect(nativeWorkspace == .nativeWorkspace)
        #expect(nativeWorkspace.usesNativeChrome)
    }

    @MainActor
    @Test func persistentRemoteSessionRemainsRestartableAfterDisconnect() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "devbox",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64_017,
                relayID: "session-card-restart",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-session-card-restart.sock",
                terminalStartupCommand: "ssh devbox",
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "session-card-restart"
            ),
            autoConnect: false
        )
        workspace.trackRemoteTerminalSurface(panelId)
        workspace.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
                workingDirectory: "/projects/service-wk1",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/opt/homebrew/bin/codex",
                    arguments: ["/opt/homebrew/bin/codex"],
                    workingDirectory: "/projects/service-wk1",
                    environment: nil,
                    capturedAt: 123,
                    source: "process"
                )
            ),
            panelId: panelId
        )

        #expect(workspace.markRemoteTerminalSessionEnded(surfaceId: panelId, relayPort: 64_017))
        #expect(!workspace.activeRemoteTerminalSurfaceIds.contains(panelId))
    }
}
