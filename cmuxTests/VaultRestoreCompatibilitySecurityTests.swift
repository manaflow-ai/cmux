import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxCore
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Compatibility fallbacks must quote identifiers before a rendered command
/// is typed into a terminal, even when a structured restore snapshot is absent.
@MainActor
@Suite(.serialized)
struct VaultRestoreCompatibilitySecurityTests {
    @Test("Open inherits the selected local directory when splitting is rejected")
    func openFallbackPreservesLocalDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TabManager(initialWorkingDirectory: directory.path, autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let originalDelegate = workspace.bonsplitController.delegate
        let rejectingDelegate = VaultOpenRejectingSplitDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate
        defer { workspace.bonsplitController.delegate = originalDelegate }
        let entry = SessionEntry(
            id: "claude:local-fallback",
            agent: .claude,
            sessionId: "local-fallback",
            title: "Local fallback",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_109),
            fileURL: nil,
            specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
        )

        #expect(SessionEntryResumeCoordinator().open(entry, tabManager: manager))
        #expect(manager.tabs.count == 2)
        let openedWorkspace = try #require(manager.selectedWorkspace)
        #expect(openedWorkspace !== workspace)
        #expect(openedWorkspace.currentDirectory == directory.path)
        let panelID = try #require(openedWorkspace.focusedPanelId)
        #expect(openedWorkspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId == entry.sessionId)
    }

    @Test("Quoted registration values remain structured through the app adapter")
    func quotedRegistrationValueRemainsAvailable() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "custom-agent",
            name: "Custom Agent",
            detect: CmuxVaultAgentDetectRule(processName: "custom-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --label ' padded ' --session {{sessionId}}",
            cwd: .preserve
        )
        let entry = SessionEntry(
            id: "custom-agent:quoted-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "quoted-session",
            title: "Quoted argument",
            cwd: "/tmp/project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_108),
            fileURL: nil,
            specifics: .registered(registration)
        )
        let launch = try #require(entry.resumeLaunch)
        let snapshot = try #require(launch.startupRestoreAgent)

        #expect(launch.strategy == .restoreVerb)
        #expect(launch.initialInput == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore custom-agent quoted-session\n")
        #expect(snapshot.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: snapshot.workingDirectory,
            observedPermissionMode: snapshot.permissionMode
        ) == ["custom-agent", "--label", " padded ", "--session", "quoted-session"])
    }

    @Test("Legacy Codex approval metadata preserves the upstream on-request migration")
    func legacyCodexApprovalPolicyMigratesExplicitly() throws {
        let sessionID = "669b4d0f-a991-4a51-aeb4-4b78a611c803"
        let entry = SessionEntry(
            id: "codex:\(sessionID)",
            agent: .codex,
            sessionId: sessionID,
            title: "Legacy Codex approval",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_110),
            fileURL: nil,
            specifics: .codex(
                model: nil,
                approvalPolicy: "on-failure",
                sandboxMode: "workspace-write",
                effort: nil
            )
        )
        let launch = try #require(entry.resumeLaunch)
        let snapshot = try #require(launch.startupRestoreAgent)

        #expect(launch.strategy == .restoreVerb)
        #expect(snapshot.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: snapshot.workingDirectory,
            observedPermissionMode: snapshot.permissionMode
        ) == [
            "codex", "resume", sessionID,
            "-c", "check_for_update_on_startup=false",
            "-a", "on-request", "-s", "workspace-write"
        ])
    }

    @Test(arguments: ["claude", "codex"])
    func invalidBuiltInSessionIDsAreQuotedInCompatibilityInput(_ rawKind: String) throws {
        let unsafeSessionID = "bad;echo-pwned"
        let specifics: AgentSpecifics = rawKind == "claude"
            ? .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
            : .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
        let entry = SessionEntry(
            id: "\(rawKind):\(unsafeSessionID)",
            agent: rawKind == "claude" ? .claude : .codex,
            sessionId: unsafeSessionID,
            title: "Unsafe \(rawKind) session",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_107),
            fileURL: nil,
            specifics: specifics
        )
        let launch = try #require(entry.resumeLaunch)

        #expect(launch.strategy == .legacyCommand)
        #expect(launch.legacyFallbackReason == .missingStructuredSnapshot)
        #expect(!launch.initialInput.contains("--resume \(unsafeSessionID)"))
        #expect(!launch.initialInput.contains("resume \(unsafeSessionID)"))
    }
}

@MainActor
private final class VaultOpenRejectingSplitDelegate: BonsplitDelegate {
    func splitTabBar(
        _ controller: BonsplitController,
        shouldSplitPane pane: PaneID,
        orientation: SplitOrientation
    ) -> Bool {
        false
    }
}
