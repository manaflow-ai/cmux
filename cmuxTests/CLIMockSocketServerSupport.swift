import XCTest
import Darwin

/// Coordinates mock control-socket accept loops that share a listener FD.
///
/// Many CLI tests open a *fresh* mock server for every hook invocation but reuse
/// the same bound listener FD across those invocations. Each new server must
/// supersede the previous one, otherwise a leftover accept loop lingers on the
/// shared FD and can steal the next hook's connection — fulfilling the previous
/// (already-satisfied) expectation and leaving the current one hanging until the
/// 5s wait times out.
///
/// The loops run on raw `Thread`s rather than GCD queues on purpose: a blocking
/// `accept()` parked on a GCD worker ties that worker up for the whole test, and
/// a test that spins up a server per hook quickly drains the shared GCD pool that
/// `runProcess` needs for its stdout/stderr readers and exit waiter — which then
/// looks exactly like the CLI hanging.
final class CLIMockAcceptLoopRegistry: @unchecked Sendable {
    static let shared = CLIMockAcceptLoopRegistry()

    private let lock = NSLock()
    private struct Handle { let stopWriteFD: Int32; let done: DispatchSemaphore }
    private var current: [Int32: Handle] = [:]

    /// Starts a poll-based accept loop on `listenerFD`, superseding any previous
    /// loop registered for the same FD (it is signalled to stop and joined before
    /// the new loop begins accepting). Each accepted connection is handed to its
    /// own raw thread via `onConnection`.
    func start(
        listenerFD: Int32,
        onConnection: @escaping @Sendable (Int32) -> Void,
        onListenerClosed: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        let previous = current[listenerFD]
        lock.unlock()
        if let previous {
            var one: UInt8 = 1
            _ = Darwin.write(previous.stopWriteFD, &one, 1)
            _ = previous.done.wait(timeout: .now() + 2)
        }

        var stopFDs: [Int32] = [-1, -1]
        _ = pipe(&stopFDs)
        let stopReadFD = stopFDs[0]
        let stopWriteFD = stopFDs[1]
        let done = DispatchSemaphore(value: 0)

        lock.lock()
        current[listenerFD] = Handle(stopWriteFD: stopWriteFD, done: done)
        lock.unlock()

        let thread = Thread {
            defer {
                // Deregister before closing the pipe FDs so a later server on a
                // reused FD number never writes a stop byte into an unrelated
                // descriptor.
                self.lock.lock()
                if self.current[listenerFD]?.done === done {
                    self.current[listenerFD] = nil
                }
                self.lock.unlock()
                Darwin.close(stopReadFD)
                Darwin.close(stopWriteFD)
                done.signal()
            }
            while true {
                var fds = [
                    pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stopReadFD, events: Int16(POLLIN), revents: 0),
                ]
                let ready = Darwin.poll(&fds, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    onListenerClosed()
                    return
                }
                if (fds[1].revents & Int16(POLLIN)) != 0 {
                    // Superseded by a newer server on the same FD.
                    return
                }
                let listenerEvents = fds[0].revents
                if (listenerEvents & Int16(POLLIN)) != 0 {
                    var clientAddr = sockaddr_un()
                    var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                            Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                        }
                    }
                    if clientFD < 0 {
                        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                        onListenerClosed()
                        return
                    }
                    let handlerThread = Thread { onConnection(clientFD) }
                    handlerThread.stackSize = 1 << 20
                    handlerThread.start()
                    continue
                }
                if (listenerEvents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                    onListenerClosed()
                    return
                }
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
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
            defer { lock.unlock() }
            guard !didFulfill else { return }
            didFulfill = true
            expectation.fulfill()
        }
    }

    // The bundled CLI opens a dedicated short-lived control connection for the
    // `system.top` agent-process lookup in addition to its main hook connection.
    // Headless (piped stdin/stdout with no controlling TTY) that lookup always
    // fires because caller-TTY resolution can't succeed, so every hook invocation
    // needs at least two accepted connections. Default to a small pool with margin
    // so the extra connection is always serviced instead of starving on a
    // single-accept mock.
    static let defaultMockConnectionCount = 4

    func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = CLINotifyProcessIntegrationRegressionTests.defaultMockConnectionCount,
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
        connectionCount: Int = CLINotifyProcessIntegrationRegressionTests.defaultMockConnectionCount,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> XCTestExpectation {
        // `connectionCount` is retained for source compatibility but no longer
        // caps how many connections are serviced: a single accept loop dispatches
        // every incoming connection to its own handler, so the CLI's extra
        // `system.top` control connection is always answered.
        _ = connectionCount
        let handled = expectation(description: "cli mock socket handled")
        let fulfillmentGate = MockSocketFulfillmentGate()
        CLIMockAcceptLoopRegistry.shared.start(listenerFD: listenerFD, onConnection: { clientFD in
            defer {
                Darwin.close(clientFD)
                fulfillmentGate.fulfill(handled)
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
                        fulfillmentGate.fulfill(handled)
                    }
                    guard let responsePayload = handler(line) else { continue }
                    let response = responsePayload + "\n"
                    _ = response.withCString { ptr in
                        Darwin.write(clientFD, ptr, strlen(ptr))
                    }
                }
            }
        }, onListenerClosed: {
            // Unblock the waiter if the listener is torn down before any client
            // connected (matches the previous accept-failure fulfillment).
            fulfillmentGate.fulfill(handled)
        })
        return handled
    }

    /// Runs a mock control-socket accept loop on a dedicated raw thread (NOT a GCD
    /// queue). Each accepted connection is handled on its own raw thread.
    ///
    /// This deliberately avoids `DispatchQueue.global()`: a blocking `accept()`
    /// parked on a GCD worker ties that worker up for the whole test, and a test
    /// that opens a fresh server per hook quickly exhausts the shared GCD pool —
    /// which then starves the `runProcess` stdout/stderr readers and exit waiter,
    /// making the CLI look like it hung. Raw threads keep the GCD pool free.
    static func runMockAcceptLoop(
        listenerFD: Int32,
        onConnection: @escaping @Sendable (Int32) -> Void,
        onListenerClosed: (@Sendable () -> Void)? = nil
    ) {
        let thread = Thread {
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
                    onListenerClosed?()
                    return
                }
                let handlerThread = Thread { onConnection(clientFD) }
                handlerThread.stackSize = 1 << 20
                handlerThread.start()
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    func startDetachedMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = CLINotifyProcessIntegrationRegressionTests.defaultMockConnectionCount,
        handler: @escaping @Sendable (String) -> String
    ) {
        // See `runMockAcceptLoop`: a single raw-thread accept loop services every
        // connection, so `connectionCount` no longer bounds the server.
        _ = connectionCount
        Self.runMockAcceptLoop(listenerFD: listenerFD) { clientFD in
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
                    let response = handler(line) + "\n"
                    _ = response.withCString { ptr in
                        Darwin.write(clientFD, ptr, strlen(ptr))
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
