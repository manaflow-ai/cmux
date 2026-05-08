import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testIOSStatusRendersDisabledProductionSafeStatus() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ios-status")
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

            XCTAssertEqual(method, "mobile_sync.status")
            return self.v2Response(
                id: id,
                ok: true,
                result: self.iosStatusPayload(
                    enabled: false,
                    listenerState: "stopped",
                    tailscaleAvailable: false,
                    selectedAddress: nil
                )
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ios", "status"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            """
            Mobile Sync: disabled
            Listener: stopped
            Tailscale: unavailable
            Workspaces: 2
            Terminals: 3
            Active attachments: 0

            """
        )
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"mobile_sync.status""#) },
            "Expected ios status to call mobile_sync.status, saw \(state.commands)"
        )
    }

    func testIOSStatusJSONForwardsSocketPayload() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ios-json")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: self.iosStatusPayload(
                    enabled: false,
                    listenerState: "stopped",
                    tailscaleAvailable: true,
                    selectedAddress: "100.64.1.2"
                )
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "ios", "status"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = try XCTUnwrap(jsonObject(result.stdout))
        XCTAssertEqual(output["enabled"] as? Bool, false)
        let tailscale = try XCTUnwrap(output["tailscale"] as? [String: Any])
        XCTAssertEqual(tailscale["available"] as? Bool, true)
        XCTAssertEqual(tailscale["selected_address"] as? String, "100.64.1.2")
    }

    private func iosStatusPayload(
        enabled: Bool,
        listenerState: String,
        tailscaleAvailable: Bool,
        selectedAddress: String?
    ) -> [String: Any] {
        let selectedAddressValue: Any = selectedAddress.map { $0 as Any } ?? NSNull()
        let addresses: [[String: Any]] = selectedAddress.map {
            [["interface": "utun4", "address": $0, "kind": "ipv4"]]
        } ?? []
        return [
            "enabled": enabled,
            "listener": ["state": listenerState],
            "tailscale": [
                "available": tailscaleAvailable,
                "selected_address": selectedAddressValue,
                "addresses": addresses,
            ],
            "workspace_count": 2,
            "terminal_count": 3,
            "active_attachment_count": 0,
        ]
    }
}
