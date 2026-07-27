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
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
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
        resolverMethodAvailable: Bool = true
    ) -> DispatchSemaphore {
        startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
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
                    return v2Response(id: id, ok: true, result: [
                        "workspace_id": pidTarget.workspaceId,
                        "surface_id": pidTarget.surfaceId,
                        "source": "pid",
                    ])
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
            default:
                return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
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
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: context.cliPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
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

    private static func startMockServer(
        listenerFD: Int32,
        state: ServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    if errno == EINTR { continue }
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        Darwin.close(clientFD)
                        handled.signal()
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
