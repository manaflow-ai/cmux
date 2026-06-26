import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for custom-title provenance: auto-naming writes must never
/// overwrite user-set titles, clearing must reset provenance, and provenance
/// must round-trip through session snapshots (with legacy snapshots that
/// predate provenance decoding as user-owned).
@MainActor
@Suite struct WorkspaceTitleProvenanceTests {

    // MARK: - Workspace titles

    @Test func autoWriteOnUntitledWorkspaceLands() {
        let workspace = Workspace(title: "Terminal")
        let applied = workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(applied)
        #expect(workspace.title == "Fix auth bug")
        #expect(workspace.customTitle == "Fix auth bug")
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func autoWriteOverUserTitleIsRejected() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("My Project")
        let applied = workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(!applied)
        #expect(workspace.title == "My Project")
        #expect(workspace.effectiveCustomTitleSource == .user)
    }

    @Test func userWriteOverAutoTitleLandsAndClaimsOwnership() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        let applied = workspace.setCustomTitle("Release prep")
        #expect(applied)
        #expect(workspace.title == "Release prep")
        #expect(workspace.effectiveCustomTitleSource == .user)
        // The workspace is now user-owned: further auto writes must be rejected.
        #expect(!workspace.setCustomTitle("Something else", source: .auto))
    }

    @Test func autoWriteCanRefreshAutoTitle() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        let applied = workspace.setCustomTitle("Debug login flow", source: .auto)
        #expect(applied)
        #expect(workspace.title == "Debug login flow")
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func autoWriteNeverClears() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)
        #expect(!workspace.setCustomTitle(nil, source: .auto))
        #expect(!workspace.setCustomTitle("   ", source: .auto))
        #expect(workspace.title == "Fix auth bug")
    }

    @Test func clearingUserTitleRevertsToProcessTitleAndAllowsAutoWrite() {
        let workspace = Workspace(title: "Terminal")
        workspace.applyProcessTitle("zsh")
        workspace.setCustomTitle("My Project")
        workspace.setCustomTitle(nil)
        #expect(workspace.title == "zsh")
        #expect(workspace.customTitle == nil)
        #expect(workspace.effectiveCustomTitleSource == nil)
        #expect(workspace.setCustomTitle("Fix auth bug", source: .auto))
        #expect(workspace.effectiveCustomTitleSource == .auto)
    }

    @Test func carriedTitleWithoutProvenanceIsTreatedAsUserOwned() {
        let workspace = Workspace(title: "Terminal")
        // Simulate a custom title that arrived without provenance (legacy
        // restore, carried panel move): direct assignment bypasses the setter.
        workspace.customTitle = "Carried Title"
        #expect(workspace.effectiveCustomTitleSource == .user)
        #expect(!workspace.setCustomTitle("Fix auth bug", source: .auto))
        #expect(workspace.customTitle == "Carried Title")
    }

    // MARK: - Panel titles

    @Test func panelProvenanceMirrorsWorkspaceRules() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Fix auth bug", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Fix auth bug")
        #expect(workspace.panelCustomTitleSources[panelId] == .auto)

        // User rename wins and claims ownership.
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Build Pane"))
        #expect(workspace.panelCustomTitleSources[panelId] == .user)
        #expect(!workspace.setPanelCustomTitle(panelId: panelId, title: "Other", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Build Pane")

        // Clearing resets provenance and re-opens the panel to auto naming.
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: nil))
        #expect(workspace.panelCustomTitles[panelId] == nil)
        #expect(workspace.panelCustomTitleSources[panelId] == nil)
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Refreshed", source: .auto))
        #expect(workspace.panelCustomTitleSources[panelId] == .auto)
    }

    @Test func panelAutoWriteRejectedForCarriedTitleWithoutProvenance() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        // Simulate a carried title (move/respawn flows write the dictionary
        // directly when no provenance traveled with the title).
        workspace.panelCustomTitles[panelId] = "Carried Tab"
        #expect(!workspace.setPanelCustomTitle(panelId: panelId, title: "Other", source: .auto))
        #expect(workspace.panelCustomTitles[panelId] == "Carried Tab")
    }

    // MARK: - Snapshot round-trip

    @Test func workspaceSnapshotRoundTripPreservesProvenance() throws {
        var snapshot = SessionWorkspaceSnapshot(
            processTitle: "zsh",
            customTitle: "Fix auth bug",
            customTitleSource: .auto,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
        let decoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded.customTitleSource == .auto)

        // Legacy shape: encoding a nil source omits the key, which is exactly
        // what snapshots persisted before provenance look like on disk.
        snapshot.customTitleSource = nil
        let legacyDecoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(legacyDecoded.customTitleSource == nil)

        // Restore semantics: absent provenance restores as user-owned.
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle(legacyDecoded.customTitle, source: legacyDecoded.customTitleSource ?? .user)
        #expect(workspace.effectiveCustomTitleSource == .user)
    }

    @Test func restoreDropsUnverifiedAutoWorkspaceTitle() {
        let workspace = Workspace(title: "Terminal")
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "zsh",
            customTitle: "Foreign Summary",
            customTitleSource: .auto,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )

        workspace.restoreSessionSnapshot(snapshot)

        #expect(workspace.customTitle == nil)
        #expect(workspace.effectiveCustomTitleSource == nil)
        #expect(workspace.title == "zsh")
    }

    @Test func restorePreservesLegacyWorkspaceTitleWithoutProvenance() {
        let workspace = Workspace(title: "Terminal")
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "zsh",
            customTitle: "Legacy Title",
            customTitleSource: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )

        workspace.restoreSessionSnapshot(snapshot)

        #expect(workspace.customTitle == "Legacy Title")
        #expect(workspace.effectiveCustomTitleSource == .user)
        #expect(workspace.title == "Legacy Title")
    }

    @Test func restoreDropsUnverifiedAutoPanelFallbackTitle() throws {
        let panelId = UUID()
        let snapshot = SessionWorkspaceSnapshot(
            workspaceId: UUID(),
            processTitle: "zsh",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            groupId: nil,
            isManuallyUnread: false,
            hasUnreadIndicator: false,
            notifications: nil,
            terminalScrollBarHidden: nil,
            currentDirectory: "/tmp",
            focusedPanelId: panelId,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)),
            panels: [
                Self.terminalPanelSnapshot(
                    id: panelId,
                    title: "Foreign Summary",
                    customTitle: "Foreign Summary",
                    customTitleSource: .auto
                )
            ],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil
        )
        let workspace = Workspace(title: "Terminal")

        let restoredIds = workspace.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredIds[panelId])

        #expect(workspace.panelCustomTitles[restoredPanelId] == nil)
        #expect(workspace.panelTitles[restoredPanelId] != "Foreign Summary")
        #expect(workspace.panelTitle(panelId: restoredPanelId) != "Foreign Summary")
    }

    @Test func replacedResumeBindingDoesNotReuseStoredVerification() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let firstBinding = Self.resumeBinding(sessionId: "sess-a", cwd: "/tmp/a")
        let secondBinding = Self.resumeBinding(sessionId: "sess-b", cwd: "/tmp/b")

        #expect(workspace.setSurfaceResumeBinding(firstBinding, panelId: panelId))
        workspace.restoredAgentVerificationByPanelId[panelId] = Self.verifiedCrashRecovery(
            binding: firstBinding
        )
        #expect(workspace.transcriptExistsAtWindowCwd)

        #expect(workspace.setSurfaceResumeBinding(secondBinding, panelId: panelId))

        #expect(workspace.restoredAgentVerificationByPanelId[panelId] == nil)
        #expect(!workspace.transcriptExistsAtWindowCwd)
    }

    @Test func cachedVerificationMustMatchRestoredPanelBinding() {
        let firstBinding = Self.resumeBinding(sessionId: "sess-a", cwd: "/tmp/a")
        let secondBinding = Self.resumeBinding(sessionId: "sess-b", cwd: "/tmp/b")
        let snapshot = Self.terminalPanelSnapshot(
            id: UUID(),
            title: "Foreign Summary",
            customTitle: "Foreign Summary",
            customTitleSource: .auto,
            resumeBinding: secondBinding
        )

        let verified = Workspace.restoredPanelNameIsVerified(
            snapshot,
            cachedVerification: Self.verifiedCrashRecovery(binding: firstBinding)
        )

        #expect(!verified)
    }

    private static func terminalPanelSnapshot(
        id: UUID,
        title: String,
        customTitle: String?,
        customTitleSource: Workspace.CustomTitleSource?,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil
    ) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: title,
            customTitle: customTitle,
            customTitleSource: customTitleSource,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            hasUnreadIndicator: false,
            restoredUnreadContributesToWorkspace: nil,
            notifications: nil,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(resumeBinding: resumeBinding),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            agentSession: nil,
            project: nil
        )
    }

    private static func resumeBinding(sessionId: String, cwd: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            kind: RestorableAgentKind.claude.rawValue,
            command: "claude --resume \(sessionId)",
            cwd: cwd,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true
        )
    }

    private static func verifiedCrashRecovery(binding: SurfaceResumeBindingSnapshot) -> CrashRecoveryVerification {
        CrashRecoveryVerification(
            facts: ResumeBindingFacts(
                hasBinding: true,
                agentKind: RestorableAgentKind.claude,
                sessionId: binding.checkpointId,
                resumeCommandConstructable: true,
                transcriptExistsAtWindowCwd: true,
                transcriptExistsElsewhere: false
            ),
            presence: ClaudeTranscriptPresence(
                existsAtWindowCwd: true,
                existsElsewhere: false,
                resolvedPathAtWindowCwd: "/tmp/transcript.jsonl"
            ),
            fingerprint: Workspace.crashRecoveryVerificationFingerprint(binding: binding)
        )
    }
}
