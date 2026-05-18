import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testTopLevelLoginAliasesAuthLogin() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("auth-login")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

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

            switch method {
            case "auth.status":
                return self.v2Response(id: id, ok: true, result: ["signed_in": false])
            case "auth.begin_sign_in":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "signed_in": true,
                        "user": ["email": "dev@example.com"],
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["login"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Opening sign-in popup on the cmux web app.\nSigned in as dev@example.com.\n")
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"auth.begin_sign_in""#) },
            "Expected login alias to call auth.begin_sign_in, saw \(state.commands)"
        )
    }

    func testTopLevelLogoutAliasesAuthLogout() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("auth-logout")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

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

            switch method {
            case "auth.status":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "signed_in": true,
                        "user": ["email": "dev@example.com"],
                    ]
                )
            case "auth.sign_out":
                return self.v2Response(id: id, ok: true, result: ["signed_in": false])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["logout"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Signed out.\n")
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"auth.sign_out""#) },
            "Expected logout alias to call auth.sign_out, saw \(state.commands)"
        )
    }
}
