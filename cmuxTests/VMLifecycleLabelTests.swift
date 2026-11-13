import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testVMLifecycleResolvesDisplayNameAfterBackendNotFound() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-resume-display-name")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let displayName = "probe-a"
        let vmID = "4be0afa3ef3fd95e026fe9ce10e48eb2"

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
            case "vm.resume":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["id"] as? String == displayName {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: [
                            "code": "backend_error",
                            "message": "The requested Cloud VM was not found.",
                            "data": ["backend_code": "vm_not_found", "http_status": 404],
                        ]
                    )
                }
                XCTAssertEqual(params["id"] as? String, vmID)
                return self.v2Response(id: id, ok: true, result: ["id": vmID, "status": "running"])
            case "vm.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "vms": [[
                            "id": vmID,
                            "displayName": displayName,
                            "slug": "sleepy-teal-otter",
                            "status": "paused",
                            "provider": "freestyle",
                            "image": "snapshot-default",
                        ]]
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
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "resume", displayName],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("probe-a resumed (status=running)"), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.resume", "vm.list", "vm.resume"]
        )
    }
}
