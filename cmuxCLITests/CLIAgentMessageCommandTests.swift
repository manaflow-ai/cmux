import Darwin
import Foundation
import Testing

/// `cmux agent message` must go through `agent.message.send`, never the
/// terminal keystroke path, and the inbox hooks must answer each agent in the
/// shape its hook protocol expects without ever erasing a human's prompt.
@Suite(.serialized)
struct CLIAgentMessageCommandTests {
    private static let callerWorkspaceID = "11111111-1111-1111-1111-111111111111"
    private static let callerSurfaceID = "22222222-2222-2222-2222-222222222222"
    private static let timeout: TimeInterval = 60

    // MARK: - cmux agent message

    @Test func messageGoesThroughTheMessageChannelNotKeystrokes() throws {
        let run = try runCLI(arguments: ["agent", "message", "cmux-remote-status", "rebase", "when", "free"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let methods = run.requests.compactMap { $0["method"] as? String }
        #expect(methods.contains("agent.message.send"))
        #expect(!methods.contains("surface.send_text"))
        #expect(!methods.contains("terminal.paste"))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["target"] as? String == "cmux-remote-status")
        #expect(params["body"] as? String == "rebase when free")
        #expect(params["sender_surface_id"] as? String == Self.callerSurfaceID)
        #expect(params["sender_workspace_id"] as? String == Self.callerWorkspaceID)
        #expect(params["from"] == nil)
        #expect(run.result.stdout.contains("msg-1"), Comment(rawValue: run.result.stdout))
    }

    @Test func messageFromThreadAndSeparator() throws {
        let run = try runCLI(arguments: [
            "agent", "message", "workspace:3", "--from", "reviewer", "--thread", "t-9", "--", "--not-a-flag",
        ])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["target"] as? String == "workspace:3")
        #expect(params["from"] as? String == "reviewer")
        #expect(params["thread_id"] as? String == "t-9")
        #expect(params["body"] as? String == "--not-a-flag")
    }

    @Test func replyToNeedsNoTarget() throws {
        let run = try runCLI(arguments: ["agent", "message", "--reply-to", "msg-0", "done"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["reply_to"] as? String == "msg-0")
        #expect(params["target"] == nil)
        #expect(params["body"] as? String == "done")
    }

    @Test func dashReadsTheMessageFromStandardInput() throws {
        let run = try runCLI(
            arguments: ["agent", "message", "surface:4", "-"],
            standardInput: "line one\nline two\n"
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["body"] as? String == "line one\nline two\n")
    }

    @Test func emptyMessageFailsWithoutSending() throws {
        let run = try runCLI(arguments: ["agent", "message", "surface:4"], standardInput: "")

        #expect(run.result.status != 0)
        #expect(run.request("agent.message.send") == nil)
    }

    @Test func messageWarnsWhenTheRecipientHasNoAgentYet() throws {
        let run = try runCLI(
            arguments: ["agent", "message", "surface:4", "hi"],
            responses: ["agent.message.send": Self.sendResult(hasAgent: false)]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(!run.result.stderr.isEmpty)
    }

    @Test func messageHelpNeedsNoSocket() throws {
        let run = try runCLI(arguments: ["agent", "message", "--help"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(run.result.stdout.contains("Usage: cmux agent message"))
        #expect(run.request("agent.message.send") == nil)
    }

    @Test func inboxListsMessagesAndCanMarkThemRead() throws {
        let run = try runCLI(
            arguments: ["agent", "inbox", "--surface", "workspace:2", "--state", "queued", "--mark-read"],
            responses: [
                "agent.message.list": [
                    "messages": [[
                        "id": "abcdef0123456789",
                        "state": "queued",
                        "sender_name": "coordinator",
                        "body": "first line\nsecond line",
                    ], [
                        "id": "fedcba9876543210",
                        "state": "delivered",
                        "sender_name": "reviewer",
                        "body": "already delivered",
                    ]],
                ],
            ]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let listParams = try #require(run.request("agent.message.list")?["params"] as? [String: Any])
        #expect(listParams["surface"] as? String == "workspace:2")
        #expect(listParams["state"] as? String == "queued")
        let readParams = try #require(run.request("agent.message.mark_read")?["params"] as? [String: Any])
        #expect(readParams["ids"] as? [String] == ["fedcba9876543210"])
        #expect(run.result.stdout.contains("abcdef01  coordinator: first line"), Comment(rawValue: run.result.stdout))
        #expect(!run.result.stdout.contains("second line"))
    }

    // MARK: - Hooks

    @Test func claudePromptSubmitDrainAttachesPendingMessagesAsContext() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-drain"],
            standardInput: #"{"session_id":"s-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#,
            responses: ["agent.message.claim": ["messages": [], "text": "[cmux agent message] from a\n---\nhello\n---"]]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("agent.message.claim")?["params"] as? [String: Any])
        #expect(params["surface_id"] as? String == Self.callerSurfaceID)
        #expect(params["via"] as? String == "claude.prompt-submit")
        #expect(params["mark_delivered_read"] as? Bool == false)
        let output = try #require(codexHookJSONObject(run.result.stdout))
        let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "UserPromptSubmit")
        #expect((specific["additionalContext"] as? String)?.contains("hello") == true)
    }

    @Test func claudePromptSubmitDrainIsANoOpWithoutMessages() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-drain"],
            standardInput: #"{"session_id":"s-1"}"#,
            responses: ["agent.message.claim": ["messages": [], "text": ""]]
        )

        #expect(run.result.status == 0)
        #expect(run.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    }

    @Test func inboxHooksOutsideACmuxSurfaceDoNothing() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-drain"],
            standardInput: #"{"session_id":"s-1"}"#,
            surfaceID: nil
        )

        #expect(run.result.status == 0)
        #expect(run.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
        #expect(run.request("agent.message.claim") == nil)
    }

