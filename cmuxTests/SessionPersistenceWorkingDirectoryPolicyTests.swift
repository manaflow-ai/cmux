import CMUXAgentLaunch
import Foundation
import CmuxCore
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session persistence working-directory policy")
struct SessionPersistenceWorkingDirectoryPolicyTests {
    @Test(arguments: ["codex", "claude"], [nil, "/srv/trusted"] as [String?])
    func exactBindingPolicySurvivesGenericRetargeting(kind: String, trustedDirectory: String?) {
        let binding = SurfaceResumeBindingSnapshot(
            kind: kind,
            command: "\(kind) --resume retained-session",
            cwd: trustedDirectory,
            checkpointId: "retained-session",
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                arguments: [kind],
                workingDirectory: trustedDirectory
            ),
            restoreWorkingDirectorySelection: .exact(trustedDirectory)
        )

        let retargeted = binding.retargetingWorkingDirectory("/Users/local/fallback")

        #expect(retargeted == binding)
        #expect(retargeted.inlineStartupInput?.contains("/Users/local/fallback") != true)
    }

    @Test(arguments: [
        nil,
        AgentRestoreWorkingDirectorySelection.recordedFallback(preferred: "/tmp/original"),
    ] as [AgentRestoreWorkingDirectorySelection?])
    func genericRetargetingDoesNotCreateRemoteProvenance(
        selection: AgentRestoreWorkingDirectorySelection?
    ) {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume retained-session",
            cwd: "/tmp/original",
            checkpointId: "retained-session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: selection
        )

        let retargeted = binding.retargetingWorkingDirectory("/tmp/destination")

        #expect(retargeted.cwd == "/tmp/destination")
        #expect(retargeted.restoreWorkingDirectorySelection == selection)
    }

    @Test(arguments: [
        AgentRestoreWorkingDirectorySelection.exact(nil),
        .exact("/srv/trusted"),
        .unavailable,
    ], [false, true])
    func preparedForkArgumentsHonorRetainedPolicy(
        selection: AgentRestoreWorkingDirectorySelection,
        usesLaunchOverride: Bool
    ) throws {
        let launch = AgentLaunchCommandSnapshot(
            arguments: ["codex", "-C", "/Users/local/captured", "--model", "fast"],
            workingDirectory: "/Users/local/snapshot"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "retained-session",
            workingDirectory: "/Users/local/snapshot",
            launchCommand: launch,
            restoreWorkingDirectorySelection: selection
        )

        let arguments = snapshot.preparedForkArguments(
            launchCommand: usesLaunchOverride ? launch : nil,
            workingDirectory: "/Users/local/caller"
        )

        guard selection.permitsResume else {
            #expect(arguments == nil)
            return
        }
        let prepared = try #require(arguments)
        #expect(prepared.contains("retained-session"))
        #expect(prepared.contains("fast"))
        #expect(!prepared.contains("-C"))
        #expect(!prepared.contains(where: { $0.contains("/Users/local/") }))
    }

    @Test("Drops duplicate Kimi working-directory options")
    func dropsDuplicateKimiWorkingDirectoryOption() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && kimi --resume session --work-dir '/tmp/project' --model kimi-k2",
            cwd: "/tmp/project",
            source: "agent-hook",
            updatedAt: 1
        )

        #expect(
            binding.command == TerminalStartupWorkingDirectoryPrefix.prefix(
                "kimi --resume session --model kimi-k2",
                workingDirectory: "/tmp/project"
            )
        )
    }

    @Test("Drops Kimi and Qoder short working-directory options")
    func dropsKimiAndQoderShortWorkingDirectoryOptions() {
        let workingDirectory = "/tmp/project"
        let cases = [
            (kind: "kimi", option: "-w '\(workingDirectory)'"),
            (kind: "kimi", option: "-w\(workingDirectory)"),
            (kind: "qoder", option: "-w '\(workingDirectory)'"),
            (kind: "qoder", option: "-w\(workingDirectory)"),
        ]

        for item in cases {
            let binding = SurfaceResumeBindingSnapshot(
                kind: item.kind,
                command: "cd '\(workingDirectory)' && \(item.kind) --resume session \(item.option) --model fast",
                cwd: workingDirectory,
                source: "agent-hook",
                updatedAt: 1
            )

            #expect(
                binding.command == TerminalStartupWorkingDirectoryPrefix.prefix(
                    "\(item.kind) --resume session --model fast",
                    workingDirectory: workingDirectory
                ),
                Comment(rawValue: "\(item.kind) \(item.option)")
            )
        }
    }

    @Test("Drops Kimi and Qoder short options after cwd retargeting")
    func retargetingDropsKimiAndQoderShortWorkingDirectoryOptions() {
        let workingDirectory = "/tmp/project"
        let cases = [
            (kind: "kimi", option: "-w '\(workingDirectory)'"),
            (kind: "kimi", option: "-w\(workingDirectory)"),
            (kind: "qoder", option: "-w '\(workingDirectory)'"),
            (kind: "qoder", option: "-w\(workingDirectory)"),
        ]

        for item in cases {
            let binding = SurfaceResumeBindingSnapshot(
                kind: item.kind,
                command: "\(item.kind) --resume session \(item.option) --model fast",
                cwd: nil,
                source: "agent-hook",
                updatedAt: 1
            )
            let retargeted = binding.retargetingWorkingDirectory(workingDirectory)

            #expect(
                retargeted.command == TerminalStartupWorkingDirectoryPrefix.prefix(
                    "\(item.kind) --resume session --model fast",
                    workingDirectory: workingDirectory
                ),
                Comment(rawValue: "\(item.kind) \(item.option)")
            )
        }
    }

    @Test("Preserves Claude Teams worktree options")
    func preservesClaudeTeamsWorktreeOption() {
        let workingDirectory = "/tmp/team-worktree"
        let command = "cmux claude-teams --resume team-session -w '\(workingDirectory)' --model sonnet"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "cd '\(workingDirectory)' && \(command)",
            cwd: workingDirectory,
            source: "agent-hook",
            updatedAt: 1
        )

        #expect(
            binding.command == TerminalStartupWorkingDirectoryPrefix.optionalChangeDirectoryPrefix(
                for: workingDirectory
            ).map { $0 + command }
        )
    }
}
