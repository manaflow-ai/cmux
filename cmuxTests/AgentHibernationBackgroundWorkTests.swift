import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Hibernation must never terminate an agent that is still waiting on
/// background work: a `run_in_background` shell, a Monitor, or an async subagent.
@Suite
struct AgentHibernationBackgroundWorkTests {
    private static let agentStart: Int64 = 1_800_000_000

    // MARK: Process scope

    @Test
    func lateShellUnderTheAgentMakesTheScopeUnsafe() {
        let scope = processSnapshot(including: [
            .init(pid: 300, parent: 101, group: 300, name: "zsh", startOffset: 600),
            .init(pid: 301, parent: 300, group: 300, name: "sleep", startOffset: 601),
        ]).agentHibernationProcessScope(panelProcessIDs: [101], agentProcessIDs: [101])

        #expect(scope.terminationProcessIDs.contains(300))
        #expect(scope.containsUnrelatedProcess)
    }

    @Test
    func launchBaselineChildrenKeepTheScopeSafe() {
        let scope = processSnapshot(including: [])
            .agentHibernationProcessScope(panelProcessIDs: [101], agentProcessIDs: [101])

        #expect(scope.terminationProcessIDs == [101, 102])
        #expect(scope.containsUnrelatedProcess == false)
    }

    @Test
    func lateNonShellChildDoesNotCountAsBackgroundWork() {
        let scope = processSnapshot(including: [
            .init(pid: 310, parent: 101, group: 101, name: "node", startOffset: 900),
        ]).agentHibernationProcessScope(panelProcessIDs: [101], agentProcessIDs: [101])

        #expect(scope.containsUnrelatedProcess == false)
    }

    @Test
    func lateShellUnderAnMCPServerDoesNotCountAsBackgroundWork() {
        let scope = processSnapshot(including: [
            .init(pid: 320, parent: 102, group: 101, name: "sh", startOffset: 900),
        ]).agentHibernationProcessScope(panelProcessIDs: [101], agentProcessIDs: [101])

        #expect(scope.containsUnrelatedProcess == false)
    }

    // MARK: Transcript

    @Test
    func unfinishedBackgroundBashBlocksTheTeardownSnapshot() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write([
            Self.userTurn,
            Self.backgroundBashLaunch(toolUseID: "toolu_bash", taskID: "bshell1"),
        ])

