import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CodexResumeForkTrackingTests {
    @Test
    func pickerResumedCodexIsForkableBeforeItsFirstPrompt() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-picker-fork-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let sessionId = "019f53cf-4d3d-7ad1-8516-a6f236a78a41"
        let sessionsDirectory = root
            .appendingPathComponent(".codex/sessions/2026/07/11", isDirectory: true)
        let decoyRollout = sessionsDirectory
            .appendingPathComponent(
                "rollout-2026-07-11T11-00-00-019f53cf-0000-7000-8000-000000000000.jsonl",
                isDirectory: false
            )
        let rollout = sessionsDirectory
            .appendingPathComponent("rollout-2026-07-11T12-00-00-\(sessionId).jsonl", isDirectory: false)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try Data().write(to: decoyRollout)
        let decoyHandle = try FileHandle(forReadingFrom: decoyRollout)
        defer { try? decoyHandle.close() }
        try """
        {"type":"session_meta","payload":{"id":"\(sessionId)","source":"cli","thread_source":"user"}}

        """.write(to: rollout, atomically: true, encoding: .utf8)
        let rolloutHandle = try FileHandle(forWritingTo: rollout)
        defer { try? rolloutHandle.close() }

        let workspaceId = UUID()
        let panelId = UUID()
        let agentPID = Int(Darwin.getpid())
        let openRolloutPath = try #require(AgentChatSessionRegistry.openCodexRolloutPath(pid: agentPID))
        #expect(
            URL(fileURLWithPath: openRolloutPath).resolvingSymlinksInPath().path
                == rollout.resolvingSymlinksInPath().path
        )
        let identity = try #require(AgentPIDProcessIdentity(pid: pid_t(agentPID)))
        let executable = "/opt/custom/codex-dev"
        let liveExecutable = "/opt/custom/vendor/aarch64-apple-darwin/bin/codex"
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: agentPID,
                    parentPID: 1,
                    name: "codex",
                    path: liveExecutable,
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: agentPID,
                    terminalProcessGroupID: agentPID,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 71),
            includesProcessDetails: true
        )
        let resumeLaunches: [(arguments: [String], forbiddenForkToken: String?)] = [
            ([executable, "resume"], nil),
            ([executable, "resume", "--last", "--model", "gpt-5.4"], "--last"),
            ([executable, "resume", "named-session", "--model", "gpt-5.4"], "named-session"),
        ]
        for resumeLaunch in resumeLaunches {
            let encodedLaunchArguments = Data(
                (resumeLaunch.arguments.joined(separator: "\0") + "\0").utf8
            ).base64EncodedString()
            let processArguments = CmuxTopProcessArguments(
                arguments: [liveExecutable] + Array(resumeLaunch.arguments.dropFirst()),
                environment: [
                    "CMUX_AGENT_LAUNCH_KIND": "codex",
                    "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
                    "CMUX_AGENT_LAUNCH_ARGV_B64": encodedLaunchArguments,
                    "CMUX_AGENT_LAUNCH_CWD": cwd.path,
                    "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                    "CMUX_SURFACE_ID": panelId.uuidString,
                    "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
                    "PWD": cwd.path,
                ]
            )

            let result = SharedLiveAgentIndexLoader(
                homeDirectory: root.path,
                fileManager: fm,
                registry: CmuxVaultAgentRegistry(registrations: []),
                processSnapshotProvider: { processSnapshot },
                capturedAtProvider: { 71 },
                processArgumentsProvider: { $0 == agentPID ? processArguments : nil },
                processIdentityProvider: { $0 == agentPID ? identity : nil }
            ).loadResultSynchronously()

            let snapshot = try #require(result.index.snapshot(workspaceId: workspaceId, panelId: panelId))
            #expect(snapshot.kind == .codex)
            #expect(snapshot.sessionId == sessionId)
            #expect(result.index.agentProcessIDs(workspaceId: workspaceId, panelId: panelId) == Set([agentPID]))
            #expect(result.forkValidatedPanels.contains(.init(workspaceId: workspaceId, panelId: panelId)))
            let forkCommand = try #require(snapshot.forkCommand)
            #expect(forkCommand.contains(AgentResumeArgv.codexWrapperShellExecutableToken), "\(forkCommand)")
            #expect(forkCommand.contains("CMUX_CUSTOM_CODEX_PATH=\(executable)"), "\(forkCommand)")
            #expect(forkCommand.contains(sessionId), "\(forkCommand)")
            if let forbiddenForkToken = resumeLaunch.forbiddenForkToken {
                #expect(!forkCommand.contains(forbiddenForkToken), "\(forkCommand)")
            }
        }

        let staleExecutable = "/opt/stale/codex"
        // A bare parent capture has no argv tail to compare. It must not be trusted
        // by a nested Codex process whose live executable is different.
        let staleArguments = [staleExecutable]
        let staleEncodedArguments = Data(
            (staleArguments.joined(separator: "\0") + "\0").utf8
        ).base64EncodedString()
        let inheritedCaptureProcess = CmuxTopProcessArguments(
            arguments: [liveExecutable, "resume", "--last"],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "codex",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": staleExecutable,
                "CMUX_AGENT_LAUNCH_ARGV_B64": staleEncodedArguments,
                "CMUX_AGENT_LAUNCH_CWD": "/tmp/stale-parent-cwd",
                "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                "CMUX_SURFACE_ID": panelId.uuidString,
                "PWD": cwd.path,
            ]
        )
        let inheritedCaptureResult = SharedLiveAgentIndexLoader(
            homeDirectory: root.path,
            fileManager: fm,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { 72 },
            processArgumentsProvider: { $0 == agentPID ? inheritedCaptureProcess : nil },
            processIdentityProvider: { $0 == agentPID ? identity : nil }
        ).loadResultSynchronously()
        let inheritedCaptureSnapshot = try #require(
            inheritedCaptureResult.index.snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        #expect(inheritedCaptureSnapshot.workingDirectory == cwd.path)
        let inheritedCaptureFork = try #require(inheritedCaptureSnapshot.forkCommand)
        #expect(inheritedCaptureFork.contains("CMUX_CUSTOM_CODEX_PATH=\(liveExecutable)"), "\(inheritedCaptureFork)")
        #expect(!inheritedCaptureFork.contains(staleExecutable), "\(inheritedCaptureFork)")
        #expect(!inheritedCaptureFork.contains("stale-session-name"), "\(inheritedCaptureFork)")

        let liveCustomExecutable = "/opt/custom/codex-dev"
        let liveCustomProcessSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: agentPID,
                    parentPID: 1,
                    name: "codex-dev",
                    path: liveCustomExecutable,
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: agentPID,
                    terminalProcessGroupID: agentPID,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 73),
            includesProcessDetails: true
        )
        let malformedCaptureProcess = CmuxTopProcessArguments(
            arguments: [liveCustomExecutable, "resume", "--last"],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "codex",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": liveCustomExecutable,
                "CMUX_AGENT_LAUNCH_ARGV_B64": "%%%",
                "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                "CMUX_SURFACE_ID": panelId.uuidString,
                "PWD": cwd.path,
            ]
        )
        let malformedCaptureResult = SharedLiveAgentIndexLoader(
            homeDirectory: root.path,
            fileManager: fm,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { liveCustomProcessSnapshot },
            capturedAtProvider: { 73 },
            processArgumentsProvider: { $0 == agentPID ? malformedCaptureProcess : nil },
            processIdentityProvider: { $0 == agentPID ? identity : nil }
        ).loadResultSynchronously()
        let malformedCaptureSnapshot = try #require(
            malformedCaptureResult.index.snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        let malformedCaptureFork = try #require(malformedCaptureSnapshot.forkCommand)
        #expect(
            malformedCaptureFork.contains("CMUX_CUSTOM_CODEX_PATH=\(liveCustomExecutable)"),
            "\(malformedCaptureFork)"
        )

        let siblingRollout = sessionsDirectory
            .appendingPathComponent(
                "rollout-2026-07-11T13-00-00-019f53cf-1111-7111-8111-111111111111.jsonl",
                isDirectory: false
            )
        try """
        {"type":"session_meta","payload":{"id":"019f53cf-1111-7111-8111-111111111111","parent_thread_id":"\(sessionId)","thread_source":"subagent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(sessionId)"}}}}}

        """.write(to: siblingRollout, atomically: true, encoding: .utf8)
        let siblingHandle = try FileHandle(forWritingTo: siblingRollout)
        defer { try? siblingHandle.close() }
        #expect(
            AgentChatSessionRegistry.openCodexRolloutPath(pid: agentPID) == openRolloutPath,
            "A writable subagent rollout must not hide the resumed root conversation."
        )

        let ambiguousRoot = sessionsDirectory
            .appendingPathComponent(
                "rollout-2026-07-11T14-00-00-019f53cf-2222-7222-8222-222222222222.jsonl",
                isDirectory: false
            )
        try """
        {"type":"session_meta","payload":{"id":"019f53cf-2222-7222-8222-222222222222","source":"cli","thread_source":"user"}}

        """.write(to: ambiguousRoot, atomically: true, encoding: .utf8)
        let ambiguousRootHandle = try FileHandle(forWritingTo: ambiguousRoot)
        defer { try? ambiguousRootHandle.close() }
        #expect(
            AgentChatSessionRegistry.openCodexRolloutPath(pid: agentPID) == nil,
            "Two writable root conversations are ambiguous and must wait for hook identity."
        )
    }

}
