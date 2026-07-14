import Darwin
import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testWorkspaceCreateForwardsRepeatableTemplateParametersAndResolvesCommand() throws {
        let socketPath = makeSocketPath("workspace-template")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let state = MockSocketServerState()
        let handled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { line in
                self.jsonObject(line)?["method"] as? String == "surface.send_text"
            }
        ) { line in
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return "OK"
            }
            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_ref": "workspace:9"]
                )
            case "surface.send_text":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        var environment = workspaceTemplateCLIEnvironment(socketPath: socketPath)
        environment["apiPort"] = "4100"
        let result = runProcess(
            executablePath: try bundledCLIPath(),
            arguments: [
                "workspace", "create",
                "--name", "Dev {{ticket}}",
                "--command", "api --ticket {{ticket}} --port {{apiPort}}",
                "--param", "ticket=FIRST",
                "--param=ticket=BERKS-87",
                "--param", "apiPort",
                "--focus", "false",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [handled], timeout: processTimeout(5))
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let requests = state.snapshot().compactMap(jsonObject)
        let create = try XCTUnwrap(requests.first { $0["method"] as? String == "workspace.create" })
        let createParams = try XCTUnwrap(create["params"] as? [String: Any])
        XCTAssertEqual(createParams["title"] as? String, "Dev {{ticket}}")
        XCTAssertEqual(createParams["focus"] as? Bool, false)
        XCTAssertEqual(
            createParams["template_params"] as? [String: String],
            ["ticket": "BERKS-87", "apiPort": "4100"]
        )

        let send = try XCTUnwrap(requests.first { $0["method"] as? String == "surface.send_text" })
        let sendParams = try XCTUnwrap(send["params"] as? [String: Any])
        XCTAssertEqual(sendParams["workspace_id"] as? String, "workspace:9")
        XCTAssertEqual(sendParams["text"] as? String, "api --ticket BERKS-87 --port 4100\r")
    }

    func testLayoutOpenForwardsTemplateParametersWithoutFocus() throws {
        let socketPath = makeSocketPath("layout-template")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let state = MockSocketServerState()
        let handled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return "OK"
            }
            guard method == "layout.open" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: ["workspace_ref": "workspace:4"]
            )
        }

        let result = runProcess(
            executablePath: try bundledCLIPath(),
            arguments: [
                "layout", "open", "Ticket Dev",
                "--param", "ticket=BERKS-87",
                "--param", "vitePort=5174",
                "--focus", "false",
            ],
            environment: workspaceTemplateCLIEnvironment(socketPath: socketPath),
            timeout: 5
        )

        wait(for: [handled], timeout: processTimeout(5))
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let request = try XCTUnwrap(state.snapshot().compactMap(jsonObject).first)
        XCTAssertEqual(request["method"] as? String, "layout.open")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["focus"] as? Bool, false)
        XCTAssertEqual(
            params["template_params"] as? [String: String],
            ["ticket": "BERKS-87", "vitePort": "5174"]
        )
    }

    func testWorkspaceTemplateParameterRejectsInvalidNameBeforeSocketMutation() throws {
        let socketPath = makeSocketPath("invalid-template")
        let result = runProcess(
            executablePath: try bundledCLIPath(),
            arguments: ["workspace", "create", "--param", "bad.name=value"],
            environment: workspaceTemplateCLIEnvironment(socketPath: socketPath),
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("invalid template parameter name 'bad.name'"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testWorkspaceTemplateParameterImportsMustExist() throws {
        let socketPath = makeSocketPath("missing-template")
        var environment = workspaceTemplateCLIEnvironment(socketPath: socketPath)
        environment.removeValue(forKey: "CMUX_PARAMETER_THAT_IS_NOT_SET")
        let result = runProcess(
            executablePath: try bundledCLIPath(),
            arguments: ["workspace", "create", "--param", "CMUX_PARAMETER_THAT_IS_NOT_SET"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("could not import an unset environment variable"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    private func workspaceTemplateCLIEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"
        return environment
    }
}
