import Darwin
import Dispatch
import Foundation

/// Shared harness for the issue-7939 live delivery-target CLI regression
/// tests: a mock cmux control server that can answer (or refuse) the
/// `agent.resolve_delivery_target` probes, plus process/session-store
/// helpers. Kept out of the test suite file for the 500-line file budget.
enum ClaudeHookLiveDeliveryHarness {
    struct Context {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: ServerState
        let root: URL
        let storeURL: URL

        func cleanup() {
            // The accept loop must be parked before the descriptor goes away:
            // a closed fd number can be reused by another parallel suite's
            // listener within microseconds, and a loop still polling it
            // would accept that suite's connections.
            state.stopAcceptLoop(timeout: 1)
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Command log plus the accept-loop bookkeeping that lets a test wait
    /// until every connection its CLI child opened has been read.
    final class ServerState: @unchecked Sendable {
        private let condition = NSCondition()
        private var commands: [String] = []
        private var serverStarted = false
        private var stopRequested = false
        private var acceptLoopStopped = false
        private var inFlightClients = 0
        private var drainRequests = 0
        private var drainedThrough = 0

        func append(_ command: String) {
            condition.lock()
            commands.append(command)
            condition.unlock()
        }

        func snapshot() -> [String] {
            condition.lock()
            let value = commands
            condition.unlock()
            return value
        }

        /// Blocks until the accept loop has observed, after this call, an
        /// empty listen backlog with no client reader in flight. Call it once
        /// the CLI child has exited: every connection the child opened is then
        /// either accepted (in flight) or still queued in the backlog, so this
        /// observation proves the command log is complete. One-way sends
        /// (`feed.push` telemetry) never wait for a reply, so the log is
        /// otherwise racing a reader thread that may start late.
        func waitForQuiescence(timeout: TimeInterval) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard serverStarted, !acceptLoopStopped else { return true }
            drainRequests += 1
            let request = drainRequests
            let deadline = Date(timeIntervalSinceNow: timeout)
            while drainedThrough < request, !acceptLoopStopped {
                if !condition.wait(until: deadline) { break }
            }
            return drainedThrough >= request || (acceptLoopStopped && inFlightClients == 0)
        }

        fileprivate func markServerStarted() {
            condition.lock()
            serverStarted = true
            condition.unlock()
        }

        fileprivate var shouldStop: Bool {
            condition.lock()
            defer { condition.unlock() }
            return stopRequested
        }

        fileprivate func clientAccepted() {
            condition.lock()
            inFlightClients += 1
            condition.unlock()
        }

        fileprivate func clientClosed() {
            condition.lock()
            inFlightClients -= 1
            condition.broadcast()
            condition.unlock()
        }

        /// Accept-loop only: a poll slice ended with nothing queued. Only the
        /// thread that dequeues connections may make this observation, so no
        /// connection can sit between `accept` and `clientAccepted` while it
        /// is made.
        fileprivate func noteBacklogEmpty() {
            condition.lock()
            if inFlightClients == 0 {
                drainedThrough = drainRequests
                condition.broadcast()
            }
            condition.unlock()
        }

        fileprivate func markAcceptLoopStopped() {
            condition.lock()
            acceptLoopStopped = true
            condition.broadcast()
            condition.unlock()
        }

        fileprivate func stopAcceptLoop(timeout: TimeInterval) {
            condition.lock()
            defer { condition.unlock() }
            guard serverStarted, !acceptLoopStopped else { return }
            stopRequested = true
            let deadline = Date(timeIntervalSinceNow: timeout)
            while !acceptLoopStopped {
                if !condition.wait(until: deadline) { break }
            }
        }
    }

    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    static func makeContext(name: String) throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
        return Context(
            cliPath: try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self),
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: ServerState(),
            root: root,
            storeURL: root.appendingPathComponent("claude-hook-sessions.json")
        )
    }

    static func hookEnvironment(context: Context) -> [String: String] {
        [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.storeURL.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]
    }

    /// Mock control server. `pidTarget` answers the `{pid}` probe;
    /// `surfaceTargets` answers `{surface_id}` re-home probes;
    /// `resolverMethodAvailable: false` simulates an older app.
    static func startDeliveryTargetServer(
        context: Context,
        surfacesByWorkspace: [String: [String]],
        pidTarget: (workspaceId: String, surfaceId: String)?,
        surfaceTargets: [String: String] = [:],
        ttyRows: [(tty: String, workspaceId: String, surfaceId: String)] = [],
        resolverMethodAvailable: Bool = true,
        acknowledgesPIDResolution: Bool = true,
        resumeClearSucceeds: Bool = true,
        resumeClearOwnsCheckpoint: Bool? = true,
        readerStartDelay: TimeInterval = 0
    ) -> DispatchSemaphore {
        startMockServer(
            listenerFD: context.listenerFD,
            state: context.state,
            readerStartDelay: readerStartDelay
        ) { line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "agent.resolve_delivery_target":
                guard resolverMethodAvailable else {
                    return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unknown method"])
                }
                if params["pid"] != nil {
                    guard let pidTarget else {
                        return v2Response(id: id, ok: false, error: ["code": "not_found", "message": "pid not owned by a live surface"])
                    }
                    var result: [String: Any] = [
                        "workspace_id": pidTarget.workspaceId,
                        "surface_id": pidTarget.surfaceId,
                        "source": "pid",
                    ]
                    if acknowledgesPIDResolution {
                        result["pid_resolution"] = params["pid_resolution"] as? String ?? "corroborated"
                    }
                    return v2Response(id: id, ok: true, result: result)
                }
                if let surfaceId = params["surface_id"] as? String,
                   let workspaceId = surfaceTargets[surfaceId] {
                    return v2Response(id: id, ok: true, result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "source": "surface",
                    ])
                }
                return v2Response(id: id, ok: false, error: ["code": "not_found", "message": "no live target"])
            case "surface.list":
                guard let workspaceId = params["workspace_id"] as? String,
                      let surfaceIds = surfacesByWorkspace[workspaceId] else {
                    return v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
                }
                let surfaces: [[String: Any]] = surfaceIds.enumerated().map { index, surfaceId in
                    ["id": surfaceId, "ref": "surface:\(index + 1)", "focused": index == 0]
                }
                return v2Response(id: id, ok: true, result: ["surfaces": surfaces])
            case "debug.terminals":
                let terminals: [[String: Any]] = ttyRows.map {
                    ["tty": $0.tty, "workspace_id": $0.workspaceId, "surface_id": $0.surfaceId]
                }
                return v2Response(id: id, ok: true, result: ["terminals": terminals])
            case "feed.push":
                return v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            case "surface.resume.clear":
                if resumeClearSucceeds {
                    guard let resumeClearOwnsCheckpoint else {
                        return v2Response(id: id, ok: true, result: [:])
                    }
                    return v2Response(
                        id: id,
                        ok: true,
                        result: ["cleared": resumeClearOwnsCheckpoint]
                    )
                }
                return v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "cleanup_failed", "message": "injected resume cleanup failure"]
                )
            default:
                return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }
    }

    /// `hook_event_name` of every `feed.push` the mock server received, in
    /// arrival order.
    static func feedEventNames(in context: Context) -> [String] {
        context.state.snapshot().compactMap { command -> String? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any],
                  let event = params["event"] as? [String: Any] else {
                return nil
            }
            return event["hook_event_name"] as? String
        }
    }

    static func resumeBindingParams(in context: Context) -> [[String: Any]] {
        context.state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
    }

    static func writeSessionStore(
        to storeURL: URL,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String,
        pid: Int? = nil
    ) throws {
        let now = Date().timeIntervalSince1970
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "cwd": cwd,
            "isRestorable": true,
            "startedAt": now,
            "updatedAt": now,
        ]
        if let pid { record["pid"] = pid }
        let store: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: record],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: storeURL)
    }

    static func sessionRecord(in storeURL: URL, sessionId: String) throws -> [String: Any]? {
        // A hook that fails closed before its first accepted upsert never
        // creates the store file; that is the strongest form of "no record".
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        let sessions = saved?["sessions"] as? [String: Any]
        return sessions?[sessionId] as? [String: Any]
    }

    static func runHookProcess(
        context: Context,
        arguments: [String],
        environment: [String: String],
        standardInput: String
    ) -> ProcessRunResult {
        // Runs on dedicated threads (CLITestProcessRunner) so a saturated
        // libdispatch pool during parallel Swift Testing cannot hide the exit.
        let outcome = CLITestProcessRunner.run(
            executablePath: context.cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: 10
        )
        // The child is gone (or its process group was killed), so every
        // connection it opened is now accepted or queued; wait for the mock
        // server to read all of them before the test looks at the log.
        var stderr = outcome.stderr
        if !context.state.waitForQuiescence(timeout: 2) {
            stderr += "\n[test harness] mock server still had a connection in flight 2s after the CLI exited"
        }
        return ProcessRunResult(
            status: outcome.status,
            stdout: outcome.stdout,
            stderr: stderr,
            timedOut: outcome.timedOut
        )
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(code))
        }
        return fd
    }

    /// Length of one accept-loop poll slice. Bounds how long
    /// `waitForQuiescence` and `stopAcceptLoop` wait for the loop to notice.
    private static let acceptPollSliceMilliseconds: Int32 = 10

    /// - Parameter readerStartDelay: Test-only scheduling latency injected
    ///   before each client reader starts, to model a cold reader thread on a
    ///   loaded runner.
    private static func startMockServer(
        listenerFD: Int32,
        state: ServerState,
        readerStartDelay: TimeInterval,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        state.markServerStarted()
        // Accept and per-client loops block indefinitely; keep them off the
        // libdispatch pool so parallel suites cannot starve each other.
        CLITestProcessRunner.detachBlockingThread(name: "cmux-test-live-delivery-mock-accept") {
            defer { state.markAcceptLoopStopped() }
            while !state.shouldStop {
                // Poll in short slices instead of blocking in accept: a slice
                // that ends with nothing queued is the "backlog empty"
                // observation `waitForQuiescence` needs, and a stop request
                // from `cleanup` is honored before the listener fd closes.
                var listener = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&listener, 1, acceptPollSliceMilliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 {
                    state.noteBacklogEmpty()
                    continue
                }
                if listener.revents & Int16(POLLNVAL | POLLERR | POLLHUP) != 0 { return }
                if state.shouldStop { return }

                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
                    return
                }
                state.clientAccepted()

                CLITestProcessRunner.detachBlockingThread(name: "cmux-test-live-delivery-mock-client") {
                    defer {
                        Darwin.close(clientFD)
                        state.clientClosed()
                        handled.signal()
                    }
                    if readerStartDelay > 0 {
                        // Scenario pacing only: models the reader being
                        // scheduled late, not synchronization.
                        Thread.sleep(forTimeInterval: readerStartDelay)
                    }

                    func writeResponse(_ response: String) {
                        let line = response + "\n"
                        _ = line.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
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
                            writeResponse(handler(line))
                        }
                    }
                }
            }
        }
        return handled
    }

    private static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }
}