    @Test func claudeWaitClaimsThenWakesTheSessionByExitingTwo() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-wait"],
            standardInput: #"{"session_id":"s-7","hook_event_name":"Stop"}"#,
            responses: [
                "agent.message.poll": ["status": "current", "queued": 1, "held": false],
                "agent.message.claim": ["messages": [], "text": "[cmux agent message] from a\n---\nwake up\n---"],
            ]
        )

        #expect(run.result.status == 2, Comment(rawValue: run.result.stderr))
        #expect(run.result.stderr.contains("wake up"), Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout.isEmpty)
        let poll = try #require(run.request("agent.message.poll")?["params"] as? [String: Any])
        #expect(poll["surface_id"] as? String == Self.callerSurfaceID)
        #expect((poll["poller_key"] as? String)?.isEmpty == false)
        #expect(poll["register"] as? Bool == true)
        #expect(poll["mark_delivered_read"] as? Bool == true)
        let claim = try #require(run.request("agent.message.claim")?["params"] as? [String: Any])
        #expect(claim["via"] as? String == "claude.wake")
        #expect(claim["defer_delivery"] as? Bool == true)
        #expect((claim["poller_key"] as? String)?.isEmpty == false)
        // The poll claims nothing; the claim is a separate call made right
        // before the message is handed to Claude.
        let methods = run.requests.compactMap { $0["method"] as? String }
        #expect(methods.firstIndex(of: "agent.message.poll")! < methods.firstIndex(of: "agent.message.claim")!)
    }

    @Test func claudeWaitExitsQuietlyWhenANewerHookTakesOver() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-wait"],
            standardInput: #"{"session_id":"s-7","hook_event_name":"SessionStart"}"#,
            responses: ["agent.message.poll": ["status": "superseded"]]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stderr.isEmpty)
        let params = try #require(run.request("agent.message.poll")?["params"] as? [String: Any])
        #expect(params["mark_delivered_read"] as? Bool == false)
        #expect(run.request("agent.message.claim") == nil)
    }

    @Test func claudeWaitDoesNotClaimWhileDeliveryIsHeld() throws {
        // Held on every poll, then superseded, so the hook exits on its own.
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-wait"],
            standardInput: #"{"session_id":"s-7","hook_event_name":"Stop"}"#,
            responses: ["agent.message.poll": ["status": "current", "queued": 2, "held": true]],
            pollResponsesAfterFirst: ["status": "superseded"]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.request("agent.message.claim") == nil)
        let polls = run.requests.filter { $0["method"] as? String == "agent.message.poll" }
        #expect(polls.count == 2)
        #expect((polls.last?["params"] as? [String: Any])?["register"] as? Bool == false)
    }

    @Test func headlessClaudeRunsLeaveTheInboxAlone() throws {
        let drain = try runCLI(
            arguments: ["hooks", "claude", "inbox-drain"],
            standardInput: #"{"session_id":"s-1"}"#,
            extraEnvironment: ["CMUX_CLAUDE_HEADLESS": "1"],
            responses: ["agent.message.claim": ["messages": [], "text": "should not appear"]]
        )
        #expect(drain.result.status == 0)
        #expect(drain.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")

        let wait = try runCLI(
            arguments: ["hooks", "claude", "inbox-wait"],
            standardInput: #"{"session_id":"s-1","hook_event_name":"SessionStart"}"#,
            extraEnvironment: ["CMUX_CLAUDE_HEADLESS": "1"]
        )
        #expect(wait.result.status == 0)
        #expect(drain.requests.isEmpty && wait.requests.isEmpty)
    }

    @Test func optionsAndHelpFlagsAfterTheSeparatorAreMessageText() throws {
        let run = try runCLI(arguments: ["agent", "message", "surface:4", "--", "run", "ls", "-h", "--from", "x"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["target"] as? String == "surface:4")
        #expect(params["body"] as? String == "run ls -h --from x")
        #expect(params["from"] == nil)
    }

    @Test func codexStopContinuesTheTurnWithPendingMessages() throws {
        let run = try runCLI(
            arguments: ["hooks", "codex", "inbox-stop"],
            standardInput: #"{"session_id":"c-1","hook_event_name":"Stop"}"#,
            responses: ["agent.message.claim": ["messages": [], "text": "[cmux agent message] from a\n---\nnext\n---"]]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("agent.message.claim")?["params"] as? [String: Any])
        #expect(params["via"] as? String == "codex.stop")
        #expect(params["mark_delivered_read"] as? Bool == true)
        let output = try #require(codexHookJSONObject(run.result.stdout))
        #expect(output["decision"] as? String == "block")
        #expect((output["reason"] as? String)?.contains("next") == true)
    }

    // MARK: - Harness

    private struct Run {
        let result: CLIHookProcessRunner.Result
        let requests: [[String: Any]]

        func request(_ method: String) -> [String: Any]? {
            requests.last { $0["method"] as? String == method }
        }
    }

    private static func sendResult(hasAgent: Bool = true) -> [String: Any] {
        [
            "id": "msg-1",
            "state": "queued",
            "recipient_workspace_title": "cmux-remote-status",
            "recipient_surface_ref": "surface:4",
            "recipient_has_agent": hasAgent,
        ]
    }

    private func runCLI(
        arguments: [String],
        standardInput: String? = nil,
        surfaceID: String? = callerSurfaceID,
        extraEnvironment: [String: String] = [:],
        responses: [String: [String: Any]] = [:],
        pollResponsesAfterFirst: [String: Any]? = nil
    ) throws -> Run {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-agent-message-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var canned: [String: [String: Any]] = ["agent.message.send": Self.sendResult()]
        canned.merge(responses) { _, new in new }
        let socketPath = makeCodexHookSocketPath("agentmsg")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let recorder = RequestRecorder()
        let server = Self.startMockServer(
            listenerFD: listenerFD,
            recorder: recorder,
            responses: canned,
            laterPoll: pollResponsesAfterFirst
        )
        defer {
            server.stop.set()
            _ = server.done.wait(timeout: .now() + 5)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = [
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_SOCKET_PASSWORD": "",
            "CMUX_WORKSPACE_ID": Self.callerWorkspaceID,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CFFIXED_USER_HOME": home.path,
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        if let surfaceID {
            environment["CMUX_SURFACE_ID"] = surfaceID
        }
        environment.merge(extraEnvironment) { _, new in new }
        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self),
            arguments: arguments,
            environment: environment,
            standardInput: standardInput ?? "",
            timeout: Self.timeout
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return Run(result: result, requests: recorder.requests())
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func requests() -> [[String: Any]] {
            lock.lock()
            let snapshot = lines
            lock.unlock()
            return snapshot.compactMap(codexHookJSONObject)
        }
    }

    private final class CannedResponses: @unchecked Sendable {
        private let lock = NSLock()
        private let byMethod: [String: [String: Any]]
        /// Answers every `agent.message.poll` after the first, when set.
        private let laterPoll: [String: Any]?
        private var polls = 0

        init(_ byMethod: [String: [String: Any]], laterPoll: [String: Any]?) {
            self.byMethod = byMethod
            self.laterPoll = laterPoll
        }

        func result(for method: String) -> [String: Any] {
            lock.lock()
            defer { lock.unlock() }
            if method == "agent.message.poll" {
                polls += 1
                if polls > 1, let laterPoll { return laterPoll }
            }
            return byMethod[method] ?? [:]
        }
    }

    private static func startMockServer(
        listenerFD: Int32,
        recorder: RequestRecorder,
        responses: [String: [String: Any]],
        laterPoll: [String: Any]?
    ) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        let canned = CannedResponses(responses, laterPoll: laterPoll)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            while !stop.isSet {
                var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pollFD, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard ready > 0 else { continue }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                serve(clientFD: clientFD, recorder: recorder, canned: canned)
            }
        }
        return (done, stop)
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private static func serve(clientFD: Int32, recorder: RequestRecorder, canned: CannedResponses) {
        defer { Darwin.close(clientFD) }
        guard ignoreSIGPIPE(onAcceptedFixtureSocket: clientFD) else { return }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                recorder.record(line)
                let request = codexHookJSONObject(line)
                let id = (request?["id"] as? String) ?? "unknown"
                let method = request?["method"] as? String ?? ""
                let result = canned.result(for: method)
                let response = codexHookV2Response(id: id, ok: true, result: result)
                guard writeAllToFixtureSocket(response + "\n", fd: clientFD) else { return }
            }
        }
    }
}
