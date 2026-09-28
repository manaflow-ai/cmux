import Foundation
import Testing

/// The Claude hooks that tell the sidebar what a *running* pane is running on:
/// `--work=subagents` while a `Task` call is in flight, and plain
/// `--work=running` otherwise. The waiting half (a Stop with live background
/// work) is covered in `ClaudeBackgroundWorkNotifyTests`.
@Suite(.serialized)
struct ClaudeHookWorkStateTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let workspaceId = "11111111-1111-1111-1111-111111111111"
    private static let surfaceId = "22222222-2222-2222-2222-222222222222"

    /// Runs one PreToolUse hook for `toolName` and returns the commands the
    /// mock app saw.
    private func runPreToolUse(name: String, toolName: String, pid: String) throws -> [String] {
        let context = try Harness.makeContext(name: name)
        defer { context.cleanup() }
        let sessionId = "\(name)-session"

        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.workspaceId,
            surfaceId: Self.surfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.workspaceId: [Self.surfaceId]],
            pidTarget: nil,
            surfaceTargets: [Self.surfaceId: Self.workspaceId]
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.workspaceId
        environment["CMUX_SURFACE_ID"] = Self.surfaceId
        environment["CMUX_CLAUDE_PID"] = pid

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"\#(toolName)","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        return context.state.snapshot()
    }

    private func statusLine(_ commands: [String]) -> String? {
        commands.last { $0.hasPrefix("set_status claude_code ") }
    }

    /// A `Task` call blocks the parent inside the tool until its subagents
    /// finish, so the subagent state holds for exactly that span.
    @Test func taskToolReportsRunningSubagents() throws {
        let commands = try runPreToolUse(name: "work-state-task", toolName: "Task", pid: "43401")
        let status = statusLine(commands)
        #expect(status?.hasPrefix("set_status claude_code Running subagents ") == true,
                "A Task call must say the agent is running subagents; saw \(commands)")
        #expect(status?.contains("--work=subagents") == true,
                "The subagents pill must carry the work state the glyph reads; saw \(commands)")
        #expect(status?.contains("--icon=point.3.filled.connected.trianglepath.dotted") == true,
                "The subagents pill must use the connected-points symbol; saw \(commands)")
    }

    /// Every other tool is the agent working directly, which must keep the
    /// pill and glyph it had before the work state existed.
    @Test func ordinaryToolReportsPlainRunning() throws {
        let commands = try runPreToolUse(name: "work-state-bash", toolName: "Bash", pid: "43402")
        let status = statusLine(commands)
        #expect(status?.hasPrefix("set_status claude_code Running ") == true,
                "An ordinary tool must keep the plain Running pill; saw \(commands)")
        #expect(status?.contains("--work=running") == true)
        #expect(status?.contains("--icon=bolt.fill") == true)
        #expect(status?.contains("subagents") == false)
    }
}
