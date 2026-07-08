import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testGrokRepeatedWaitingNotificationsUpdateStateWithoutBanner() throws {
        let context = try makeGrokNoiseContext(name: "grok-wait-dedupe")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let firstStart = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))

        let commands = Array(context.state.snapshot().dropFirst(firstStart))
        XCTAssertEqual(notifyCommands(in: commands).count, 0, "Grok waiting events should update state without banners, saw \(commands)")
        XCTAssertTrue(
            setStatusCommands(in: commands).contains { $0.contains("set_status grok Grok needs input") },
            "Grok waiting events should still mark the pane as needing input, saw \(commands)"
        )
    }

    func testGrokWaitingFallbackRebuildUpdatesStateWithoutBanner() throws {
        let context = try makeGrokNoiseContext(name: "grok-fallback-waiting", sessionId: nil)
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))
        try runGrokNoiseHook(context, "prompt-submit", payload: grokNoisePayload(context, event: "UserPromptSubmit"))

        let fallbackStart = context.state.snapshot().count
        let unclassified = grokUnclassifiedPayload(context)
        try runGrokNoiseHook(context, "notification", payload: unclassified)
        try runGrokNoiseHook(context, "notification", payload: unclassified)

        let commands = Array(context.state.snapshot().dropFirst(fallbackStart))
        XCTAssertEqual(notifyCommands(in: commands).count, 0, "Grok fallback rebuild should update state without banners, saw \(commands)")
        XCTAssertTrue(
            setStatusCommands(in: commands).contains { $0.contains("set_status grok Grok needs input") },
            "Grok fallback rebuild should preserve the needs-input pane state, saw \(commands)"
        )
    }

    func testGrokIncidentalCompletionCueDoesNotReding() throws {
        let context = try makeGrokNoiseContext(name: "grok-incidental")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "Turn complete in 1.2s."))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "All done reviewing the files you asked about"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 1, "Incidental completion cue should not send after a real completion, saw \(notifications)")
        XCTAssertTrue(notifications.first?.contains("Grok|Completed|") == true, notifications.joined(separator: "\n"))
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

    func testGrokRepeatedIdenticalPermissionPromptsDoNotBanner() throws {
        let context = try makeGrokNoiseContext(name: "grok-permission")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        let permissionPrompt = grokPermissionPromptPayload(context)
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)

        try runGrokNoiseHook(context, "prompt-submit", payload: grokNoisePayload(context, event: "UserPromptSubmit"))
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 0, "Grok permission_prompt telemetry should never banner, saw \(notifications)")
    }

    func testGrokDistinctPermissionPromptsDoNotBanner() throws {
        let context = try makeGrokNoiseContext(name: "grok-distinct-permission")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokPermissionPromptPayload(context, message: "Grok needs permission to run rm"))
        try runGrokNoiseHook(context, "notification", payload: grokPermissionPromptPayload(context, message: "Grok needs permission to edit config.yaml"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 0, "Grok permission messages should update state without banners, saw \(notifications)")
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

    func testAntigravityErrorFallbackRemainsUntagged() throws {
        let context = try makeGrokNoiseContext(name: "antigravity-error-fallback", agent: "antigravity")
        defer { context.cleanup() }

        let errorMessage = "Build failed: exit 1"
        try seedStoredNotification(
            context,
            subtitle: "Error",
            body: errorMessage,
            status: "error"
        )

        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: antigravityNoisePayload(context, event: "Notification"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 1, "Expected one rebuilt Antigravity error notification, saw \(notifications)")
        XCTAssertTrue(
            notifications.first?.contains("Antigravity|Error|\(errorMessage)") == true,
            notifications.joined(separator: "\n")
        )
        XCTAssertFalse(
            notifications.first?.contains("|c=") == true,
            "Rebuilt error notifications should remain untagged, saw \(notifications)"
        )
    }

    func testAntigravityWaitingNotificationStillBanners() throws {
        let context = try makeGrokNoiseContext(name: "antigravity-waiting", agent: "antigravity")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: antigravityNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: antigravityNoisePayload(context, event: "Notification", message: "waiting for input"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 1, "Antigravity waiting cues should still banner, saw \(notifications)")
        XCTAssertTrue(notifications.first?.hasSuffix("|c=idle-reminder;p=0") == true, notifications.joined(separator: "\n"))
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

    private func seedStoredNotification(
        _ context: GrokNoiseContext,
        subtitle: String,
        body: String,
        status: String
    ) throws {
        let now = Date().timeIntervalSince1970
        let storePayload: [String: Any] = [
            "version": 1,
            "sessions": [
                context.sessionId: [
                    "sessionId": context.sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "lastSubtitle": subtitle,
                    "lastBody": body,
                    "lastNotificationStatus": status,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let storeData = try JSONSerialization.data(withJSONObject: storePayload, options: [.prettyPrinted, .sortedKeys])
        let storeURL = context.root.appendingPathComponent("\(context.agent)-hook-sessions.json", isDirectory: false)
        try storeData.write(to: storeURL)
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

    private func setStatusCommands(in commands: [String]) -> [String] {
        commands.filter { $0.hasPrefix("set_status ") }
    }
}
