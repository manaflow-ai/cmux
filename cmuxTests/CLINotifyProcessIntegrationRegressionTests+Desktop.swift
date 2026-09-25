import Darwin
import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    /// `cmux notify --desktop false` must reach the app as a `desktop: false`
    /// field on the create request, and the flag must stay absent when the
    /// caller did not pass it, so the app keeps its policy default.
    func testNotifyDesktopFlagTravelsOnTheCreateRequest() throws {
        let socketPath = makeSocketPath("desktop")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        startNotifyMockServer(listenerFD: listenerFD, state: state)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let cliPath = try bundledCLIPath()

        let disabled = runNotify(cliPath: cliPath, socketPath: socketPath, arguments: ["--title", "Panel only", "--desktop", "false"])
        XCTAssertEqual(disabled.status, 0, disabled.stderr + disabled.stdout)
        let disabledRequest = try XCTUnwrap(createRequests(in: state).last, "no notification.create* request was sent")
        XCTAssertEqual(disabledRequest["desktop"] as? Bool, false)
        XCTAssertEqual(disabledRequest["title"] as? String, "Panel only")

        let inline = runNotify(cliPath: cliPath, socketPath: socketPath, arguments: ["--title", "Inline", "--desktop=true"])
        XCTAssertEqual(inline.status, 0, inline.stderr + inline.stdout)
        let inlineRequest = try XCTUnwrap(createRequests(in: state).last)
        XCTAssertEqual(inlineRequest["desktop"] as? Bool, true)

        let unchanged = runNotify(cliPath: cliPath, socketPath: socketPath, arguments: ["--title", "Default"])
        XCTAssertEqual(unchanged.status, 0, unchanged.stderr + unchanged.stdout)
        let defaultRequest = try XCTUnwrap(createRequests(in: state).last)
        XCTAssertEqual(defaultRequest["title"] as? String, "Default")
        XCTAssertNil(defaultRequest["desktop"], "an absent flag must not send a desktop field")

        let requestsBeforeRejection = createRequests(in: state).count
        let rejected = runNotify(cliPath: cliPath, socketPath: socketPath, arguments: ["--title", "Bad", "--desktop", "maybe"])
        XCTAssertNotEqual(rejected.status, 0, "an unrecognizable --desktop value must be a usage error")
        XCTAssertTrue(rejected.stderr.contains("true or false"), rejected.stderr)
        XCTAssertEqual(createRequests(in: state).count, requestsBeforeRejection, "a rejected flag must not post anything")
    }

    private func runNotify(cliPath: String, socketPath: String, arguments: [String]) -> ProcessRunResult {
        runProcess(
            executablePath: cliPath,
            arguments: ["notify"] + arguments,
            environment: [
                "HOME": NSTemporaryDirectory(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 10
        )
    }

    /// The `params` of every `notification.create*` request the CLI sent, in order.
    private func createRequests(in state: MockSocketServerState) -> [[String: Any]] {
        state.snapshot().compactMap { line -> [String: Any]? in
            guard let payload = jsonObject(line),
                  let method = payload["method"] as? String,
                  method.hasPrefix("notification.create") else { return nil }
            return payload["params"] as? [String: Any] ?? [:]
        }
    }

    /// Accepts connections until the listener closes and answers every v2 request
    /// with a success payload, recording each request line.
    private func startNotifyMockServer(listenerFD: Int32, state: MockSocketServerState) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { Darwin.close(clientFD) }
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        if count == 0 { return }
                        pending.append(buffer, count: count)
                        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                            pending.removeSubrange(0...newlineRange.lowerBound)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            state.append(line)
                            let response = notifyMockResponse(line: line) + "\n"
                            _ = response.withCString { ptr in
                                Darwin.write(clientFD, ptr, strlen(ptr))
                            }
                        }
                    }
                }
            }
        }
    }

    private func notifyMockResponse(line: String) -> String {
        guard let payload = jsonObject(line) else { return "OK" }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        if method.hasPrefix("notification.create") {
            return v2Response(id: id, ok: true, result: [
                "workspace_id": "11111111-1111-1111-1111-111111111111",
                "surface_id": "22222222-2222-2222-2222-222222222222",
                "id": "33333333-3333-3333-3333-333333333333",
            ])
        }
        return v2Response(id: id, ok: true, result: [:])
    }
}
