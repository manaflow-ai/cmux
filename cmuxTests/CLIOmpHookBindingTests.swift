import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CLIOmpHookBindingTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let leakedWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let liveWorkspaceId = "44444444-4444-4444-4444-444444444444"
    private static let leakedSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let liveSurfaceId = "33333333-3333-3333-3333-333333333333"
    private static let ompPID = Int(getpid())

    @Test
    func controllingTTYPolicyDoesNotCorroborateWithInheritedEnvironment() {
        let tty = AgentDeliveryTargetCandidate(workspaceId: UUID(), surfaceId: UUID())
        let inherited = AgentDeliveryTargetCandidate(workspaceId: UUID(), surfaceId: UUID())

        #expect(
            agentDeliveryTargetCombining(
                ttyTarget: tty,
                envTarget: inherited,
                resolution: .controllingTTY
            ) == tty
        )
        #expect(
            agentDeliveryTargetCombining(
                ttyTarget: nil,
                envTarget: inherited,
                resolution: .controllingTTY
            ) == nil
        )
    }

    @Test
    func piSessionStartPreservesPathRequiredByForkVersionProbe() async throws {
        let context = try Harness.makeContext(name: "pi-fork-path")
        defer { context.cleanup() }

        let sessionId = "pi-fork-path-session"
        let stateDirectory = context.root.appendingPathComponent(".cmuxterm", isDirectory: true)
        let binDirectory = context.root.appendingPathComponent("custom-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let runtimeName = "cmux-pi-fork-test-runtime"
        let runtime = binDirectory.appendingPathComponent(runtimeName, isDirectory: false)
        try "#!/bin/sh\nprintf '0.83.0\\n'\n"
            .write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)

        let pi = binDirectory.appendingPathComponent("pi", isDirectory: false)
        try "#!/usr/bin/env \(runtimeName)\n"
            .write(to: pi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId]],
            pidTarget: nil
        )
        let launchPath = "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"
        var environment = Harness.hookEnvironment(context: context)
        environment["PATH"] = launchPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDirectory.path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "pi"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = pi.path
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = Self.base64NULSeparated([pi.path])
        environment["CMUX_AGENT_LAUNCH_CWD"] = context.root.path

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "pi", "session-start",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let workspaceId = try #require(UUID(uuidString: Self.liveWorkspaceId))
        let surfaceId = try #require(UUID(uuidString: Self.liveSurfaceId))
        let snapshot = try #require(
            RestorableAgentSessionIndex.load(
                homeDirectory: context.root.path,
                fileManager: .default
            )
            .snapshot(
                workspaceId: workspaceId,
                panelId: surfaceId
            )
        )
        #expect(snapshot.launchCommand?.environment?["PATH"] == launchPath)
        #expect(
            await AgentForkSupport.supportsFork(snapshot: snapshot),
            "Fork availability must probe Pi with the PATH captured by its session-start hook."
        )
    }

    @Test
    func resumedSessionUsesLivePIDTTYTargetAndSupersedesPriorProcessClaim() throws {
        let context = try Harness.makeContext(name: "omp-live-pid")
        defer { context.cleanup() }

        let previousSessionId = "omp-session-before-resume"
        let resumedSessionId = "omp-session-after-resume"
        let storeURL = context.root.appendingPathComponent("omp-hook-sessions.json")
        try Self.writePriorSession(
            to: storeURL,
            sessionId: previousSessionId,
            workspaceId: Self.leakedWorkspaceId,
            surfaceId: Self.leakedSurfaceId,
            cwd: context.root.path
        )

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.leakedWorkspaceId: [Self.leakedSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_WORKSPACE_ID"] = Self.leakedWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.leakedSurfaceId
        environment["CMUX_OMP_PID"] = String(Self.ompPID)
        environment["CMUX_AGENT_LAUNCH_KIND"] = "omp"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/omp"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = Self.base64NULSeparated(["/usr/local/bin/omp"])
        environment["CMUX_AGENT_LAUNCH_CWD"] = context.root.path

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "omp", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(resumedSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")

        let commands = context.state.snapshot()
        let requests = commands.compactMap(Self.jsonObject)
        let pidProbe = try #require(requests.first {
            $0["method"] as? String == "agent.resolve_delivery_target"
                && ($0["params"] as? [String: Any])?["pid"] as? Int == Self.ompPID
        })
        #expect(
            (pidProbe["params"] as? [String: Any])?["pid_resolution"] as? String == "controlling_tty",
            "Hook binding must ask the app for kernel controlling-TTY evidence, not env-attributed process placement"
        )

        let resumeRequest = try #require(requests.last {
            $0["method"] as? String == "surface.resume.set"
        })
        let resumeParams = try #require(resumeRequest["params"] as? [String: Any])
        #expect(resumeParams["workspace_id"] as? String == Self.liveWorkspaceId)
        #expect(resumeParams["surface_id"] as? String == Self.liveSurfaceId)
        let clearRequest = try #require(requests.first {
            $0["method"] as? String == "surface.resume.clear"
        })
        let clearParams = try #require(clearRequest["params"] as? [String: Any])
        #expect(clearParams["surface_id"] as? String == Self.leakedSurfaceId)
        #expect(clearParams["checkpoint_id"] as? String == previousSessionId)
        let resumeIndex = try #require(commands.firstIndex {
            Self.jsonObject($0)?["method"] as? String == "surface.resume.set"
        })
        let pidIndex = try #require(commands.firstIndex {
            $0.hasPrefix("set_agent_pid omp.\(resumedSessionId) ")
        })
        let lifecycleIndex = try #require(commands.firstIndex {
            $0.hasPrefix("agent_journal_append ") && $0.contains("\"agent_key\":\"omp\"")
        })
        let clearIndex = try #require(commands.firstIndex {
            Self.jsonObject($0)?["method"] as? String == "surface.resume.clear"
        })
        #expect(resumeIndex < clearIndex)
        #expect(pidIndex < clearIndex)
        #expect(lifecycleIndex < clearIndex)

        let store = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        let sessions = try #require(store["sessions"] as? [String: Any])
        #expect(sessions[previousSessionId] == nil, "A resumed session ID must supersede the prior claim from the same live process")
        let resumed = try #require(sessions[resumedSessionId] as? [String: Any])
        #expect(resumed["workspaceId"] as? String == Self.liveWorkspaceId)
        #expect(resumed["surfaceId"] as? String == Self.liveSurfaceId)
        #expect(resumed["pid"] as? Int == Self.ompPID)
        #expect(store["pendingSupersededSessionCleanup"] == nil)
        #expect(store["activeSessionsBySurface"] == nil)
        #expect(store["activeSessionsByWorkspace"] == nil)
    }

    @Test
    func rejectedLivePIDBindingDoesNotPersistInheritedTarget() throws {
        let context = try Harness.makeContext(name: "omp-rejected-pid")
        defer { context.cleanup() }
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.leakedWorkspaceId: [Self.leakedSurfaceId]],
            pidTarget: nil
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_WORKSPACE_ID"] = Self.leakedWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.leakedSurfaceId
        environment["CMUX_OMP_PID"] = String(Self.ompPID)

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "omp", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"omp-rejected-session","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requests = context.state.snapshot().compactMap(Self.jsonObject)
        #expect(requests.contains { $0["method"] as? String == "agent.resolve_delivery_target" })
        #expect(!requests.contains { $0["method"] as? String == "surface.resume.set" })
    }

    @Test
    func unacknowledgedPIDPolicyDoesNotTrustOlderAppResponse() throws {
        let context = try Harness.makeContext(name: "omp-old-app")
        defer { context.cleanup() }
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.leakedWorkspaceId: [Self.leakedSurfaceId]],
            pidTarget: (workspaceId: Self.leakedWorkspaceId, surfaceId: Self.leakedSurfaceId),
            acknowledgesPIDResolution: false
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_WORKSPACE_ID"] = Self.leakedWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.leakedSurfaceId
        environment["CMUX_OMP_PID"] = String(Self.ompPID)

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "omp", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"omp-old-app-session","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requests = context.state.snapshot().compactMap(Self.jsonObject)
        #expect(requests.contains { $0["method"] as? String == "agent.resolve_delivery_target" })
        #expect(!requests.contains { $0["method"] as? String == "surface.resume.set" })
    }

    @Test
    func explicitRoutingDoesNotProbeProcessBinding() throws {
        let context = try Harness.makeContext(name: "omp-explicit-route")
        defer { context.cleanup() }
        let sessionId = "omp-explicit-session"
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId]],
            pidTarget: (workspaceId: Self.leakedWorkspaceId, surfaceId: Self.leakedSurfaceId)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_OMP_PID"] = String(Self.ompPID)
        environment["CMUX_AGENT_LAUNCH_KIND"] = "omp"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/omp"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = Self.base64NULSeparated(["/usr/local/bin/omp"])
        environment["CMUX_AGENT_LAUNCH_CWD"] = context.root.path

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "omp", "session-start",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requests = context.state.snapshot().compactMap(Self.jsonObject)
        #expect(!requests.contains {
            $0["method"] as? String == "agent.resolve_delivery_target"
        })
        let resume = try #require(requests.last {
            $0["method"] as? String == "surface.resume.set"
        })
        let params = try #require(resume["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.liveWorkspaceId)
        #expect(params["surface_id"] as? String == Self.liveSurfaceId)
    }

    @Test
    func ambientTTYCannotMoveGenericHookAcrossClaimedWorkspace() throws {
        let context = try Harness.makeContext(name: "generic-tty-boundary")
        defer { context.cleanup() }
        let sessionId = "codex-ambient-tty-session"
        let staleTTY = "ttys-ambient-stale"
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.liveWorkspaceId: [Self.liveSurfaceId],
                Self.leakedWorkspaceId: [Self.leakedSurfaceId],
            ],
            pidTarget: nil,
            ttyRows: [
                (tty: staleTTY, workspaceId: Self.leakedWorkspaceId, surfaceId: Self.leakedSurfaceId)
            ]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = staleTTY
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = Self.base64NULSeparated(["/usr/local/bin/codex"])
        environment["CMUX_AGENT_LAUNCH_CWD"] = context.root.path

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "codex", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let resumeBindings = Harness.resumeBindingParams(in: context)
        #expect(resumeBindings.count == 1)
        let resume = try #require(resumeBindings.first)
        #expect(resume["workspace_id"] as? String == Self.liveWorkspaceId)
        #expect(resume["surface_id"] as? String == Self.liveSurfaceId)
    }

    @Test
    func numericPIDWithoutGenerationDoesNotSupersedePriorSession() throws {
        let context = try Harness.makeContext(name: "omp-pid-generation")
        defer { context.cleanup() }
        let priorSessionId = "generation-unknown"
        let currentSessionId = "generation-known"
        let storeURL = context.root.appendingPathComponent("omp-hook-sessions.json")
        try Self.writePriorSession(
            to: storeURL,
            sessionId: priorSessionId,
            workspaceId: Self.leakedWorkspaceId,
            surfaceId: Self.leakedSurfaceId,
            cwd: context.root.path,
            includeProcessGeneration: false
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.leakedWorkspaceId: [Self.leakedSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_WORKSPACE_ID"] = Self.leakedWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.leakedSurfaceId
        environment["CMUX_OMP_PID"] = String(Self.ompPID)
        environment["CMUX_AGENT_LAUNCH_KIND"] = "omp"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/omp"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = Self.base64NULSeparated(["/usr/local/bin/omp"])
        environment["CMUX_AGENT_LAUNCH_CWD"] = context.root.path

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "omp", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        #expect(sessions[priorSessionId] != nil)
        #expect(sessions[currentSessionId] != nil)
    }

    private static func writePriorSession(
        to storeURL: URL,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String,
        includeProcessGeneration: Bool = true
    ) throws {
        let timestamp = Date.now.timeIntervalSince1970
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "cwd": cwd,
            "pid": ompPID,
            "isRestorable": true,
            "startedAt": timestamp,
            "updatedAt": timestamp,
        ]
        if includeProcessGeneration {
            let identity = try #require(Self.processStartIdentity(pid: Self.ompPID))
            record["pidStartSeconds"] = identity.seconds
            record["pidStartMicroseconds"] = identity.microseconds
        }
        let store: [String: Any] = [
            "version": 1,
            "activeSessionsBySurface": [:],
            "activeSessionsByWorkspace": [:],
            "sessions": [sessionId: record],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: storeURL)
    }

    private static func processStartIdentity(pid: Int) -> (seconds: Int64, microseconds: Int64)? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return (Int64(info.pbi_start_tvsec), Int64(info.pbi_start_tvusec))
    }

    private static func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}
