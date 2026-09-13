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
        let oldAdmissionKeys = context.state.admittedNotificationKeysSnapshot()
        XCTAssertEqual(oldAdmissionKeys.count, 1)
        let oldKey = try XCTUnwrap(oldAdmissionKeys.first)
        let promptStart = context.state.snapshot().count
        try runGrokNoiseHook(context, "prompt-submit", payload: grokNoisePayload(context, event: "UserPromptSubmit"))
        let promptCommands = Array(context.state.snapshot().dropFirst(promptStart))
        XCTAssertEqual(promptCommands.filter { $0.hasPrefix("clear_notifications ") }, [
            "clear_notifications --tab=\(context.workspaceId) --panel=\(context.surfaceId) --correlation-key=\(oldKey)",
        ])

        // Prompt submission clears summaries. Seed retained display metadata
        // explicitly so this fixture still exercises stored-summary recovery.
        let stateURL = context.root.appendingPathComponent("grok-hook-sessions.json")
        var retainedStore = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        var retainedSessions = try XCTUnwrap(retainedStore["sessions"] as? [String: Any])
        var retainedSession = try XCTUnwrap(retainedSessions[context.sessionId] as? [String: Any])
        retainedSession["lastSubtitle"] = "Permission"
        retainedSession["lastBody"] = "Grok needs permission to run rm"
        retainedSession["lastNotificationStatus"] = "needsInput"
        retainedSessions[context.sessionId] = retainedSession
        retainedStore["sessions"] = retainedSessions
        try JSONSerialization.data(withJSONObject: retainedStore).write(to: stateURL, options: .atomic)

        let fallbackStart = context.state.snapshot().count
        let unclassified = grokUnclassifiedPayload(context)
        try runGrokNoiseHook(context, "notification", payload: unclassified)
        try runGrokNoiseHook(context, "notification", payload: unclassified)

        let fallbackCommands = Array(context.state.snapshot().dropFirst(fallbackStart))
        XCTAssertTrue(notifyCommands(in: fallbackCommands).isEmpty,
            "A stored summary must not revive the approval resolved by the new prompt")
        XCTAssertEqual(context.state.admittedNotificationKeysSnapshot(), oldAdmissionKeys,
            "Display-only fallbacks must not reserve a new notification receipt")
        XCTAssertFalse(fallbackCommands.contains { $0.hasPrefix("set_status ") },
            "Reusing display text must not resurrect prior needs-input lifecycle state")
        let candidates = fallbackCommands.compactMap(AgentHookTestNotificationPipeline.candidatePresentation)
        XCTAssertEqual(candidates.count, 2, "Both native fallback invocations should retain their display candidates")
        XCTAssertTrue(candidates.allSatisfy { $0.contains("|c=idle-reminder;p=0") })
        XCTAssertTrue(candidates.allSatisfy { $0.contains(";a=grok") })
        XCTAssertTrue(candidates.allSatisfy { $0.contains(";s=needsInput") })

        let store = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let session = try XCTUnwrap((store["sessions"] as? [String: Any])?[context.sessionId] as? [String: Any])
        XCTAssertEqual(session["runtimeStatus"] as? String, "running")
        XCTAssertNil(session["lastNotificationStatus"])

        let newRequestStart = context.state.snapshot().count
        let newRequest = grokPermissionPromptPayload(context,
            message: "Grok needs permission to run rm", requestId: "current-permission")
        try runGrokNoiseHook(context, "notification", payload: newRequest)
        try runGrokNoiseHook(context, "notification", payload: newRequest)
        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(newRequestStart)))
        XCTAssertEqual(notifications.count, 1,
            "A genuine current request must still deliver once after suppressed stored fallbacks")
        XCTAssertTrue(notifications.first?.contains("Grok|Permission|Grok needs permission to run rm") == true)
        XCTAssertTrue(notifications.first?.contains("|c=needs-permission;p=0") == true)
        XCTAssertTrue(notifications.first?.contains(";a=grok") == true)
        XCTAssertTrue(notifications.first?.contains(";s=needsInput") == true)
        XCTAssertEqual(context.state.admittedNotificationKeysSnapshot().count, 2)
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
            firstTurnNotifications.first?.contains("|c=needs-permission;p=0") == true,
            firstTurnNotifications.joined(separator: "\n")
        )

        try runGrokNoiseHook(context, "prompt-submit", payload: grokNoisePayload(context, event: "UserPromptSubmit"))
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 2, "Prompt submit should re-arm permission prompt delivery for the next turn, saw \(notifications)")
        XCTAssertTrue(notifications.allSatisfy { $0.contains("|c=needs-permission;p=0") }, notifications.joined(separator: "\n"))
        XCTAssertTrue(notifications.allSatisfy { $0.contains(";s=needsInput") }, notifications.joined(separator: "\n"))
    }

    func testGrokDistinctPermissionPromptsAlwaysDeliver() throws {
        let context = try makeGrokNoiseContext(name: "grok-distinct-permission")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokPermissionPromptPayload(context, message: "Grok needs permission to run rm", requestId: "permission-rm"))
        try runGrokNoiseHook(context, "notification", payload: grokPermissionPromptPayload(context, message: "Grok needs permission to edit config.yaml", requestId: "permission-config"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 2, "Distinct permission prompts should each deliver, saw \(notifications)")
        XCTAssertTrue(notifications.allSatisfy { $0.contains("|c=needs-permission;p=0") }, notifications.joined(separator: "\n"))
        XCTAssertTrue(notifications.allSatisfy { $0.contains(";s=needsInput") }, notifications.joined(separator: "\n"))
    }

    func testAntigravityErrorNotificationCarriesErrorSoundContext() throws {
        let context = try makeGrokNoiseContext(name: "antigravity-error", agent: "antigravity")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: antigravityNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: antigravityNoisePayload(context, event: "Notification", message: "Build failed: exit 1"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 1, "Expected one Antigravity error notification, saw \(notifications)")
        XCTAssertTrue(
            notifications.first?.contains(";a=antigravity") == true
                && notifications.first?.contains(";s=errorStalled") == true,
            "Error notifications should carry the error sound context, saw \(notifications)"
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

        startDetachedAgentHookMockServer(listenerFD: listenerFD, state: state, surfaceId: surfaceId)
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
        message: String = "Tool permission requested",
        requestId: String? = nil
    ) -> String {
        var payload = [
            "hookEventName": "notification", "sessionId": context.sessionId,
            "cwd": context.root.path, "notificationType": "permission_prompt",
            "message": message, "level": "info",
        ]
        payload["request_id"] = requestId
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
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
