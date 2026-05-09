import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testIOSDefaultCommandEnablesMobileSync() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ios-enable")
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

            XCTAssertEqual(method, "mobile_sync.enable")
            return self.v2Response(
                id: id,
                ok: true,
                result: self.iosStatusPayload(
                    enabled: true,
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
            arguments: ["ios"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            """
            Mobile Sync: enabled
            Listener: stopped
            Tailscale: available (100.64.1.2)
            Workspaces: 2
            Terminals: 3
            Active attachments: 0

            """
        )
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"mobile_sync.enable""#) },
            "Expected ios to call mobile_sync.enable, saw \(state.commands)"
        )
    }

    func testIOSOffDisablesMobileSync() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ios-disable")
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

            XCTAssertEqual(method, "mobile_sync.disable")
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
            arguments: ["ios", "off"],
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
            state.commands.contains { $0.contains(#""method":"mobile_sync.disable""#) },
            "Expected ios off to call mobile_sync.disable, saw \(state.commands)"
        )
    }

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

    func testIOSStatusRendersPairingQRCodeWhenURLIsAvailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ios-qr")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let pairingURL = "cmux-ios://pair?v=1&payload=test"

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
                    enabled: true,
                    listenerState: "listening",
                    tailscaleAvailable: true,
                    selectedAddress: "100.64.1.2",
                    listenerHost: "100.64.1.2",
                    listenerPort: 49152,
                    pairingURL: pairingURL
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
        XCTAssertTrue(result.stdout.contains("Endpoint: 100.64.1.2:49152 (Tailscale)\n"))
        XCTAssertTrue(result.stdout.contains("Pairing QR:\n"))
        XCTAssertTrue(result.stdout.contains("██"))
        XCTAssertTrue(result.stdout.contains("Pairing URL: \(pairingURL)\n"))
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
        selectedAddress: String?,
        listenerHost: String? = nil,
        listenerPort: Int? = nil,
        debugLoopback: Bool = false,
        pairingURL: String? = nil
    ) -> [String: Any] {
        let selectedAddressValue: Any = selectedAddress.map { $0 as Any } ?? NSNull()
        let addresses: [[String: Any]] = selectedAddress.map {
            [["interface": "utun4", "address": $0, "kind": "ipv4"]]
        } ?? []
        let hostValue: Any = listenerHost.map { $0 as Any } ?? NSNull()
        let portValue: Any = listenerPort.map { $0 as Any } ?? NSNull()
        let pairingValue: Any = pairingURL.map { $0 as Any } ?? NSNull()
        return [
            "enabled": enabled,
            "listener": [
                "state": listenerState,
                "host": hostValue,
                "port": portValue,
                "debug_loopback": debugLoopback,
            ],
            "pairing_url": pairingValue,
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
