import Darwin
import Dispatch
import Foundation

/// Shared harness for the issue-7939 live delivery-target CLI regression
/// tests: a mock cmux control server that can answer (or refuse) the
/// `agent.resolve_delivery_target` probes, plus process/session-store
/// helpers. Kept out of the test suite file for the 500-line file budget.
enum ClaudeHookLiveDeliveryHarness {
    /// File-manager seam used to prove that unrelated hook writes do not
    /// rewrite the task-sync sidecar.
    final class TaskSyncCountingFileManager: FileManager {
        private(set) var taskSyncSidecarCreateCount = 0

        func resetTaskSyncSidecarCreateCount() {
            taskSyncSidecarCreateCount = 0
        }

        override func createFile(
            atPath path: String,
            contents data: Data?,
            attributes attr: [FileAttributeKey: Any]? = nil
        ) -> Bool {
            if path.contains(".task-sync.json") {
                taskSyncSidecarCreateCount += 1
            }
            return super.createFile(atPath: path, contents: data, attributes: attr)
        }
    }

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

    struct TaskSyncDeliverySignals {
        let feed = DispatchSemaphore(value: 0)
        let reconciliation = DispatchSemaphore(value: 0)
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
        resumeClearOwnsCheckpoint: Bool? = true
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

    /// Mock server for the task-sync hook's routing, Feed, and checklist calls.
    static func startTaskSyncServer(
        context: Context,
        workspaceId: String,
        surfaceId: String,
        workspaceIDsBySurface: [String: String] = [:],
        missingWorkspaceIDs: Set<String> = [],
        feedPushSucceeds: Bool = true,
        rejectsEmptyFeedSnapshots: Bool = false
    ) -> TaskSyncDeliverySignals {
        let deliveries = TaskSyncDeliverySignals()
        _ = startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = jsonObject(line),
                  let method = payload["method"] as? String else {
                return "OK"
            }
            if method == "feed.push" {
                deliveries.feed.signal()
                let params = payload["params"] as? [String: Any]
                let event = params?["event"] as? [String: Any]
                let toolInput = event?["tool_input"] as? [String: Any]
                let todos = toolInput?["todos"] as? [[String: Any]]
                let rejectsSnapshot = rejectsEmptyFeedSnapshots && todos?.isEmpty == true
                guard feedPushSucceeds, !rejectsSnapshot else {
                    guard let id = payload["id"] as? String else {
                        return "ERROR: injected Feed rejection"
                    }
                    return v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "delivery_failed", "message": "injected Feed rejection"]
                    )
                }
                if let id = payload["id"] as? String {
                    return v2Response(id: id, ok: true, result: [:])
                }
                return "OK"
            }
            guard let id = payload["id"] as? String else {
                return "OK"
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "agent.resolve_delivery_target":
                let requestedSurfaceID = params["surface_id"] as? String
                let resolvedWorkspaceID = requestedSurfaceID.flatMap {
                    workspaceIDsBySurface[$0]
                } ?? workspaceId
                return v2Response(id: id, ok: true, result: [
                    "workspace_id": resolvedWorkspaceID,
                    "surface_id": requestedSurfaceID ?? surfaceId,
                    "source": "surface",
                ])
            case "surface.list":
                let requestedWorkspaceID = params["workspace_id"] as? String
                let resolvedSurfaceID = workspaceIDsBySurface.first {
                    $0.value == requestedWorkspaceID
                }?.key ?? surfaceId
                return v2Response(id: id, ok: true, result: [
                    "surfaces": [["id": resolvedSurfaceID, "ref": "surface:1", "focused": true]],
                ])
            case "workspace.todo.reconcile":
                let items = params["items"] as? [[String: Any]] ?? []
                if items.count > 50 {
                    let destinationCount = (params["workspace_ids"] as? [String])?.count ?? 1
                    for _ in 0..<destinationCount {
                        deliveries.reconciliation.signal()
                    }
                    return v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "invalid_params", "message": "checklist cap exceeded"]
                    )
                }
                if let destinationWorkspaceIDs = params["workspace_ids"] as? [String] {
                    let results: [[String: Any]] = destinationWorkspaceIDs.map { workspaceID in
                        deliveries.reconciliation.signal()
                        if missingWorkspaceIDs.contains(workspaceID) {
                            return [
                                "workspace_id": workspaceID,
                                "ok": false,
                                "error": ["code": "not_found", "message": "workspace closed"],
                            ]
                        }
                        return ["workspace_id": workspaceID, "ok": true]
                    }
                    return v2Response(id: id, ok: true, result: ["results": results])
                }
                deliveries.reconciliation.signal()
                if let destinationWorkspaceID = params["workspace_id"] as? String,
                   missingWorkspaceIDs.contains(destinationWorkspaceID) {
                    return v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "workspace closed"]
                    )
                }
                return v2Response(id: id, ok: true, result: [:])
            default:
                return v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }
        return deliveries
    }

    static func taskSyncReconcileRequests(in context: Context) -> [[String: Any]] {
        context.state.snapshot().compactMap { command -> [String: Any]? in
            guard let request = jsonObject(command),
                  request["method"] as? String == "workspace.todo.reconcile" else {
                return nil
            }
            return request["params"] as? [String: Any]
        }.flatMap { params -> [[String: Any]] in
            guard let workspaceIDs = params["workspace_ids"] as? [String] else {
                return [params]
            }
            return workspaceIDs.map { workspaceID in
                var expanded = params
                expanded.removeValue(forKey: "workspace_ids")
                expanded["workspace_id"] = workspaceID
                return expanded
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
        pid: Int? = nil,
        claudeTaskDirectoryName: String? = nil,
        claudeTaskStoreID: String? = nil,
        markActive: Bool = false
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
        if let claudeTaskDirectoryName {
            record["claudeTaskDirectoryName"] = claudeTaskDirectoryName
        }
        if let claudeTaskStoreID {
            record["claudeTaskStoreID"] = claudeTaskStoreID
        }
        var store: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: record],
        ]
        if markActive {
            let active: [String: Any] = [
                "sessionId": sessionId,
                "updatedAt": now,
            ]
            store["activeSessionsByWorkspace"] = [workspaceId: active]
            store["activeSessionsBySurface"] = [surfaceId: active]
        }
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

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }
}