        guard case .backgroundWorkPending = fixture.snapshotBeforeTeardown() else {
            Issue.record("A pane with an unfinished background shell must not be torn down")
            return
        }
    }

    @Test
    func completedBackgroundBashAllowsTheTeardownSnapshot() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write([
            Self.userTurn,
            Self.backgroundBashLaunch(toolUseID: "toolu_bash", taskID: "bshell1"),
            Self.queuedNotification(toolUseID: "toolu_bash", taskID: "bshell1", status: "completed"),
        ])

        guard case .snapshot = fixture.snapshotBeforeTeardown() else {
            Issue.record("Finished background work must not block hibernation")
            return
        }
    }

    @Test
    func unfinishedAsyncAgentBlocksTheTeardownSnapshot() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write([
            Self.userTurn,
            Self.asyncAgentLaunch(toolUseID: "toolu_agent", agentID: "a1234567890abcdef"),
            Self.monitorEventNotification(taskID: "a1234567890abcdef"),
        ])

        guard case .backgroundWorkPending = fixture.snapshotBeforeTeardown() else {
            Issue.record("A pane with a running async subagent must not be torn down")
            return
        }
    }

    @Test
    func batchedNotificationWithOnlyTaskIDsFinishesEveryNamedTask() {
        let lines = [
            Self.asyncAgentLaunch(toolUseID: "toolu_a", agentID: "a1111111111111111"),
            Self.asyncAgentLaunch(toolUseID: "toolu_b", agentID: "a2222222222222222"),
            #"{"type":"user","timestamp":"2026-09-28T08:09:00.000Z","message":{"role":"user","content":"<task-notification>\n<task-id>a1111111111111111</task-id>\n<task-id>a2222222222222222</task-id>\n<status>stopped</status>\n<summary>2 background agents stopped</summary>\n</task-notification>"}}"#,
        ]

        #expect(Self.unfinished(lines).isEmpty)
    }

    @Test
    func launchesBeforeTheAgentProcessStartedAreIgnored() {
        let lines = [Self.backgroundBashLaunch(toolUseID: "toolu_old", taskID: "bold", timestamp: "2026-09-28T07:00:00.000Z")]
        let agentStartedAt = ISO8601DateFormatter().date(from: "2026-09-28T07:30:00Z")

        #expect(Self.unfinished(lines, notBefore: agentStartedAt).isEmpty)
        #expect(Self.unfinished(lines) == ["toolu_old"])
    }

    @Test
    func monitorEventsAndQuotedNotificationsDoNotFinishATask() {
        let quotedNotification = #"{"type":"user","timestamp":"2026-09-28T08:02:00.000Z","message":{"role":"user","content":[{"tool_use_id":"toolu_cat","type":"tool_result","content":"<task-notification>\n<task-id>bmon1</task-id>\n<tool-use-id>toolu_monitor</tool-use-id>\n<status>completed</status>\n</task-notification>"}]},"toolUseResult":{"stdout":"","stderr":""}}"#
        let lines = [
            #"{"type":"user","timestamp":"2026-09-28T08:00:07.000Z","message":{"role":"user","content":[{"tool_use_id":"toolu_monitor","type":"tool_result","content":"Monitor started"}]},"toolUseResult":{"taskId":"bmon1","timeoutMs":900000,"persistent":false}}"#,
            Self.monitorEventNotification(taskID: "bmon1"),
            quotedNotification,
        ]

        #expect(Self.unfinished(lines) == ["toolu_monitor"])
        #expect(Self.unfinished(lines + [Self.queuedNotification(toolUseID: "toolu_monitor", taskID: "bmon1", status: "completed")]).isEmpty)
    }

    @Test
    func todoTaskIDsAreNotBackgroundLaunches() {
        let todoUpdate = #"{"type":"user","timestamp":"2026-09-28T08:00:08.000Z","message":{"role":"user","content":[{"tool_use_id":"toolu_todo","type":"tool_result","content":"Updated task #3"}]},"toolUseResult":{"success":true,"taskId":"3","updatedFields":["status"]}}"#

        #expect(Self.unfinished([todoUpdate]).isEmpty)
    }

    @Test
    func taskStopFinishesTheStoppedTask() {
        let lines = [
            Self.backgroundBashLaunch(toolUseID: "toolu_server", taskID: "bserver1"),
            #"{"type":"user","timestamp":"2026-09-28T08:03:00.000Z","message":{"role":"user","content":[{"tool_use_id":"toolu_stop","type":"tool_result","content":"Successfully stopped task: bserver1"}]},"toolUseResult":{"message":"Successfully stopped task: bserver1","task_id":"bserver1","task_type":"local_bash","command":"./server"}}"#,
        ]

        #expect(Self.unfinished(lines).isEmpty)
    }

    private static func unfinished(_ lines: [String], notBefore: Date? = nil) -> Set<String> {
        AgentHibernationTranscriptGuard.unfinishedBackgroundLaunchIDs(
            inTranscriptTail: Data(lines.joined(separator: "\n").utf8),
            notBefore: notBefore
        )
    }

    // MARK: Fixtures

    private struct Process {
        let pid: Int
        let parent: Int
        let group: Int
        let name: String
        let startOffset: Int64
    }

    /// Agent 101 (`claude`, group leader) with an MCP server started at launch.
    private func processSnapshot(including extra: [Process]) -> CmuxTopProcessSnapshot {
        let workspaceID = UUID()
        let panelID = UUID()
        let base = [
            Process(pid: 101, parent: 1, group: 101, name: "claude", startOffset: 0),
            Process(pid: 102, parent: 101, group: 101, name: "node", startOffset: 2),
        ]
        let processes = (base + extra).map { process in
            CmuxTopProcessInfo(
                pid: process.pid,
                processIdentity: AgentPIDProcessIdentity(
                    pid: pid_t(process.pid),
                    startSeconds: Self.agentStart + process.startOffset,
                    startMicroseconds: 0
                ),
                parentPID: process.parent, name: process.name, path: nil,
                ttyDevice: 0x123,
                cmuxWorkspaceID: workspaceID,
                cmuxSurfaceID: panelID,
                cmuxAttributionReason: "environment",
                processGroupID: process.group,
                terminalProcessGroupID: 101, cpuPercent: 0, residentBytes: 0,
                virtualBytes: 0, threadCount: 1
            )
        }
        return CmuxTopProcessSnapshot(processes: processes, sampledAt: .now, includesProcessDetails: true)
    }

    struct TranscriptFixture {
        let home: URL
        let cwd = "/tmp/background-work-repo"
        let sessionId = "background-work-session"

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-hibernation-background-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        var transcriptURL: URL {
            home
                .appendingPathComponent(".claude/projects", isDirectory: true)
                .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd), isDirectory: true)
                .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        }

        func write(_ lines: [String]) throws {
            try FileManager.default.createDirectory(
                at: transcriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        }

        func snapshotBeforeTeardown() -> AgentHibernationTranscriptGuard.TeardownSnapshotOutcome {
            AgentHibernationTranscriptGuard.snapshotBeforeTeardown(
                agent: SessionRestorableAgentSnapshot(
                    kind: .claude,
                    sessionId: sessionId,
                    workingDirectory: cwd,
                    launchCommand: nil
                ),
                homeDirectory: home.path,
                snapshotDirectory: home.appendingPathComponent("snapshots", isDirectory: true)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: home)
        }
    }

    static let userTurn = #"{"type":"user","timestamp":"2026-09-28T08:00:00.000Z","message":{"role":"user","content":"run the tests in the background"}}"#

    static func backgroundBashLaunch(toolUseID: String, taskID: String, timestamp: String = "2026-09-28T08:00:05.000Z") -> String {
        #"{"type":"user","timestamp":"\#(timestamp)","message":{"role":"user","content":[{"tool_use_id":"\#(toolUseID)","type":"tool_result","content":"Command running in background with ID: \#(taskID)."}]},"toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"\#(taskID)"}}"#
    }

    static func asyncAgentLaunch(toolUseID: String, agentID: String) -> String {
        #"{"type":"user","timestamp":"2026-09-28T08:00:06.000Z","message":{"role":"user","content":[{"tool_use_id":"\#(toolUseID)","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"\#(agentID)","description":"review"}}"#
    }

    static func queuedNotification(toolUseID: String?, taskID: String, status: String) -> String {
        let toolUse = toolUseID.map { #"\n<tool-use-id>\#($0)</tool-use-id>"# } ?? ""
        return #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-28T08:05:00.000Z","content":"<task-notification>\n<task-id>\#(taskID)</task-id>\#(toolUse)\n<status>\#(status)</status>\n<summary>done</summary>\n</task-notification>"}"#
    }

    /// A Monitor-style event: it names the task but carries no `<status>`.
    static func monitorEventNotification(taskID: String) -> String {
        #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-28T08:01:00.000Z","content":"<task-notification>\n<task-id>\#(taskID)</task-id>\n<summary>Monitor event</summary>\n<event>line</event>\n</task-notification>"}"#
    }
}
