import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Hibernation must only take down an agent whose wake can relaunch it the way
/// the user started it. A Claude pane without a captured argv would wake as a
/// bare `claude --resume`, skipping wrappers such as `sr claude proxy` and
/// ending at "Not logged in".
@MainActor
@Suite(.serialized)
struct AgentHibernationLaunchFidelityTests {
    private let cwd = "/tmp/cmux-hibernation-launch-fidelity"

    @Test
    func claudeWithCapturedArgvIsEligible() throws {
        let launch = AgentLaunchCommandSnapshot(
            launcher: "claude",
            executablePath: "/usr/local/bin/claude",
            arguments: ["/usr/local/bin/claude", "--model", "opus"],
            workingDirectory: cwd
        )
        #expect(try gate(kind: .claude, launch: launch) != nil)
    }

    @Test
    func claudeWithoutLaunchCaptureIsNotHibernated() throws {
        #expect(try gate(kind: .claude, launch: nil) == nil)
    }

    @Test
    func claudeWithRejectedLaunchCaptureIsNotHibernated() throws {
        let launch = AgentLaunchCommandSnapshot(
            rejectedOn: .argvDecodeFailed,
            launcher: "claude",
            executablePath: "/usr/local/bin/claude",
            workingDirectory: cwd
        )
        #expect(try gate(kind: .claude, launch: launch) == nil)
    }

    @Test
    func claudeWithEnvironmentOnlyCaptureIsNotHibernated() throws {
        let launch = AgentLaunchCommandSnapshot(
            launcher: "claude",
            executablePath: "/usr/local/bin/claude",
            arguments: [],
            workingDirectory: cwd,
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-profile"],
            source: "environment"
        )
        #expect(try gate(kind: .claude, launch: launch) == nil)
    }

    @Test
    func provenSubrouterLaunchWithoutArgvIsEligible() throws {
        let marker = "sr claude proxy --resume"
        let launch = AgentLaunchCommandSnapshot(
            launcher: "claude",
            executablePath: "/usr/local/bin/claude",
            arguments: [],
            workingDirectory: cwd,
            environment: [
                "SUBROUTER_CLAUDE_RESUME_COMMAND": marker,
                "CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND": marker,
            ],
            source: "environment"
        )
        #expect(try gate(kind: .claude, launch: launch) != nil)
    }

    @Test
    func agentWhoseDeclaredLauncherNoLongerResolvesIsNotHibernated() throws {
        let launch = AgentLaunchCommandSnapshot(
            launcher: "claude",
            externalLauncher: "launcher-that-is-not-declared-\(UUID().uuidString)",
            executablePath: "/usr/local/bin/claude",
            arguments: ["/usr/local/bin/claude"],
            workingDirectory: cwd
        )
        #expect(try gate(kind: .claude, launch: launch) == nil)
    }

    @Test
    func codexWithoutLaunchCaptureKeepsItsBuiltInResume() throws {
        #expect(try gate(kind: .codex, launch: nil) != nil)
    }

    private func gate(
        kind: RestorableAgentKind,
        launch: AgentLaunchCommandSnapshot?
    ) throws -> SessionRestorableAgentSnapshot? {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-launch-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.restoredAgentLifecycle.setSnapshot(
            SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: "launch-fidelity-session",
                workingDirectory: cwd,
                launchCommand: launch
            ),
            panelId: panelId
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:]
        )
        return workspace.restorableAgentForHibernation(panelId: panelId, index: index)
    }
}
