import XCTest
import Darwin

extension CMUXOpenCommandTests {
    func openTypedDiffSession(payload: [String: Any], cliPath: String) throws -> String {
        let source = try XCTUnwrap(payload["sessionSource"] as? [String: Any])
        let token = try XCTUnwrap(payload["capabilityToken"] as? String)
        let sidecarURL = URL(fileURLWithPath: cliPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-diff-sidecar", isDirectory: false)
        let rootURL = URL(fileURLWithPath: "/tmp/cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        let request: [String: Any] = [
            "id": "xctest-session",
            "version": 1,
            "method": "sessionOpen",
            "params": ["source": source, "capabilityToken": token],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let result = runProcess(
            executablePath: sidecarURL.path,
            arguments: ["rpc", "--root", rootURL.path, "--cmux", cliPath],
            environment: ProcessInfo.processInfo.environment,
            timeout: 15,
            stdinText: String(decoding: requestData, as: UTF8.self)
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        if let error = response["error"] as? [String: Any],
           error["code"] as? String == "emptyDiff" {
            return ""
        }
        let opened = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(opened["type"] as? String, "sessionOpened")
        let value = try XCTUnwrap(opened["value"] as? [String: Any])
        let patchRef = try XCTUnwrap(value["patch"] as? [String: Any])
        let patchID = try XCTUnwrap(patchRef["id"] as? String)
        let patchURL = try XCTUnwrap(URL(string: patchID))
        let patch = try String(
            contentsOf: rootURL.appendingPathComponent(
                patchURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ),
            encoding: .utf8
        )
        if let sessionID = value["sessionId"] as? String {
            let close: [String: Any] = [
                "id": "xctest-session-close",
                "version": 1,
                "method": "sessionClose",
                "params": ["sessionId": sessionID, "capabilityToken": token],
            ]
            if let closeData = try? JSONSerialization.data(withJSONObject: close) {
                _ = runProcess(
                    executablePath: sidecarURL.path,
                    arguments: ["rpc", "--root", rootURL.path, "--cmux", cliPath],
                    environment: ProcessInfo.processInfo.environment,
                    timeout: 15,
                    stdinText: String(decoding: closeData, as: UTF8.self)
                )
            }
        }
        return patch
    }

    func resolvedDiffViewerHTMLFileURL(_ fileURL: URL, from params: [String: Any]) throws -> URL {
        var current = fileURL
        for _ in 0..<4 {
            let html = try String(contentsOf: current, encoding: .utf8)
            guard let redirectURL = Self.diffViewerRedirectURL(from: html) else {
                return current
            }
            current = try diffViewerHTMLFileURL(for: redirectURL, from: params)
        }
        return current
    }

    private static func diffViewerRedirectURL(from html: String) -> String? {
        let marker = "data-cmux-diff-redirect=\""
        guard let start = html.range(of: marker)?.upperBound else { return nil }
        let tail = html[start...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

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
