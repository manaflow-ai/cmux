import Foundation
import Testing

@Suite(.serialized)
struct ClaudeHookHibernationSessionEndPreservationTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness
    private static let workspaceID = "11111111-1111-1111-1111-111111111111"
    private static let surfaceID = "22222222-2222-2222-2222-222222222222"

    /// Verifies the app probe runs before SessionEnd consumes the record.
    @Test
    func sessionEndPreservesHibernatingGenerationBeforeCleanup() throws {
        let context = try Harness.makeContext(name: "session-end-hibernation-preserve")
        defer { context.cleanup() }
        let sessionID = "session-end-hibernation-preserve-session"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionID,
            workspaceId: Self.workspaceID,
            surfaceId: Self.surfaceID,
            cwd: context.root.path,
            pid: 43219,
            pidStartSeconds: 17,
            pidStartMicroseconds: 23
        )
        let handled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.workspaceID: [Self.surfaceID]],
            pidTarget: (workspaceId: Self.workspaceID, surfaceId: Self.surfaceID),
            hibernationSessionEndPreserved: true
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.workspaceID
        environment["CMUX_SURFACE_ID"] = Self.surfaceID
        environment["CMUX_CLAUDE_PID"] = "43219"
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionID)","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout == "{}\n")
        let commands = context.state.snapshot()
        let request = try #require(commands.compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["method"] as? String == "agent.hibernation.session_end" else { return nil }
            return payload
        }.first)
        let params = try #require(request["params"] as? [String: Any])
        #expect((params["pid"] as? NSNumber)?.intValue == 43219)
        #expect((params["pid_start_seconds"] as? NSNumber)?.int64Value == 17)
        #expect((params["pid_start_microseconds"] as? NSNumber)?.int64Value == 23)
        #expect(!commands.contains { $0.contains("\"method\":\"surface.resume.clear\"") })
        #expect(!commands.contains { $0.contains("\"method\":\"feed.push\"") })
        #expect(try Harness.sessionRecord(in: context.storeURL, sessionId: sessionID) != nil)
    }
}
