import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    private final class MockSocketFulfillmentGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didFulfill = false

        func fulfill(_ expectation: XCTestExpectation) {
            lock.lock()
            defer { lock.unlock() }
            guard !didFulfill else { return }
            didFulfill = true
            expectation.fulfill()
        }
    }

    func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        startMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionCount: connectionCount,
            fulfillWhen: fulfillWhen
        ) { line in
            handler(line)
        }
    }

    func startMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli mock socket handled")
        let fulfillmentGate = MockSocketFulfillmentGate()
        for _ in 0..<max(1, connectionCount) {
            DispatchQueue.global(qos: .userInitiated).async {
                func fulfillOnce() {
                    fulfillmentGate.fulfill(handled)
                }

                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    fulfillOnce()
                    return
                }
                defer {
                    Darwin.close(clientFD)
                    fulfillOnce()
                }

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
                        if fulfillWhen?(line) == true {
                            fulfillOnce()
                        }
                        guard let responsePayload = handler(line) else { continue }
                        let response = responsePayload + "\n"
                        _ = response.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
                    }
                }
            }
        }
        return handled
    }

    func startDetachedMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        handler: @escaping @Sendable (String) -> String
    ) {
        for _ in 0..<max(1, connectionCount) {
            DispatchQueue.global(qos: .userInitiated).async {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    return
                }
                defer {
                    Darwin.close(clientFD)
                }

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
                        let response = handler(line) + "\n"
                        _ = response.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
                    }
                }
            }
        }
    }

    func startAgentHookMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        surfaceId: String,
        connectionCount: Int
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state, connectionCount: connectionCount) { line in
            self.agentHookMockResponse(line: line, surfaceId: surfaceId)
        }
    }

    func startDetachedAgentHookMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        surfaceId: String,
        connectionCount: Int
    ) {
        startDetachedMockServer(listenerFD: listenerFD, state: state, connectionCount: connectionCount) { line in
            self.agentHookMockResponse(line: line, surfaceId: surfaceId)
        }
    }

    func assertSSHPTYAttachOmitsSurfaceArgument(
        _ script: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            script.contains(#"ssh-pty-attach --wait --workspace "$cmux_ssh_pty_workspace_id" --surface"#),
            script,
            file: file,
            line: line
        )
    }

    private func agentHookMockResponse(line: String, surfaceId: String) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return surfaceListResponse(id: id, surfaceId: surfaceId)
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }
}
