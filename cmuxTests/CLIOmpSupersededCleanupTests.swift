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
    func boundedCleanupDemotesEverySupersededClaimAndPersistsFailures() throws {
        let context = try Harness.makeContext(name: "omp-cleanup-bound")
        defer { context.cleanup() }

        let priorSessionIds = (0..<6).map { "omp-cleanup-prior-\($0)" }
        let currentSessionId = "omp-cleanup-current"
        try Self.writePriorSessions(
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
            arguments: ["hooks", "omp", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(currentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        let clearedCheckpoints = commands.compactMap { command -> String? in
            guard let payload = Self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear",
                  let params = payload["params"] as? [String: Any] else {
                return nil
            }
            return params["checkpoint_id"] as? String
        }
        #expect(clearedCheckpoints == Array(priorSessionIds.prefix(4)))
        #expect(!commands.contains { $0.hasPrefix("clear_agent_pid omp.") })

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: context.root.appendingPathComponent("omp-hook-sessions.json"))) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        #expect(Set(sessions.keys) == Set([currentSessionId]))
        let pending = try #require(saved["pendingSupersededSessionCleanup"] as? [String: Any])
        #expect(Set(pending.keys) == Set(priorSessionIds))
        #expect(saved["activeSessionsBySurface"] == nil)
        #expect(saved["activeSessionsByWorkspace"] == nil)
    }

    private static func writePriorSessions(
        to storeURL: URL,
        sessionIds: [String],
        cwd: String
    ) throws {
        let identity = try #require(Self.processStartIdentity(pid: Self.ompPID))
        let timestamp = Date.now.timeIntervalSince1970
        var sessions: [String: Any] = [:]
        for (index, sessionId) in sessionIds.enumerated() {
            sessions[sessionId] = [
                "sessionId": sessionId,
                "workspaceId": Self.staleWorkspaceId,
                "surfaceId": Self.staleSurfaceId,
                "cwd": cwd,
                "pid": Self.ompPID,
                "pidStartSeconds": identity.seconds,
                "pidStartMicroseconds": identity.microseconds,
                "isRestorable": true,
                "startedAt": timestamp + Double(index),
                "updatedAt": timestamp + Double(index),
            ]
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
