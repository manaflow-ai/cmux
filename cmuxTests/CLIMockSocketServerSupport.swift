import XCTest
import Darwin
import Dispatch

final class MockSocketServerToken: @unchecked Sendable {
    private let lifetime: MockSocketServerLifetime

    fileprivate init(lifetime: MockSocketServerLifetime) {
        self.lifetime = lifetime
    }

    func shutdown() {
        lifetime.shutdownAndWait()
    }

    deinit {
        shutdown()
    }
}

private final class MockSocketServerLifetime: @unchecked Sendable {
    private struct Storage {
        var listenerFD: Int32
        var clientFDs: Set<Int32> = []
        var stopped = false
    }

    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var storage: Storage

    init(duplicating listenerFD: Int32) {
        storage = Storage(listenerFD: Darwin.dup(listenerFD))
    }

    func beginAcceptLoop() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard !storage.stopped, storage.listenerFD >= 0 else { return nil }
        workers.enter()
        return storage.listenerFD
    }

    func finishAcceptLoop(listenerFD: Int32) {
        var fdToClose: Int32 = -1
        lock.lock()
        if storage.listenerFD == listenerFD {
            storage.listenerFD = -1
            fdToClose = listenerFD
        }
        lock.unlock()

        if fdToClose >= 0 {
            Darwin.close(fdToClose)
        }
        workers.leave()
    }

    func beginClient(_ clientFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !storage.stopped else { return false }
        storage.clientFDs.insert(clientFD)
        workers.enter()
        return true
    }

    func finishClient(_ clientFD: Int32) {
        lock.lock()
        storage.clientFDs.remove(clientFD)
        lock.unlock()
        workers.leave()
    }

    func shutdownAndWait() {
        let listenerFD: Int32
        let clientFDs: [Int32]

        lock.lock()
        if storage.stopped {
            listenerFD = -1
            clientFDs = []
        } else {
            storage.stopped = true
            listenerFD = storage.listenerFD
            storage.listenerFD = -1
            clientFDs = Array(storage.clientFDs)
        }
        lock.unlock()

        if listenerFD >= 0 {
            Darwin.shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
        }
        for clientFD in clientFDs {
            Darwin.shutdown(clientFD, SHUT_RDWR)
        }
        workers.wait()
    }
}

private final class MockSocketServerExpectation: XCTestExpectation, @unchecked Sendable {
    var serverToken: MockSocketServerToken?

    deinit {
        serverToken?.shutdown()
    }
}

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
            guard !didFulfill else {
                lock.unlock()
                return
            }
            didFulfill = true
            lock.unlock()
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
        let handled = MockSocketServerExpectation(description: "cli mock socket handled")
        let fulfillmentGate = MockSocketFulfillmentGate()
        let token = startScopedMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: connectionCount,
            fulfillWhen: fulfillWhen,
            fulfillOnce: { [weak handled] in
                guard let handled else { return }
                fulfillmentGate.fulfill(handled)
            },
            handler: handler
        )
        handled.serverToken = token
        return handled
    }

    private func startScopedMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int,
        fulfillWhen: (@Sendable (String) -> Bool)?,
        fulfillOnce: @escaping @Sendable () -> Void,
        handler: @escaping @Sendable (String) -> String?
    ) -> MockSocketServerToken {
        let lifetime = MockSocketServerLifetime(duplicating: listenerFD)
        let token = MockSocketServerToken(lifetime: lifetime)
        guard let ownedListenerFD = lifetime.beginAcceptLoop() else {
            XCTFail("Could not duplicate CLI mock socket listener: \(String(cString: strerror(errno)))")
            return token
        }

        Thread.detachNewThread {
            defer { lifetime.finishAcceptLoop(listenerFD: ownedListenerFD) }
            var acceptedConnections = 0
            while acceptedConnections < max(1, connectionCount) {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(ownedListenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0, errno == EINTR {
                    continue
                }
                guard clientFD >= 0 else {
                    fulfillOnce()
                    return
                }
                guard lifetime.beginClient(clientFD) else {
                    Darwin.close(clientFD)
                    return
                }
                acceptedConnections += 1

                Thread.detachNewThread {
                    Self.handleMockSocketClient(
                        clientFD: clientFD,
                        lifetime: lifetime,
                        state: state,
                        fulfillWhen: fulfillWhen,
                        fulfillOnce: fulfillOnce,
                        handler: handler
                    )
                }
            }
        }
        return token
    }

    func startDetachedMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        handler: @escaping @Sendable (String) -> String
    ) -> MockSocketServerToken {
        startDetachedMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionCount: connectionCount
        ) { line in
            handler(line)
        }
    }

    func startDetachedMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        handler: @escaping @Sendable (String) -> String?
    ) -> MockSocketServerToken {
        startScopedMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: connectionCount,
            fulfillWhen: nil,
            fulfillOnce: {},
            handler: handler
        )
    }

    private static func handleMockSocketClient(
        clientFD: Int32,
        lifetime: MockSocketServerLifetime,
        state: MockSocketServerState,
        fulfillWhen: (@Sendable (String) -> Bool)?,
        fulfillOnce: @escaping @Sendable () -> Void,
        handler: @escaping @Sendable (String) -> String?
    ) {
        defer {
            Darwin.close(clientFD)
            lifetime.finishClient(clientFD)
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
    ) -> MockSocketServerToken {
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
