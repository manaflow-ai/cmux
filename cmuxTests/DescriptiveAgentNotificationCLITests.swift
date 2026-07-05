import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CLINotifyProcessIntegrationRegressionTests {
    func testGenericAgentStopFallsBackToSavedPromptSnippetAndAgentMeta() throws {
        let context = try makeClaudeHookContext(name: "codex-prompt-fallback")
        defer { context.cleanup() }

        let sessionId = "codex-prompt-fallback-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let prompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"Summarize project status"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let stopStart = context.state.commands.count
        let stop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)

        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        let notify = try XCTUnwrap(
            stopCommands.first { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Expected a Codex stop notification, saw \(stopCommands)"
        )
        XCTAssertTrue(notify.contains("|Finished: Summarize project status|"), notify)
        XCTAssertTrue(notify.hasSuffix("|c=turn-complete;p=0;a=codex"), notify)
    }

    func testPromptSubmitWithoutPromptClearsSavedPromptForCompletionBanner() throws {
        let context = try makeClaudeHookContext(name: "codex-prompt-clear")
        defer { context.cleanup() }

        let sessionId = "codex-prompt-clear-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let firstPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"Refactor the parser"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(firstPrompt.status, 0, firstPrompt.stderr)

        let firstStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(firstStop.status, 0, firstStop.stderr)

        // A second prompt-submit with no extractable prompt must clear the
        // saved prompt: the next completion banner may not describe turn 1.
        let promptlessSubmit = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-2","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(promptlessSubmit.status, 0, promptlessSubmit.stderr)

        let stopStart = context.state.commands.count
        let secondStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-2","cwd":"\#(context.root.path)","hook_event_name":"Stop"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(secondStop.status, 0, secondStop.stderr)

        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        let notify = try XCTUnwrap(
            stopCommands.first { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Expected a Codex stop notification, saw \(stopCommands)"
        )
        XCTAssertFalse(notify.contains("Finished: Refactor the parser"), notify)
    }

    func testGenericAgentStopTreatsJSONAssistantMessageAsMissing() throws {
        let context = try makeClaudeHookContext(name: "codex-json-blob-fallback")
        defer { context.cleanup() }

        let sessionId = "codex-json-blob-fallback-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let prompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"Check JSON response"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let stopStart = context.state.commands.count
        let stop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"{\"status\":\"ok\"}"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)

        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        let notify = try XCTUnwrap(
            stopCommands.first { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Expected a Codex stop notification, saw \(stopCommands)"
        )
        XCTAssertTrue(notify.contains("|Finished: Check JSON response|"), notify)
        XCTAssertFalse(notify.contains(#"{"status":"ok"}"#), notify)
        XCTAssertTrue(notify.hasSuffix("|c=turn-complete;p=0;a=codex"), notify)
    }

    func testClaudeTranscriptJSONAssistantMessageDoesNotBecomeNotificationBody() throws {
        let context = try makeClaudeHookContext(name: "claude-transcript-json-fallback")
        defer { context.cleanup() }

        let sessionId = "claude-transcript-json-fallback-session"
        let transcriptURL = context.root.appendingPathComponent("claude-transcript-json-fallback.jsonl")
        try [
            #"{"type":"assistant","message":{"role":"assistant","content":"Earlier assistant prose"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"{\"findings\":[]}"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let prompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit"}"#
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let stopStart = context.state.commands.count
        let stop = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop"}"#
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)

        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        let stopNotify = try XCTUnwrap(
            stopCommands.first { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Claude Code|") },
            "Expected a Claude stop notification, saw \(stopCommands)"
        )
        XCTAssertTrue(stopNotify.contains("|Claude session completed in \(context.root.lastPathComponent)|"), stopNotify)
        XCTAssertFalse(stopNotify.contains(#"{"findings":[]}"#), stopNotify)
        XCTAssertFalse(stopNotify.contains("Earlier assistant prose"), stopNotify)
        XCTAssertTrue(stopNotify.hasSuffix("|c=turn-complete;p=0;a=claude"), stopNotify)

        let idleStart = context.state.commands.count
        let idle = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "notification"],
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude needs your input"}"#
        )
        XCTAssertFalse(idle.timedOut, idle.stderr)
        XCTAssertEqual(idle.status, 0, idle.stderr)

        let idleCommands = Array(context.state.commands.dropFirst(idleStart))
        let idleNotify = try XCTUnwrap(
            idleCommands.first { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Claude Code|") },
            "Expected a Claude idle notification, saw \(idleCommands)"
        )
        XCTAssertTrue(idleNotify.contains("|Claude session completed in \(context.root.lastPathComponent)|"), idleNotify)
        XCTAssertFalse(idleNotify.contains(#"{"findings":[]}"#), idleNotify)
        XCTAssertFalse(idleNotify.contains("Earlier assistant prose"), idleNotify)
        XCTAssertTrue(idleNotify.hasSuffix("|c=idle-reminder;p=0;a=claude"), idleNotify)
    }

    @MainActor
    func testLegacyNotifyTargetPayloadsFlowThroughAppParserWithoutAgentTagging() async throws {
        let socketPath = makeSocketPath("legacy-payloads")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        let notificationDelivered = expectation(description: "legacy notifications delivered")
        notificationDelivered.expectedFulfillmentCount = 2
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in
            notificationDelivered.fulfill()
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            TerminalController.shared.stop()
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        XCTAssertTrue(waitForSocketFile(at: socketPath), "Timed out waiting for socket at \(socketPath)")

        let legacy3 = "notify_target_async \(workspace.id.uuidString) \(focusedPanelId.uuidString) Legacy Title|Legacy Subtitle|Legacy Body"
        let legacyMeta = "notify_target_async \(workspace.id.uuidString) \(focusedPanelId.uuidString) Legacy Meta|Legacy Subtitle|Legacy Body|c=turn-complete;p=0"
        let responses = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.sendSocketCommands([legacy3, legacyMeta], to: socketPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(responses, ["OK", "OK"])
        await fulfillment(of: [notificationDelivered], timeout: 5)

        let legacy3Notification = try XCTUnwrap(
            store.notifications.first { $0.title == "Legacy Title" }
        )
        XCTAssertEqual(legacy3Notification.subtitle, "Legacy Subtitle")
        XCTAssertEqual(legacy3Notification.body, "Legacy Body")
        XCTAssertNil(legacy3Notification.agentId)

        let legacyMetaNotification = try XCTUnwrap(
            store.notifications.first { $0.title == "Legacy Meta" }
        )
        XCTAssertEqual(legacyMetaNotification.subtitle, "Legacy Subtitle")
        XCTAssertEqual(legacyMetaNotification.body, "Legacy Body")
        XCTAssertNil(legacyMetaNotification.agentId)
    }

    private nonisolated func sendSocketCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketTestError("socket(AF_UNIX)") }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else { throw socketTestError("connect(\(socketPath))") }

        var responses: [String] = []
        for command in commands {
            try writeSocketLine(command, to: fd)
            responses.append(try readSocketLine(from: fd))
        }
        return responses
    }

    private func codexLaunchEnvironment(context: ClaudeHookContext, sessionId _: String) -> [String: String] {
        [
            "CMUX_AGENT_LAUNCH_KIND": "codex",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/codex",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/codex", "--model", "gpt-5.4"]),
        ]
    }

    private nonisolated func writeSocketLine(_ command: String, to fd: Int32) throws {
        let payload = Array((command + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let wrote = payload.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard wrote >= 0 else { throw socketTestError("write(\(command))") }
            offset += wrote
        }
    }

    private nonisolated func readSocketLine(from fd: Int32) throws -> String {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            guard count > 0 else { throw socketTestError("read") }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated func socketTestError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
