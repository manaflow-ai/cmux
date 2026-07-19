import XCTest
import Darwin

/// A one-shot latch, safe to race on from several mock-server threads.
///
/// Mock servers answer more than one connection per hook, but the test waits on a
/// single expectation, so exactly one of those threads may signal it.
final class CLIMockOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }

    /// Fulfills `expectation` on the first call and ignores every later one.
    func fulfill(_ expectation: XCTestExpectation) {
        guard claim() else { return }
        expectation.fulfill()
    }
}

/// Reads newline-framed requests from `clientFD` and writes back each response
/// `respond` returns, until the peer closes the connection or a write fails.
/// Returning nil from `respond` consumes the request without answering it.
///
/// The caller owns `clientFD` and is responsible for closing it.
func cliMockServeLineFramedConnection(
    clientFD: Int32,
    respond: (String) -> String?
) {
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
            guard let responsePayload = respond(line) else { continue }
            guard cliMockWriteAll(responsePayload + "\n", to: clientFD) else { return }
        }
    }
}

/// Writes `string` to `fd` in full, retrying short writes and interrupted or
/// would-block writes. Returns false once the peer is gone.
func cliMockWriteAll(_ string: String, to fd: Int32) -> Bool {
    let bytes = Array(string.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
        }
        if written > 0 {
            offset += written
            continue
        }
        if written == 0 { return false }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        return false
    }
    return true
}

/// Owns the mock control-socket accept loops, keyed by listener FD.
///
/// Many CLI tests open a *fresh* mock server for every hook invocation while
/// reusing one bound listener FD. Each new server must supersede the previous one,
/// otherwise a leftover accept loop lingers on the shared FD and can steal the
/// next hook's connection — fulfilling the previous (already-satisfied)
/// expectation and leaving the current one hanging until its 5s wait times out.
///
/// The loops run on raw `Thread`s rather than GCD queues on purpose: a blocking
/// accept parked on a GCD worker ties that worker up for the whole test, and a
/// test that spins up a server per hook quickly drains the shared GCD pool that
/// `runProcess` needs for its stdout/stderr readers and exit waiter — which then
/// looks exactly like the CLI hanging.
///
/// Each loop waits on both its listener FD and a private stop pipe, because
/// closing a descriptor does not wake a thread already parked in `poll`/`accept`
/// on Darwin. Without the stop pipe a loop would block until the test process
/// exits, leaking its thread. Call ``stopAll(file:line:)`` from test teardown.
final class CLIMockAcceptLoopRegistry: @unchecked Sendable {
    static let shared = CLIMockAcceptLoopRegistry()

    private final class Loop {
        let stopReadFD: Int32
        let stopWriteFD: Int32
        let done = DispatchSemaphore(value: 0)

        init(stopReadFD: Int32, stopWriteFD: Int32) {
            self.stopReadFD = stopReadFD
            self.stopWriteFD = stopWriteFD
        }
    }

    /// Guards `loops` and serializes whole start/stop sequences so two concurrent
    /// starts on one FD can't both observe the same predecessor and then both run
    /// (two loops on one listener is exactly the connection-stealing bug). Loop
    /// threads never take this lock — they only signal `done` — so holding it
    /// across the stop-and-join cannot deadlock.
    private let lock = NSLock()
    private var loops: [Int32: Loop] = [:]

