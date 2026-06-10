import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Notification CLI
extension CLINotifyProcessIntegrationRegressionTests {
    @MainActor
    func testNotifyWithUUIDSurfaceDoesNotRequireCallerWorkspaceOrWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-uuid-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerWorkspace = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                guard method == "notification.create" else {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                    )
                }

                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertNil(params["workspace_id"], "surface UUIDs should not be constrained to the caller workspace")
                XCTAssertNil(params["window_id"], "surface UUIDs should not require an explicit window")
                XCTAssertEqual(params["surface_id"] as? String, callerSurface)
                XCTAssertEqual(params["body"] as? String, "Body")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": callerWorkspace, "surface_id": callerSurface]
                )
            }

            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = callerWorkspace
        environment["CMUX_SURFACE_ID"] = callerSurface
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--surface", callerSurface, "--title", "UUID", "--body", "Body"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create\"") },
            "Expected notify to use single-call UUID notification path, saw \(state.commands)"
        )
    }

    func testNotificationCLIActionsUseSocketAPIAndParseExtendedFields() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notif-actions")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let notificationId = UUID().uuidString
        let workspaceId = UUID().uuidString
        let surfaceId = UUID().uuidString
        let openNotificationId = UUID().uuidString
        let openWorkspaceId = UUID().uuidString
        let openSurfaceId = UUID().uuidString
        let jumpNotificationId = UUID().uuidString

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        func run(
            _ arguments: [String],
            handler: @escaping @Sendable (String) -> String
        ) -> ProcessRunResult {
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state, handler: handler)
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["--socket", socketPath] + arguments,
                environment: environment,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        var result = run(["list-notifications", "--json", "--id-format", "uuids"]) { line in
            guard line == "list_notifications" else {
                return "ERROR: Unexpected command \(line)"
            }
            return "0:\(notificationId)|\(workspaceId)|\(surfaceId)|unread|List Fields|cli-test|body|2026-01-01T00:00:00Z|pct:CLI%7CNotification Workspace"
        }
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        var rows = try notificationRows(from: result.stdout)
        var row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == notificationId }))
        XCTAssertEqual(row["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(row["surface_id"] as? String, surfaceId)
        XCTAssertEqual(row["created_at"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(row["tab_title"] as? String, "CLI|Notification Workspace")

        result = run(["--json", "list-notifications", "--id-format", "uuids"]) { line in
            guard line == "list_notifications" else {
                return "ERROR: Unexpected command \(line)"
            }
            return "0:\(notificationId)|\(workspaceId)|\(surfaceId)|unread|List Fields|cli-test|body|2026-01-01T00:00:00Z|pct:CLI%7CNotification Workspace"
        }
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        rows = try notificationRows(from: result.stdout)
        row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == notificationId }))
        XCTAssertEqual(row["created_at"] as? String, "2026-01-01T00:00:00Z")

        result = run(["mark-notification-read", "--id", notificationId, "--json", "--id-format", "uuids"]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "notification.mark_read")
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["id"] as? String, notificationId)
            return self.v2Response(id: id, ok: true, result: ["marked_read": 1, "id": notificationId])
        }
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let markByIdPayload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(markByIdPayload["marked_read"] as? Int, 1)
        XCTAssertEqual(markByIdPayload["id"] as? String, notificationId)

        result = run(["dismiss-notification", "--all-read", "--json", "--id-format", "uuids"]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "notification.dismiss")
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["all_read"] as? Bool, true)
            return self.v2Response(id: id, ok: true, result: ["dismissed": 1, "all_read": true])
        }
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let dismissPayload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(dismissPayload["dismissed"] as? Int, 1)
        XCTAssertEqual(dismissPayload["all_read"] as? Bool, true)

        result = run([
            "mark-notification-read",
            "--workspace", workspaceId,
            "--surface", surfaceId,
            "--json",
            "--id-format",
            "uuids",
        ]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "notification.mark_read")
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["tab_id"] as? String, workspaceId)
            XCTAssertEqual(params["surface_id"] as? String, surfaceId)
            return self.v2Response(
                id: id,
                ok: true,
                result: ["marked_read": 1, "workspace_id": workspaceId, "surface_id": surfaceId]
            )
        }
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let markScopedPayload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(markScopedPayload["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(markScopedPayload["surface_id"] as? String, surfaceId)

        result = run(["open-notification", "--id", openNotificationId, "--json", "--id-format", "uuids"]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "notification.open")
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["id"] as? String, openNotificationId)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "id": openNotificationId,
                    "workspace_id": openWorkspaceId,
                    "surface_id": openSurfaceId,
                    "opened": true,
                    "is_read": true,
                ]
            )
        }
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let openPayload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(openPayload["workspace_id"] as? String, openWorkspaceId)
        XCTAssertEqual(openPayload["surface_id"] as? String, openSurfaceId)
        XCTAssertEqual(openPayload["is_read"] as? Bool, true)

        result = run(["jump-to-unread", "--json", "--id-format", "uuids"]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "notification.jump_to_unread")
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertTrue(params.isEmpty, "jump-to-unread should not send selector params")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "id": jumpNotificationId,
                    "workspace_id": openWorkspaceId,
                    "surface_id": openSurfaceId,
                    "opened": true,
                    "is_read": true,
                ]
            )
        }
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let jumpPayload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(jumpPayload["id"] as? String, jumpNotificationId)
        XCTAssertEqual(jumpPayload["workspace_id"] as? String, openWorkspaceId)
        XCTAssertEqual(jumpPayload["surface_id"] as? String, openSurfaceId)
        XCTAssertEqual(jumpPayload["is_read"] as? Bool, true)

        let methods = state.snapshot().map { command -> String in
            if command == "list_notifications" {
                return command
            }
            return self.jsonObject(command)?["method"] as? String ?? "invalid"
        }
        XCTAssertEqual(
            methods,
            [
                "list_notifications",
                "list_notifications",
                "notification.mark_read",
                "notification.dismiss",
                "notification.mark_read",
                "notification.open",
                "notification.jump_to_unread",
            ]
        )
    }

    func testListNotificationsKeepsOldServerPipeBodiesAsBody() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notif-old-pipe")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let notificationId = UUID().uuidString
        let workspaceId = UUID().uuidString

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard line == "list_notifications" else {
                return "ERROR: Unexpected command \(line)"
            }
            return "0:\(notificationId)|\(workspaceId)|none|unread|Legacy|Pipe|alpha|beta|gamma"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "list-notifications", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let rows = try notificationRows(from: result.stdout)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["id"] as? String, notificationId)
        XCTAssertEqual(row["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(row["body"] as? String, "alpha|beta|gamma")
        XCTAssertTrue(row["created_at"] is NSNull)
        XCTAssertTrue(row["tab_title"] is NSNull)
    }

    private func notificationRows(from stdout: String) throws -> [[String: Any]] {
        let data = Data(stdout.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]],
            "Expected notification JSON array, got: \(stdout)"
        )
    }

}
