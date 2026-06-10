import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Window flag surface commands
extension CLINotifyProcessIntegrationRegressionTests {
    func testReorderSurfaceWindowFlagRejectsSurfaceFromOtherWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("surface-other-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let targetWindowId = "11111111-1111-1111-1111-111111111111"
        let targetWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let targetSurfaceId = "33333333-3333-3333-3333-333333333333"
        let otherSurfaceId = "44444444-4444-4444-4444-444444444444"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.list":
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": targetWorkspaceId,
                                "ref": "workspace:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "surface.list":
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
                XCTAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": targetSurfaceId,
                                "ref": "surface:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["reorder-surface", "--window", targetWindowId, "--surface", otherSurfaceId, "--index", "0"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Surface not found in window"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "surface.list"]
        )
    }

    func testMoveSurfaceWindowFlagKeepsIndexedSourceInCallerContext() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("move-surface-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let targetWindowId = "11111111-1111-1111-1111-111111111111"
        let sourceSurfaceId = "22222222-2222-2222-2222-222222222222"
        let targetWorkspaceId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "surface.list":
                XCTAssertNil(params["window_id"])
                XCTAssertNil(params["workspace_id"])
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": sourceSurfaceId,
                                "ref": "surface:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "surface.move":
                XCTAssertEqual(params["surface_id"] as? String, sourceSurfaceId)
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
                XCTAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surface_id": sourceSurfaceId,
                        "window_id": targetWindowId,
                        "workspace_id": targetWorkspaceId,
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["move-surface", "--surface", "0", "--workspace", targetWorkspaceId, "--window", targetWindowId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["surface.list", "surface.move"]
        )
    }

    func testMoveSurfaceWindowFlagAllowsSourceSurfaceRefFromOtherWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("move-surface-cross-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let targetWindowId = "11111111-1111-1111-1111-111111111111"
        let sourceSurfaceRef = "surface:1"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            guard method == "surface.move" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            XCTAssertEqual(params["surface_id"] as? String, sourceSurfaceRef)
            XCTAssertEqual(params["window_id"] as? String, targetWindowId)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "surface_ref": sourceSurfaceRef,
                    "window_id": targetWindowId,
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["move-surface", "--surface", sourceSurfaceRef, "--window", targetWindowId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["surface.move"]
        )
    }

}
