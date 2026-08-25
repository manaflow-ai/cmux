import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testLateAnonymousHookCannotMutateReplacementOccupant() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("anonymous-occupant")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-anonymous-occupant-\(UUID().uuidString)", isDirectory: true)
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startDetachedMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 80
        ) { line in
            if line.hasPrefix("set_agent_lifecycle kiro unknown "),
               line.contains(" --require-accepted") {
                let claimCount = state.snapshot().reduce(into: 0) { count, command in
                    if command.hasPrefix("set_agent_lifecycle kiro unknown "),
                       command.contains(" --require-accepted"),
                       !command.contains(" --prepare-only") {
                        count += 1
                    }
                }
                return claimCount <= 2 ? "OK:1" : "OK:0"
            }
            return self.agentHookMockResponse(line: line, surfaceId: surfaceID)
        }

        func runKiroHook(
            _ subcommand: String,
            pid: Int,
            eventName: String,
            rawInput: String? = nil
        ) -> ProcessRunResult {
            runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "kiro", subcommand],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": workspaceID,
                    "CMUX_SURFACE_ID": surfaceID,
                    "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                    "CMUX_KIRO_PID": String(pid),
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: rawInput
                    ?? #"{"cwd":"\#(root.path)","hook_event_name":"\#(eventName)"}"#,
                timeout: 5
            )
        }

        let firstAgent = Process()
        firstAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        firstAgent.arguments = ["30"]
        let replacementAgent = Process()
        replacementAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        replacementAgent.arguments = ["30"]
        try firstAgent.run()
        try replacementAgent.run()
        defer {
            for process in [firstAgent, replacementAgent] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let firstPID = Int(firstAgent.processIdentifier)
        let replacementPID = Int(replacementAgent.processIdentifier)
        for pid in [firstPID, replacementPID] {
            let start = runKiroHook(
                "session-start",
                pid: pid,
                eventName: "SessionStart"
            )
            XCTAssertFalse(start.timedOut, start.stderr)
            XCTAssertEqual(start.status, 0, start.stderr)
            XCTAssertEqual(start.stdout, "{}\n")
        }

        let delayedStartCommandOffset = state.snapshot().count
        let delayedOlderStart = runKiroHook(
            "session-start",
            pid: firstPID,
            eventName: "SessionStart"
        )
        XCTAssertFalse(delayedOlderStart.timedOut, delayedOlderStart.stderr)
        XCTAssertEqual(delayedOlderStart.status, 0, delayedOlderStart.stderr)
        XCTAssertEqual(delayedOlderStart.stdout, "{}\n")
        let delayedStartCommands = Array(state.snapshot().dropFirst(delayedStartCommandOffset))
        let delayedClaims = delayedStartCommands.filter {
            $0.hasPrefix("set_agent_lifecycle kiro unknown ")
                && $0.contains(" --require-accepted")
        }
        XCTAssertEqual(delayedClaims.count, 1, "\(delayedStartCommands)")
        XCTAssertTrue(
            delayedClaims[0].contains("--expected-pid=\(firstPID)"),
            "The app must reject the exact older process claim: \(delayedStartCommands)"
        )
        XCTAssertFalse(
            delayedStartCommands.contains {
                $0.hasPrefix("set_agent_pid ")
                    || ($0.hasPrefix("set_agent_lifecycle ")
                        && !$0.contains(" --require-accepted"))
                    || $0.hasPrefix("set_status ")
                    || $0.hasPrefix("clear_notifications ")
                    || $0.hasPrefix("notify_target_async ")
            },
            "A rejected delayed SessionStart must not publish durable or visible state: \(delayedStartCommands)"
        )

        let lateCommandStart = state.snapshot().count
        let latePrompt = runKiroHook(
            "prompt-submit",
            pid: firstPID,
            eventName: "UserPromptSubmit"
        )
        XCTAssertFalse(latePrompt.timedOut, latePrompt.stderr)
        XCTAssertEqual(latePrompt.status, 0, latePrompt.stderr)
        XCTAssertEqual(latePrompt.stdout, "{}\n")
        let lateCommands = Array(state.snapshot().dropFirst(lateCommandStart))
        XCTAssertFalse(
            lateCommands.contains {
                $0.hasPrefix("set_agent_lifecycle ")
                    || $0.hasPrefix("set_status ")
                    || $0.hasPrefix("clear_notifications ")
                    || $0.hasPrefix("notify_target_async ")
            },
            "A late hook from the replaced anonymous process must not mutate the current occupant: \(lateCommands)"
        )

        let currentCommandStart = state.snapshot().count
        let currentPrompt = runKiroHook(
            "prompt-submit",
            pid: replacementPID,
            eventName: "UserPromptSubmit"
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.stdout, "{}\n")
        let currentCommands = Array(state.snapshot().dropFirst(currentCommandStart))
        XCTAssertTrue(
            currentCommands.contains {
                $0.hasPrefix("set_agent_lifecycle kiro running ")
                    && $0.contains("--expected-pid-key=kiro.\(surfaceID)")
                    && $0.contains("--expected-pid=\(replacementPID)")
            },
            "The current anonymous occupant must report lifecycle state with its PID token: \(currentCommands)"
        )
        XCTAssertFalse(
            currentCommands.contains { $0.hasPrefix("set_agent_pid ") },
            "Only anonymous session-start may claim PID ownership: \(currentCommands)"
        )

        let notificationCommandStart = state.snapshot().count
        let statuslessNotification = runKiroHook(
            "notification",
            pid: replacementPID,
            eventName: "Notification",
            rawInput: #"{"cwd":"\#(root.path)","hook_event_name":"Notification","message":"Review this custom alert"}"#
        )
        XCTAssertFalse(statuslessNotification.timedOut, statuslessNotification.stderr)
        XCTAssertEqual(statuslessNotification.status, 0, statuslessNotification.stderr)
        XCTAssertEqual(statuslessNotification.stdout, "{}\n")
        let notificationCommands = Array(
            state.snapshot().dropFirst(notificationCommandStart)
        )
        let ownershipIndex = try XCTUnwrap(
            notificationCommands.firstIndex {
                $0.hasPrefix("set_agent_lifecycle kiro ")
            }
        )
        let deliveryIndex = try XCTUnwrap(
            notificationCommands.firstIndex {
                $0.hasPrefix("notify_target_async ")
            }
        )
        XCTAssertLessThan(
            ownershipIndex,
            deliveryIndex,
            "An unclassified guarded notification must recover ownership before delivery: \(notificationCommands)"
        )

        let teardownCommandStart = state.snapshot().count
        let currentTeardown = runKiroHook(
            "session-end",
            pid: replacementPID,
            eventName: "SessionEnd"
        )
        XCTAssertFalse(currentTeardown.timedOut, currentTeardown.stderr)
        XCTAssertEqual(currentTeardown.status, 0, currentTeardown.stderr)
        XCTAssertEqual(currentTeardown.stdout, "{}\n")
        let teardownCommands = Array(state.snapshot().dropFirst(teardownCommandStart))
        XCTAssertTrue(
            teardownCommands.contains {
                $0.hasPrefix("clear_agent_pid kiro.\(surfaceID) ")
                    && $0.contains("--expected-pid=\(replacementPID)")
            },
            "Anonymous teardown must clear only the PID occupant it consumed: \(teardownCommands)"
        )
        XCTAssertTrue(
            teardownCommands.contains {
                guard let payload = self.jsonObject($0),
                      payload["method"] as? String == "surface.resume.clear",
                      let params = payload["params"] as? [String: Any] else {
                    return false
                }
                return (params["_cmux_expected_updated_at"] as? NSNumber)?.doubleValue == 123.25
            },
            "Anonymous teardown must compare-and-clear the binding revision it published: \(teardownCommands)"
        )
    }

    func testAnonymousStoreMutationRejectsReplacementDuringHookExecution() throws {
        let cliPath = try bundledCLIPath()
        let normalSocketPath = makeSocketPath("anonymous-cas-normal")
        let raceSocketPath = makeSocketPath("anonymous-cas-race")
        let normalListenerFD = try bindUnixSocket(at: normalSocketPath)
        let raceListenerFD = try bindUnixSocket(at: raceSocketPath)
        let normalState = MockSocketServerState()
        let raceState = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-anonymous-cas-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspaceID = "51111111-1111-1111-1111-111111111111"
        let surfaceID = "52222222-2222-2222-2222-222222222222"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let currentAgent = Process()
        currentAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        currentAgent.arguments = ["30"]
        let replacementAgent = Process()
        replacementAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        replacementAgent.arguments = ["30"]
        try currentAgent.run()
        try replacementAgent.run()
        defer {
            for process in [currentAgent, replacementAgent] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            Darwin.close(normalListenerFD)
            Darwin.close(raceListenerFD)
            unlink(normalSocketPath)
            unlink(raceSocketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startDetachedAgentHookMockServer(
            listenerFD: normalListenerFD,
            state: normalState,
            surfaceId: surfaceID,
            connectionCount: 80
        )
        let reachedPostValidationTargetResolution = DispatchSemaphore(value: 0)
        let allowStaleHookToContinue = DispatchSemaphore(value: 0)
        startDetachedMockServer(
            listenerFD: raceListenerFD,
            state: raceState,
            connectionCount: 80
        ) { line in
            if self.jsonObject(line)?["method"] as? String == "surface.list" {
                let surfaceListCount = raceState.snapshot().reduce(into: 0) { count, command in
                    if self.jsonObject(command)?["method"] as? String == "surface.list" {
                        count += 1
                    }
                }
                if surfaceListCount == 3 {
                    reachedPostValidationTargetResolution.signal()
                    _ = allowStaleHookToContinue.wait(timeout: .now() + 15)
                }
            }
            return self.agentHookMockResponse(line: line, surfaceId: surfaceID)
        }

        func environment(socketPath: String, pid: Int) -> [String: String] {
            [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_KIRO_PID": String(pid),
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
                "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS": "0",
                "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS": "0",
                "CMUX_AGENT_MANAGED_SUBAGENT": "0",
            ]
        }
        func runSessionStart(pid: Int) -> ProcessRunResult {
            runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "kiro", "session-start"],
                environment: environment(socketPath: normalSocketPath, pid: pid),
                standardInput: #"{"cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
                timeout: 5
            )
        }
        func storedRecord() throws -> [String: Any] {
            let storeURL = root.appendingPathComponent(
                "claude-hook-sessions.json",
                isDirectory: false
            )
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: storeURL))
                    as? [String: Any]
            )
            let sessions = try #require(object["sessions"] as? [String: Any])
            return try #require(sessions[surfaceID] as? [String: Any])
        }

        let currentStart = runSessionStart(pid: Int(currentAgent.processIdentifier))
        XCTAssertFalse(currentStart.timedOut, currentStart.stderr)
        XCTAssertEqual(currentStart.status, 0, currentStart.stderr)

        let staleHook = Process()
        let staleInput = Pipe()
        let staleOutput = Pipe()
        let staleError = Pipe()
        let staleHookExited = expectation(description: "stale anonymous hook exited")
        staleHook.executableURL = URL(fileURLWithPath: cliPath)
        staleHook.arguments = ["hooks", "kiro", "notification"]
        staleHook.environment = environment(
            socketPath: raceSocketPath,
            pid: Int(currentAgent.processIdentifier)
        )
        staleHook.standardInput = staleInput
        staleHook.standardOutput = staleOutput
        staleHook.standardError = staleError
        staleHook.terminationHandler = { _ in staleHookExited.fulfill() }
        try staleHook.run()
        try staleInput.fileHandleForWriting.write(
            contentsOf: Data(
                #"{"cwd":"\#(root.path)","hook_event_name":"Notification","message":"Review this custom alert"}"#.utf8
            )
        )
        try staleInput.fileHandleForWriting.close()

        guard reachedPostValidationTargetResolution.wait(timeout: .now() + 10) == .success else {
            allowStaleHookToContinue.signal()
            if staleHook.isRunning { staleHook.terminate() }
            XCTFail("The stale hook never reached post-validation target resolution: \(raceState.snapshot())")
            return
        }

        let replacementStart = runSessionStart(pid: Int(replacementAgent.processIdentifier))
        XCTAssertFalse(replacementStart.timedOut, replacementStart.stderr)
        XCTAssertEqual(replacementStart.status, 0, replacementStart.stderr)
        let replacementRecord = try storedRecord()

        allowStaleHookToContinue.signal()
        let exitResult = XCTWaiter().wait(for: [staleHookExited], timeout: 10)
        if exitResult != .completed, staleHook.isRunning {
            staleHook.terminate()
        }
        XCTAssertEqual(exitResult, .completed)
        XCTAssertEqual(staleHook.terminationStatus, 0)
        let staleStderr = String(
            data: staleError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(staleStderr, "")

        let recordAfterStaleHook = try storedRecord()
        XCTAssertEqual(
            (recordAfterStaleHook["pid"] as? NSNumber)?.intValue,
            (replacementRecord["pid"] as? NSNumber)?.intValue
        )
        XCTAssertEqual(
            (recordAfterStaleHook["pidStartSeconds"] as? NSNumber)?.int64Value,
            (replacementRecord["pidStartSeconds"] as? NSNumber)?.int64Value
        )
        XCTAssertEqual(
            (recordAfterStaleHook["pidStartMicroseconds"] as? NSNumber)?.int64Value,
            (replacementRecord["pidStartMicroseconds"] as? NSNumber)?.int64Value
        )
        XCTAssertNil(recordAfterStaleHook["lastEmittedNotificationFingerprint"])
    }

    func testAnonymousSessionStartPublishesDurableOwnerOnlyAfterAppAcceptance() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("anonymous-app-claim")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-anonymous-app-claim-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspaceID = "61111111-1111-1111-1111-111111111111"
        let surfaceID = "62222222-2222-2222-2222-222222222222"
        let reachedReplacementClaim = DispatchSemaphore(value: 0)
        let allowReplacementClaim = DispatchSemaphore(value: 0)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let currentAgent = Process()
        currentAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        currentAgent.arguments = ["30"]
        let replacementAgent = Process()
        replacementAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        replacementAgent.arguments = ["30"]
        try currentAgent.run()
        try replacementAgent.run()
        defer {
            allowReplacementClaim.signal()
            for process in [currentAgent, replacementAgent] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startDetachedMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 80
        ) { line in
            if line.hasPrefix("set_agent_lifecycle kiro unknown ") {
                let lifecycleClaims = state.snapshot().filter {
                    $0.hasPrefix("set_agent_lifecycle kiro unknown ")
                }
                if lifecycleClaims.count == 2 {
                    reachedReplacementClaim.signal()
                    _ = allowReplacementClaim.wait(timeout: .now() + 15)
                }
                return "OK:1"
            }
            return self.agentHookMockResponse(line: line, surfaceId: surfaceID)
        }

        func environment(pid: Int) -> [String: String] {
            [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_KIRO_PID": String(pid),
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
                "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS": "0",
                "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS": "0",
                "CMUX_AGENT_MANAGED_SUBAGENT": "0",
            ]
        }
        func runSessionStart(pid: Int) -> ProcessRunResult {
            runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "kiro", "session-start"],
                environment: environment(pid: pid),
                standardInput: #"{"cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
                timeout: 5
            )
        }
        func storedRecord() throws -> [String: Any] {
            let storeURL = root.appendingPathComponent(
                "claude-hook-sessions.json",
                isDirectory: false
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: storeURL))
                    as? [String: Any]
            )
            let sessions = try XCTUnwrap(object["sessions"] as? [String: Any])
            return try XCTUnwrap(sessions[surfaceID] as? [String: Any])
        }

        let currentStart = runSessionStart(pid: Int(currentAgent.processIdentifier))
        XCTAssertFalse(currentStart.timedOut, currentStart.stderr)
        XCTAssertEqual(currentStart.status, 0, currentStart.stderr)
        let currentRecord = try storedRecord()

        let replacementHook = Process()
        let replacementInput = Pipe()
        let replacementOutput = Pipe()
        let replacementError = Pipe()
        let replacementHookExited = expectation(description: "replacement anonymous hook exited")
        replacementHook.executableURL = URL(fileURLWithPath: cliPath)
        replacementHook.arguments = ["hooks", "kiro", "session-start"]
        replacementHook.environment = environment(pid: Int(replacementAgent.processIdentifier))
        replacementHook.standardInput = replacementInput
        replacementHook.standardOutput = replacementOutput
        replacementHook.standardError = replacementError
        replacementHook.terminationHandler = { _ in replacementHookExited.fulfill() }
        try replacementHook.run()
        try replacementInput.fileHandleForWriting.write(
            contentsOf: Data(
                #"{"cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#.utf8
            )
        )
        try replacementInput.fileHandleForWriting.close()

        guard reachedReplacementClaim.wait(timeout: .now() + 10) == .success else {
            if replacementHook.isRunning { replacementHook.terminate() }
            XCTFail("The replacement SessionStart never reached its app ownership claim: \(state.snapshot())")
            return
        }
        let claimCommand = try XCTUnwrap(
            state.snapshot().last { $0.hasPrefix("set_agent_lifecycle kiro unknown ") }
        )
        XCTAssertTrue(
            claimCommand.contains("--require-accepted"),
            "Anonymous SessionStart must require synchronous app ownership acceptance: \(claimCommand)"
        )

        let recordWhileClaimIsPending = try storedRecord()
        XCTAssertEqual(
            (recordWhileClaimIsPending["pid"] as? NSNumber)?.intValue,
            (currentRecord["pid"] as? NSNumber)?.intValue
        )
        XCTAssertEqual(
            (recordWhileClaimIsPending["pidStartSeconds"] as? NSNumber)?.int64Value,
            (currentRecord["pidStartSeconds"] as? NSNumber)?.int64Value
        )
        XCTAssertEqual(
            (recordWhileClaimIsPending["pidStartMicroseconds"] as? NSNumber)?.int64Value,
            (currentRecord["pidStartMicroseconds"] as? NSNumber)?.int64Value
        )

        allowReplacementClaim.signal()
        let exitResult = XCTWaiter().wait(for: [replacementHookExited], timeout: 10)
        if exitResult != .completed, replacementHook.isRunning {
            replacementHook.terminate()
        }
        XCTAssertEqual(exitResult, .completed)
        XCTAssertEqual(replacementHook.terminationStatus, 0)
        XCTAssertEqual(
            String(
                data: replacementOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ),
            "{}\n"
        )
        XCTAssertEqual(
            String(
                data: replacementError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ),
            ""
        )

        let replacementRecord = try storedRecord()
        XCTAssertEqual(
            (replacementRecord["pid"] as? NSNumber)?.intValue,
            Int(replacementAgent.processIdentifier)
        )
        XCTAssertNotEqual(
            (replacementRecord["pidStartSeconds"] as? NSNumber)?.int64Value,
            (currentRecord["pidStartSeconds"] as? NSNumber)?.int64Value
        )
    }

    func testLateRovoDevHookCannotMutateReplacementOccupantSharingInferredSessionID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rovo-occupant")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-occupant-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let workspaceID = "33333333-3333-3333-3333-333333333333"
        let surfaceID = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try writeRovoDevSessionMetadata(
            sessionsRoot: sessionsRoot,
            sessionId: "workspace-scoped-session",
            workspacePath: workspace.path,
            modified: Date(timeIntervalSince1970: 200)
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startDetachedAgentHookMockServer(
            listenerFD: listenerFD,
            state: state,
            surfaceId: surfaceID,
            connectionCount: 80
        )

        func runRovoDevHook(_ subcommand: String, pid: Int, eventName: String) -> ProcessRunResult {
            runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "rovodev", subcommand],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": workspace.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": workspaceID,
                    "CMUX_SURFACE_ID": surfaceID,
                    "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                    "CMUX_ROVODEV_SESSIONS_DIR": sessionsRoot.path,
                    "CMUX_ROVODEV_PID": String(pid),
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"cwd":"\#(workspace.path)","hook_event_name":"\#(eventName)"}"#,
                timeout: 5
            )
        }

        let firstAgent = Process()
        firstAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        firstAgent.arguments = ["30"]
        let replacementAgent = Process()
        replacementAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        replacementAgent.arguments = ["30"]
        try firstAgent.run()
        try replacementAgent.run()
        defer {
            for process in [firstAgent, replacementAgent] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let firstPID = Int(firstAgent.processIdentifier)
        let replacementPID = Int(replacementAgent.processIdentifier)
        for pid in [firstPID, replacementPID] {
            let start = runRovoDevHook(
                "session-start",
                pid: pid,
                eventName: "session_start"
            )
            XCTAssertFalse(start.timedOut, start.stderr)
            XCTAssertEqual(start.status, 0, start.stderr)
            XCTAssertEqual(start.stdout, "{}\n")
        }
        let startLifecycleCommands = state.snapshot().filter {
            $0.hasPrefix("set_agent_lifecycle rovodev unknown ")
        }
        XCTAssertEqual(startLifecycleCommands.count, 2, "\(startLifecycleCommands)")
        XCTAssertTrue(
            startLifecycleCommands.allSatisfy { $0.contains("--new-occupant") },
            "Every Rovo Dev start must rotate its anonymous occupant generation: \(startLifecycleCommands)"
        )
        XCTAssertFalse(
            startLifecycleCommands.contains { $0.contains("--session-id=") },
            "Workspace-scoped inferred Rovo Dev metadata must not become authoritative occupant identity: \(startLifecycleCommands)"
        )

        let lateCommandStart = state.snapshot().count
        let latePrompt = runRovoDevHook(
            "prompt-submit",
            pid: firstPID,
            eventName: "on_tool_permission"
        )
        XCTAssertFalse(latePrompt.timedOut, latePrompt.stderr)
        XCTAssertEqual(latePrompt.status, 0, latePrompt.stderr)
        XCTAssertEqual(latePrompt.stdout, "{}\n")
        let lateCommands = Array(state.snapshot().dropFirst(lateCommandStart))
        XCTAssertFalse(
            lateCommands.contains {
                $0.hasPrefix("set_agent_lifecycle ")
                    || $0.hasPrefix("set_status ")
                    || $0.hasPrefix("clear_notifications ")
                    || $0.hasPrefix("notify_target_async ")
            },
            "A late Rovo Dev hook sharing an inferred workspace session must not mutate the current occupant: \(lateCommands)"
        )

        let currentCommandStart = state.snapshot().count
        let currentPrompt = runRovoDevHook(
            "prompt-submit",
            pid: replacementPID,
            eventName: "on_tool_permission"
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.stdout, "{}\n")
        let currentCommands = Array(state.snapshot().dropFirst(currentCommandStart))
        XCTAssertTrue(
            currentCommands.contains {
                $0.hasPrefix("set_agent_lifecycle rovodev running ")
                    && $0.contains("--expected-pid-key=rovodev.workspace-scoped-session")
                    && $0.contains("--expected-pid=\(replacementPID)")
            },
            "The replacement Rovo Dev occupant must report lifecycle state with its PID token: \(currentCommands)"
        )
        XCTAssertFalse(
            currentCommands.contains { $0.hasPrefix("set_agent_pid ") },
            "Only anonymous Rovo Dev session-start may claim PID ownership: \(currentCommands)"
        )
    }
}