    /// Starts a poll-based accept loop on `listenerFD`, superseding any loop
    /// already registered for that FD (the old loop is signalled and joined before
    /// the new one starts accepting). Each accepted connection is handed to its own
    /// raw thread via `onConnection`, which owns and must close that FD.
    func start(
        listenerFD: Int32,
        onConnection: @escaping @Sendable (Int32) -> Void,
        onListenerClosed: @escaping @Sendable () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        lock.lock()
        defer { lock.unlock() }

        retireLoopLocked(listenerFD: listenerFD, file: file, line: line)

        var stopFDs: [Int32] = [-1, -1]
        guard pipe(&stopFDs) == 0 else {
            // Without a stop pipe the loop could never be superseded or reaped, so
            // starting one would reintroduce the stealing bug and leak a thread.
            XCTFail(
                "Failed to create mock server stop pipe: \(String(cString: strerror(errno)))",
                file: file,
                line: line
            )
            return
        }
        let loop = Loop(stopReadFD: stopFDs[0], stopWriteFD: stopFDs[1])
        loops[listenerFD] = loop

        let thread = Thread {
            defer { loop.done.signal() }
            while true {
                var fds = [
                    pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: loop.stopReadFD, events: Int16(POLLIN), revents: 0),
                ]
                let ready = Darwin.poll(&fds, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    onListenerClosed()
                    return
                }
                if (fds[1].revents & Int16(POLLIN)) != 0 {
                    // Superseded, or reaped at teardown.
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

    /// Stops and joins the loop registered for `listenerFD`, if any.
    func stop(listenerFD: Int32, file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        defer { lock.unlock() }
        retireLoopLocked(listenerFD: listenerFD, file: file, line: line)
    }

    /// Stops and joins every registered loop. Call from test teardown so no accept
    /// thread outlives the test that started it.
    func stopAll(file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        defer { lock.unlock() }
        // Snapshot the keys: retiring a loop removes it from `loops`.
        for listenerFD in Array(loops.keys) {
            retireLoopLocked(listenerFD: listenerFD, file: file, line: line)
        }
    }

    /// Signals the loop to exit, waits for it, then closes its stop pipe. The
    /// registry owns the pipe FDs for the loop's whole life: the loop never closes
    /// them, so a stop byte can never land in an unrelated descriptor that reused
    /// the number. Must be called with `lock` held.
    private func retireLoopLocked(listenerFD: Int32, file: StaticString, line: UInt) {
        guard let loop = loops.removeValue(forKey: listenerFD) else { return }
        var one: UInt8 = 1
        _ = Darwin.write(loop.stopWriteFD, &one, 1)
        if loop.done.wait(timeout: .now() + 5) == .timedOut {
            // A loop that ignored its stop byte is still parked on the listener and
            // will steal a later connection; that has to be loud, not silent.
            XCTFail(
                "Mock server accept loop for fd \(listenerFD) did not stop within 5s",
                file: file,
                line: line
            )
        }
        Darwin.close(loop.stopReadFD)
        Darwin.close(loop.stopWriteFD)
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
    /// Serves the mock control socket until the listener is torn down, fulfilling
    /// `handled` once the first connection is done (or once the listener goes away
    /// before anything connected).
    ///
    /// One accept loop services every connection the CLI opens. That matters
    /// headless: with piped stdio and no controlling TTY the CLI can't resolve its
    /// caller by TTY, so it always falls back to a `system.top` lookup on a second,
    /// short-lived connection. A mock that answers only one connection starves that
    /// lookup, and the hook stalls or routes to the wrong surface.
    func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        startMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: fulfillWhen
        ) { line in
            handler(line)
        }
    }

    /// Like ``startMockServer(listenerFD:state:fulfillWhen:handler:)``, but a nil
    /// return from `handler` records the request and sends no reply.
    func startMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli mock socket handled")
        let fulfillmentGate = CLIMockOnceFlag()
        CLIMockAcceptLoopRegistry.shared.start(listenerFD: listenerFD, onConnection: { clientFD in
            defer {
                Darwin.close(clientFD)
                fulfillmentGate.fulfill(handled)
            }
            cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                state.append(line)
                if fulfillWhen?(line) == true {
                    fulfillmentGate.fulfill(handled)
                }
                return handler(line)
            }
        }, onListenerClosed: {
            // Unblock the waiter if the listener is torn down before any client
            // connected (matches the previous accept-failure fulfillment).
            fulfillmentGate.fulfill(handled)
        })
        return handled
    }

    /// A mock server with no expectation to wait on, for tests that drive many
    /// hooks and assert on `state` afterwards.
    func startDetachedMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) {
        CLIMockAcceptLoopRegistry.shared.start(listenerFD: listenerFD, onConnection: { clientFD in
            defer { Darwin.close(clientFD) }
            cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                state.append(line)
                return handler(line)
            }
        }, onListenerClosed: {})
    }

    func startAgentHookMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        surfaceId: String
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            self.agentHookMockResponse(line: line, surfaceId: surfaceId)
        }
    }

    func startDetachedAgentHookMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        surfaceId: String
    ) {
        startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
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
