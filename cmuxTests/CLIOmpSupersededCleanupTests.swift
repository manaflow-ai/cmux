import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CLIOmpSupersededCleanupTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let staleWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let staleSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let liveWorkspaceId = "44444444-4444-4444-4444-444444444444"
    private static let liveSurfaceId = "33333333-3333-3333-3333-333333333333"
    private static let ompPID = Int(getpid())

    @Test
    func boundedCleanupRotatesPersistedFailuresAcrossLaterHooks() throws {
        let context = try Harness.makeContext(name: "omp-cleanup-bound")
        defer { context.cleanup() }

        let priorSessionIds = (0..<6).map { "omp-cleanup-prior-\($0)" }
        let currentSessionId = "omp-cleanup-current"
        let priorUpdatedAt = try Self.writePriorSessions(
            to: context.root.appendingPathComponent("omp-hook-sessions.json"),
            sessionIds: priorSessionIds,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.staleWorkspaceId: [Self.staleSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId),
            resumeClearSucceeds: false
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
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(Self.clearedCheckpoints(in: commands) == Array(priorSessionIds.prefix(4)))
        #expect(!commands.contains { $0.hasPrefix("clear_agent_pid omp.") })

        let savedAfterFailure = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: context.root.appendingPathComponent("omp-hook-sessions.json"))) as? [String: Any]
        )
        let sessions = try #require(savedAfterFailure["sessions"] as? [String: Any])
        #expect(Set(sessions.keys) == Set([currentSessionId]))
        let pending = try #require(savedAfterFailure["pendingSupersededSessionCleanup"] as? [String: Any])
        #expect(Set(pending.keys) == Set(priorSessionIds))
        for (index, sessionId) in priorSessionIds.enumerated() {
            let record = try #require(pending[sessionId] as? [String: Any])
            #expect(record["updatedAt"] as? Double == priorUpdatedAt[sessionId])
            #expect(record["supersededCleanupEnqueuedAt"] as? Double != nil)
            #expect(record["supersededCleanupAttemptCount"] as? Int == (index < 4 ? 1 : 0))
            #expect((record["supersededCleanupLastAttemptAt"] as? Double != nil) == (index < 4))
        }
        #expect(savedAfterFailure["activeSessionsBySurface"] == nil)
        #expect(savedAfterFailure["activeSessionsByWorkspace"] == nil)

        let retryContext = try Harness.makeContext(name: "omp-cleanup-retry")
        defer { retryContext.cleanup() }
        let retryServerHandled = Harness.startDeliveryTargetServer(
            context: retryContext,
            surfacesByWorkspace: [
                Self.staleWorkspaceId: [Self.staleSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var retryEnvironment = Harness.hookEnvironment(context: retryContext)
        retryEnvironment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        retryEnvironment["CMUX_OMP_PID"] = String(Self.ompPID)

        let retryResult = Harness.runHookProcess(
            context: retryContext,
            arguments: [
                "hooks", "omp", "prompt-submit",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: retryEnvironment,
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"retry cleanup"}"#
        )

        #expect(retryServerHandled.wait(timeout: .now() + 5) == .success)
        #expect(!retryResult.timedOut, Comment(rawValue: retryResult.stderr))
        #expect(retryResult.status == 0, Comment(rawValue: retryResult.stderr))
        let retryCommands = retryContext.state.snapshot()
        let secondBatch = [priorSessionIds[4], priorSessionIds[5], priorSessionIds[0], priorSessionIds[1]]
        #expect(Self.clearedCheckpoints(in: retryCommands) == secondBatch)
        #expect(retryCommands.filter { $0.hasPrefix("clear_agent_pid omp.") }.count == secondBatch.count)

        let savedAfterPrompt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: context.root.appendingPathComponent("omp-hook-sessions.json"))) as? [String: Any]
        )
        let pendingAfterPrompt = try #require(savedAfterPrompt["pendingSupersededSessionCleanup"] as? [String: Any])
        #expect(Set(pendingAfterPrompt.keys) == Set([priorSessionIds[2], priorSessionIds[3]]))

        let stopContext = try Harness.makeContext(name: "omp-cleanup-stop")
        defer { stopContext.cleanup() }
        let stopServerHandled = Harness.startDeliveryTargetServer(
            context: stopContext,
            surfacesByWorkspace: [
                Self.staleWorkspaceId: [Self.staleSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var stopEnvironment = Harness.hookEnvironment(context: stopContext)
        stopEnvironment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        stopEnvironment["CMUX_OMP_PID"] = String(Self.ompPID)

        let stopResult = Harness.runHookProcess(
            context: stopContext,
            arguments: [
                "hooks", "omp", "stop",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: stopEnvironment,
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop"}"#
        )

        #expect(stopServerHandled.wait(timeout: .now() + 5) == .success)
        #expect(!stopResult.timedOut, Comment(rawValue: stopResult.stderr))
        #expect(stopResult.status == 0, Comment(rawValue: stopResult.stderr))
        let finalBatch = [priorSessionIds[2], priorSessionIds[3]]
        let stopCommands = stopContext.state.snapshot()
        #expect(Self.clearedCheckpoints(in: stopCommands) == finalBatch)
        #expect(stopCommands.filter { $0.hasPrefix("clear_agent_pid omp.") }.count == finalBatch.count)

        let savedAfterStop = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: context.root.appendingPathComponent("omp-hook-sessions.json"))) as? [String: Any]
        )
        #expect(savedAfterStop["pendingSupersededSessionCleanup"] == nil)
    }

    @Test
    func sameSurfaceReplacementAcknowledgesCleanupWithoutClearingReplacementLifecycle() throws {
        let context = try Harness.makeContext(name: "omp-cleanup-same-surface")
        defer { context.cleanup() }

        let priorSessionId = "omp-cleanup-same-surface-prior"
        let currentSessionId = "omp-cleanup-same-surface-current"
        try Self.writePriorSessions(
            to: context.root.appendingPathComponent("omp-hook-sessions.json"),
            sessionIds: [priorSessionId],
            cwd: context.root.path,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.liveSurfaceId
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId]],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_OMP_PID"] = String(Self.ompPID)

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "omp", "session-start",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: environment,
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(Self.clearedCheckpoints(in: commands) == [priorSessionId])
        #expect(!commands.contains { $0.hasPrefix("clear_agent_pid omp.\(priorSessionId) ") })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.root.appendingPathComponent("omp-hook-sessions.json"))
            ) as? [String: Any]
        )
        #expect(saved["pendingSupersededSessionCleanup"] == nil)
        let sessions = try #require(saved["sessions"] as? [String: Any])
        #expect(Set(sessions.keys) == [currentSessionId])
    }

    @Test
    func checkpointMismatchStillClearsExactSupersededPID() throws {
        let context = try Harness.makeContext(name: "omp-cleanup-reused-surface")
        defer { context.cleanup() }

        let staleSessionId = "omp-cleanup-reused-stale"
        let currentSessionId = "omp-cleanup-reused-current"
        try Self.writePendingSessions(
            to: context.root.appendingPathComponent("omp-hook-sessions.json"),
            sessionIds: [staleSessionId],
            cwd: context.root.path,
            pid: Self.ompPID,
            identity: try #require(Self.processStartIdentity(pid: Self.ompPID))
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.staleWorkspaceId: [Self.staleSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId),
            resumeClearOwnsCheckpoint: false
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_OMP_PID"] = String(Self.ompPID)

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "omp", "session-start",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: environment,
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(Self.clearedCheckpoints(in: commands) == [staleSessionId])
        #expect(commands.contains {
            $0.hasPrefix("clear_agent_pid omp.\(staleSessionId) ")
                && $0.contains("--require-owned-key")
        })
        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.root.appendingPathComponent("omp-hook-sessions.json"))
            ) as? [String: Any]
        )
        #expect(saved["pendingSupersededSessionCleanup"] == nil)
    }

    @Test
    func missingResumeClearAcknowledgementKeepsCleanupPending() throws {
        let context = try Harness.makeContext(name: "omp-cleanup-missing-clear-ack")
        defer { context.cleanup() }

        let staleSessionId = "omp-cleanup-missing-clear-ack-stale"
        let currentSessionId = "omp-cleanup-missing-clear-ack-current"
        try Self.writePendingSessions(
            to: context.root.appendingPathComponent("omp-hook-sessions.json"),
            sessionIds: [staleSessionId],
            cwd: context.root.path,
            pid: Self.ompPID,
            identity: try #require(Self.processStartIdentity(pid: Self.ompPID))
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.staleWorkspaceId: [Self.staleSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId),
            resumeClearOwnsCheckpoint: nil
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_OMP_PID"] = String(Self.ompPID)

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "omp", "session-start",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: environment,
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(Self.clearedCheckpoints(in: commands) == [staleSessionId])
        #expect(!commands.contains { $0.hasPrefix("clear_agent_pid omp.\(staleSessionId) ") })
        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.root.appendingPathComponent("omp-hook-sessions.json"))
            ) as? [String: Any]
        )
        let pending = try #require(saved["pendingSupersededSessionCleanup"] as? [String: Any])
        #expect(pending[staleSessionId] != nil)
    }

    @Test
    func pendingCleanupEvictsExhaustedAttemptsAndCapsDurableQueue() throws {
        let context = try Harness.makeContext(name: "omp-cleanup-cap")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("omp-hook-sessions.json")
        let sessionIds = (0..<144).map { "omp-cleanup-cap-\(String(format: "%03d", $0))" }
        let exhausted = Set(sessionIds.prefix(12))
        let identity = try #require(Self.processStartIdentity(pid: Self.ompPID))
        try Self.writePendingSessions(
            to: storeURL,
            sessionIds: sessionIds,
            cwd: context.root.path,
            pid: Self.ompPID,
            identity: identity,
            attemptCount: { exhausted.contains($0) ? 8 : 0 }
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.staleWorkspaceId: [Self.staleSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId),
            resumeClearSucceeds: false
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_OMP_PID"] = String(Self.ompPID)

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "omp", "session-start",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: environment,
            standardInput: #"{"session_id":"omp-cleanup-cap-owner","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(Self.clearedCheckpoints(in: context.state.snapshot()) == Array(sessionIds[16..<20]))
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        let pending = try #require(saved["pendingSupersededSessionCleanup"] as? [String: Any])
        #expect(pending.count == 128)
        #expect(exhausted.allSatisfy { pending[$0] == nil })
        #expect(sessionIds[12..<16].allSatisfy { pending[$0] == nil })
    }

    @Test
    func pendingCleanupExpiresFromImmutableEnqueueTime() throws {
        let context = try Harness.makeContext(name: "omp-cleanup-expiry")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("omp-hook-sessions.json")
        let identity = try #require(Self.processStartIdentity(pid: Self.ompPID))
        try Self.writePendingSessions(
            to: storeURL,
            sessionIds: ["omp-cleanup-expired"],
            cwd: context.root.path,
            pid: Self.ompPID,
            identity: identity,
            enqueuedAt: Date().addingTimeInterval(-8 * 24 * 60 * 60).timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId]],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_OMP_PID"] = String(Self.ompPID)

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "omp", "session-start",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: environment,
            standardInput: #"{"session_id":"omp-cleanup-expiry-owner","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(Self.clearedCheckpoints(in: context.state.snapshot()).isEmpty)
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        #expect(saved["pendingSupersededSessionCleanup"] == nil)
    }

    @Test
    func laterOMPProcessRecoversCleanupOwnedByDeadGeneration() throws {
        let context = try Harness.makeContext(name: "omp-cleanup-dead")
        defer { context.cleanup() }

        let deadOwner = Process()
        deadOwner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        deadOwner.arguments = ["60"]
        try deadOwner.run()
        defer {
            if deadOwner.isRunning {
                deadOwner.terminate()
                deadOwner.waitUntilExit()
            }
        }
        let deadPID = Int(deadOwner.processIdentifier)
        let deadIdentity = try #require(Self.waitForProcessStartIdentity(pid: deadPID))
        deadOwner.terminate()
        deadOwner.waitUntilExit()
        #expect(Darwin.kill(pid_t(deadPID), 0) != 0)

        let staleSessionId = "omp-cleanup-dead-owner"
        let currentSessionId = "omp-cleanup-live-owner"
        try Self.writePendingSessions(
            to: context.root.appendingPathComponent("omp-hook-sessions.json"),
            sessionIds: [staleSessionId],
            cwd: context.root.path,
            pid: deadPID,
            identity: deadIdentity
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.staleWorkspaceId: [Self.staleSurfaceId],
                Self.liveWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_OMP_PID"] = String(Self.ompPID)

        let result = Harness.runHookProcess(
            context: context,
            arguments: [
                "hooks", "omp", "session-start",
                "--workspace", Self.liveWorkspaceId,
                "--surface", Self.liveSurfaceId,
            ],
            environment: environment,
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(Self.clearedCheckpoints(in: commands) == [staleSessionId])
        #expect(commands.contains { $0.hasPrefix("clear_agent_pid omp.\(staleSessionId) ") })

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: context.root.appendingPathComponent("omp-hook-sessions.json"))) as? [String: Any]
        )
        #expect(saved["pendingSupersededSessionCleanup"] == nil)
    }

    @discardableResult
    private static func writePriorSessions(
        to storeURL: URL,
        sessionIds: [String],
        cwd: String,
        workspaceId: String = Self.staleWorkspaceId,
        surfaceId: String = Self.staleSurfaceId
    ) throws -> [String: TimeInterval] {
        let identity = try #require(Self.processStartIdentity(pid: Self.ompPID))
        let timestamp = Date.now.timeIntervalSince1970
        var sessions: [String: Any] = [:]
        var updatedAtBySessionId: [String: TimeInterval] = [:]
        for (index, sessionId) in sessionIds.enumerated() {
            let updatedAt = timestamp + Double(index)
            sessions[sessionId] = [
                "sessionId": sessionId,
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
                "cwd": cwd,
                "pid": Self.ompPID,
                "pidStartSeconds": identity.seconds,
                "pidStartMicroseconds": identity.microseconds,
                "isRestorable": true,
                "startedAt": updatedAt,
                "updatedAt": updatedAt,
            ]
            updatedAtBySessionId[sessionId] = updatedAt
        }
        let activeSessionId = try #require(sessionIds.last)
        let active = [
            "sessionId": activeSessionId,
            "updatedAt": timestamp,
        ] as [String: Any]
        let store: [String: Any] = [
            "version": 1,
            "activeSessionsBySurface": [Self.staleSurfaceId: active],
            "activeSessionsByWorkspace": [Self.staleWorkspaceId: active],
            "sessions": sessions,
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: storeURL)
        return updatedAtBySessionId
    }

    private static func writePendingSessions(
        to storeURL: URL,
        sessionIds: [String],
        cwd: String,
        pid: Int,
        identity: (seconds: Int64, microseconds: Int64),
        attemptCount: (String) -> Int = { _ in 0 },
        enqueuedAt: TimeInterval? = nil,
        updatedAt: TimeInterval? = nil
    ) throws {
        let timestamp = Date.now.timeIntervalSince1970
        var pending: [String: Any] = [:]
        for (index, sessionId) in sessionIds.enumerated() {
            let recordUpdatedAt = updatedAt ?? (timestamp + Double(index))
            pending[sessionId] = [
                "sessionId": sessionId,
                "workspaceId": Self.staleWorkspaceId,
                "surfaceId": Self.staleSurfaceId,
                "cwd": cwd,
                "pid": pid,
                "pidStartSeconds": identity.seconds,
                "pidStartMicroseconds": identity.microseconds,
                "isRestorable": true,
                "startedAt": timestamp + Double(index),
                "updatedAt": recordUpdatedAt,
                "supersededCleanupEnqueuedAt": enqueuedAt ?? recordUpdatedAt,
                "supersededCleanupAttemptCount": attemptCount(sessionId),
            ]
        }
        let store: [String: Any] = [
            "version": 1,
            "pendingSupersededSessionCleanup": pending,
            "sessions": [:] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: storeURL)
    }

    private static func waitForProcessStartIdentity(pid: Int) -> (seconds: Int64, microseconds: Int64)? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let identity = processStartIdentity(pid: pid) {
                return identity
            }
            usleep(10_000)
        } while Date() < deadline
        return nil
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

    private static func clearedCheckpoints(in commands: [String]) -> [String] {
        commands.compactMap { command -> String? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear",
                  let params = payload["params"] as? [String: Any] else {
                return nil
            }
            return params["checkpoint_id"] as? String
        }
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}
