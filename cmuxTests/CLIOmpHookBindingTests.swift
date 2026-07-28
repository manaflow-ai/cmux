import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIOmpHookBindingTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let workspaceId = "11111111-1111-1111-1111-111111111111"
    private static let leakedSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let liveSurfaceId = "33333333-3333-3333-3333-333333333333"
    private static let ompPID = 43_210

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
            surfaceId: Self.liveSurfaceId,
            cwd: context.root.path
        )

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.workspaceId: [Self.leakedSurfaceId, Self.liveSurfaceId],
            ],
            pidTarget: (workspaceId: Self.workspaceId, surfaceId: Self.liveSurfaceId)
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_WORKSPACE_ID"] = Self.workspaceId
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

        let requests = context.state.snapshot().compactMap(Harness.jsonObject)
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
        #expect(resumeParams["workspace_id"] as? String == Self.workspaceId)
        #expect(resumeParams["surface_id"] as? String == Self.liveSurfaceId)

        let store = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        let sessions = try #require(store["sessions"] as? [String: Any])
        #expect(sessions[previousSessionId] == nil, "A resumed session ID must supersede the prior claim from the same live process")
        let resumed = try #require(sessions[resumedSessionId] as? [String: Any])
        #expect(resumed["workspaceId"] as? String == Self.workspaceId)
        #expect(resumed["surfaceId"] as? String == Self.liveSurfaceId)
        #expect(resumed["pid"] as? Int == Self.ompPID)
        #expect(store["activeSessionsBySurface"] == nil)
        #expect(store["activeSessionsByWorkspace"] == nil)
    }

    private static func writePriorSession(
        to storeURL: URL,
        sessionId: String,
        surfaceId: String,
        cwd: String
    ) throws {
        let timestamp = Date.now.timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "activeSessionsBySurface": [:],
            "activeSessionsByWorkspace": [:],
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": cwd,
                    "pid": ompPID,
                    "isRestorable": true,
                    "startedAt": timestamp,
                    "updatedAt": timestamp,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: storeURL)
    }

    private static func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }
}
