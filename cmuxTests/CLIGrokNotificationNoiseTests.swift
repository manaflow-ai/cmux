import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testGrokRepeatedWaitingNotificationsDedupe() throws {
        let context = try makeGrokNoiseContext(name: "grok-wait-dedupe")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let firstStart = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))

        let commands = Array(context.state.snapshot().dropFirst(firstStart))
        XCTAssertEqual(notifyCommands(in: commands).count, 1, "Repeated waiting events should dedupe, saw \(commands)")
    }

    func testGrokUnclassifiedFallbackRebuildIsGateableAndDedupeable() throws {
        let context = try makeGrokNoiseContext(name: "grok-fallback-gate", sessionId: nil)
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "Grok needs permission to run rm"))
        try runGrokNoiseHook(context, "prompt-submit", payload: grokNoisePayload(context, event: "UserPromptSubmit"))

        let fallbackStart = context.state.snapshot().count
        let unclassified = grokUnclassifiedPayload(context)
        try runGrokNoiseHook(context, "notification", payload: unclassified)
        try runGrokNoiseHook(context, "notification", payload: unclassified)

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(fallbackStart)))
        XCTAssertEqual(notifications.count, 1, "Unclassified fallback re-notification should dedupe, saw \(notifications)")
        XCTAssertTrue(
            notifications.first?.hasSuffix("|c=idle-reminder;p=0") == true,
            "Fallback re-notification should be gateable as idle-reminder, saw \(notifications)"
        )
    }

    func testGrokIncidentalCompletionCueAfterInterleavedNotificationDoesNotReding() throws {
        let context = try makeGrokNoiseContext(name: "grok-incidental")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "Turn complete in 1.2s."))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "All done reviewing the files you asked about"))

        // This is already green pre-fix because old waiting events do not
        // overwrite the single legacy fingerprint slot. Keep it as a guard that
        // the new multi-fingerprint store does not regress the eviction case.
        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 2, "Incidental completion cue should not send after a real completion, saw \(notifications)")
        XCTAssertEqual(notifications.filter { $0.contains("Grok|Completed|") }.count, 1, notifications.joined(separator: "\n"))
    }

    func testGrokSessionStartRefireDoesNotRearmCompletionDedupe() throws {
        let context = try makeGrokNoiseContext(name: "grok-start-refire")
        defer { context.cleanup() }

        let startPayload = grokNoisePayload(context, event: "SessionStart")
        let completionPayload = grokNoisePayload(context, event: "Notification", message: "Turn complete in 1.2s.")
        try runGrokNoiseHook(context, "session-start", payload: startPayload)
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: completionPayload)
        try runGrokNoiseHook(context, "session-start", payload: startPayload)
        try runGrokNoiseHook(context, "notification", payload: completionPayload)

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 1, "SessionStart refire should not re-arm the same completion notification, saw \(notifications)")
    }

    func testGrokRepeatedIdenticalPermissionPromptsDedupePerTurn() throws {
        let context = try makeGrokNoiseContext(name: "grok-permission")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        let permissionPrompt = grokPermissionPromptPayload(context)
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)

        let firstTurnNotifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(firstTurnNotifications.count, 1, "Repeated identical permission prompts should dedupe per turn, saw \(firstTurnNotifications)")
        XCTAssertTrue(
            firstTurnNotifications.first?.hasSuffix("|c=needs-permission;p=0") == true,
            firstTurnNotifications.joined(separator: "\n")
        )

        try runGrokNoiseHook(context, "prompt-submit", payload: grokNoisePayload(context, event: "UserPromptSubmit"))
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 2, "Prompt submit should re-arm permission prompt delivery for the next turn, saw \(notifications)")
        XCTAssertTrue(notifications.allSatisfy { $0.hasSuffix("|c=needs-permission;p=0") }, notifications.joined(separator: "\n"))
    }

    func testGrokDistinctPermissionPromptsAlwaysDeliver() throws {
        let context = try makeGrokNoiseContext(name: "grok-distinct-permission")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokPermissionPromptPayload(context, message: "Grok needs permission to run rm"))
        try runGrokNoiseHook(context, "notification", payload: grokPermissionPromptPayload(context, message: "Grok needs permission to edit config.yaml"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 2, "Distinct permission prompts should each deliver, saw \(notifications)")
        XCTAssertTrue(notifications.allSatisfy { $0.hasSuffix("|c=needs-permission;p=0") }, notifications.joined(separator: "\n"))
    }

    func testAntigravityErrorNotificationRemainsUntagged() throws {
        let context = try makeGrokNoiseContext(name: "antigravity-error", agent: "antigravity")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: antigravityNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: antigravityNoisePayload(context, event: "Notification", message: "Build failed: exit 1"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 1, "Expected one Antigravity error notification, saw \(notifications)")
        XCTAssertFalse(
            notifications.first?.contains("|c=") == true,
            "Error notifications should remain untagged, saw \(notifications)"
        )
    }

    private struct GrokNoiseContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String
        let sessionId: String
        let agent: String
        let environment: [String: String]

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeGrokNoiseContext(
        name: String,
        agent: String = "grok",
        sessionId requestedSessionId: String? = "grok-noise-session"
    ) throws -> GrokNoiseContext {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = requestedSessionId ?? surfaceId
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "GROK_HOME": grokHome.path,
        ]

        startDetachedAgentHookMockServer(listenerFD: listenerFD, state: state, surfaceId: surfaceId, connectionCount: 128)
        return GrokNoiseContext(
            cliPath: cliPath,
            socketPath: socketPath,
            listenerFD: listenerFD,
            state: state,
            root: root,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: sessionId,
            agent: agent,
            environment: environment
        )
    }

    private func runGrokNoiseHook(_ context: GrokNoiseContext, _ subcommand: String, payload: String) throws {
        let result = runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", context.agent, subcommand],
            environment: context.environment,
            standardInput: payload,
            timeout: 5
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
    }

    private func grokNoisePayload(_ context: GrokNoiseContext, event: String, message: String? = nil) -> String {
        notificationNoisePayload(sessionKey: "sessionId", context: context, eventKey: "hookEventName", event: event, message: message)
    }

    private func grokPermissionPromptPayload(
        _ context: GrokNoiseContext,
        message: String = "Tool permission requested"
    ) -> String {
        #"{"hookEventName":"notification","sessionId":"\#(context.sessionId)","cwd":"\#(context.root.path)","notificationType":"permission_prompt","message":"\#(message)","level":"info"}"#
    }

    private func antigravityNoisePayload(_ context: GrokNoiseContext, event: String, message: String? = nil) -> String {
        notificationNoisePayload(sessionKey: "session_id", context: context, eventKey: "hook_event_name", event: event, message: message)
    }

    private func grokUnclassifiedPayload(_ context: GrokNoiseContext) -> String {
        #"{"sessionId":"\#(context.sessionId)","cwd":"\#(context.root.path)","unparseable":true}"#
    }

    private func notificationNoisePayload(
        sessionKey: String,
        context: GrokNoiseContext,
        eventKey: String,
        event: String,
        message: String?
    ) -> String {
        var fields = [
            #""\#(sessionKey)":"\#(context.sessionId)""#,
            #""cwd":"\#(context.root.path)""#,
            #""\#(eventKey)":"\#(event)""#,
        ]
        if let message {
            fields.append(#""message":"\#(message)""#)
        }
        return "{\(fields.joined(separator: ","))}"
    }

    private func notifyCommands(in commands: [String]) -> [String] {
        commands.filter { $0.hasPrefix("notify_target_async ") }
    }
}
