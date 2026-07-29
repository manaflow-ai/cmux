import XCTest
import Darwin
import Network

extension CLINotifyProcessIntegrationRegressionTests {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []
        private var blankSurfaceAtSplitByThreadId: [String: Bool] = [:]

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

        func recordBlankSurfaceAtSplit(_ wasBlank: Bool, threadId: String) {
            lock.lock()
            blankSurfaceAtSplitByThreadId[threadId] = wasBlank
            lock.unlock()
        }

        func blankSurfaceAtSplit(threadId: String) -> Bool? {
            lock.lock()
            let value = blankSurfaceAtSplitByThreadId[threadId]
            lock.unlock()
            return value
        }
    }

    final class CodexTeamsTestAppServer: @unchecked Sendable {
        struct LoadedThreadPage {
            let requestCursor: String?
            let data: [String]
            let nextCursor: String?
        }

        private let queue = DispatchQueue(label: "cmux.tests.codex-teams-app-server")
        private let listener: NWListener
        private let threadsById: [String: [String: Any]]
        private let loadedThreadIdBatches: [[String]]
        private let loadedThreadPagesByCursor: [String: LoadedThreadPage]?
        private let ignoredMethods: Set<String>
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private var loadedThreadListRequestCountValue = 0
        private var loadedThreadListRequestCursorsValue: [String?] = []
        private var loadedThreadListRequestTimesValue: [TimeInterval] = []

        init(
            threads: [[String: Any]],
            loadedThreadIdBatches: [[String]],
            ignoredMethods: Set<String> = []
        ) throws {
            let parameters = NWParameters.tcp
            let webSocketOptions = NWProtocolWebSocket.Options()
            webSocketOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
            listener = try NWListener(using: parameters, on: .any)
            threadsById = Dictionary(
                uniqueKeysWithValues: threads.compactMap { thread in
                    guard let id = thread["id"] as? String else { return nil }
                    return (id, thread)
                }
            )
            self.loadedThreadIdBatches = loadedThreadIdBatches.isEmpty ? [[]] : loadedThreadIdBatches
            loadedThreadPagesByCursor = nil
            self.ignoredMethods = ignoredMethods
        }

        init(
            threads: [[String: Any]],
            loadedThreadPages: [LoadedThreadPage],
            ignoredMethods: Set<String> = []
        ) throws {
            let parameters = NWParameters.tcp
            let webSocketOptions = NWProtocolWebSocket.Options()
            webSocketOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
            listener = try NWListener(using: parameters, on: .any)
            threadsById = Dictionary(
                uniqueKeysWithValues: threads.compactMap { thread in
                    guard let id = thread["id"] as? String else { return nil }
                    return (id, thread)
                }
            )
            loadedThreadIdBatches = [[]]
            loadedThreadPagesByCursor = Dictionary(
                uniqueKeysWithValues: loadedThreadPages.map {
                    ($0.requestCursor ?? "", $0)
                }
            )
            self.ignoredMethods = ignoredMethods
        }

        func start(timeout: TimeInterval = 5) throws -> URL {
            let ready = DispatchSemaphore(value: 0)
            let failed = LockedBox<NWError?>()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.signal()
                case .failed(let error):
                    failed.set(error)
                    ready.signal()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + timeout) == .success else {
                throw NSError(
                    domain: "cmux.tests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Codex Teams test app-server did not start"]
                )
            }
            if let error = failed.get() ?? nil {
                throw error
            }
            guard let port = listener.port else {
                throw NSError(
                    domain: "cmux.tests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Codex Teams test app-server has no port"]
                )
            }
            return URL(string: "ws://127.0.0.1:\(port.rawValue)")!
        }

        func stop() {
            listener.cancel()
            lock.lock()
            let activeConnections = connections
            connections.removeAll()
            lock.unlock()
            for connection in activeConnections {
                connection.cancel()
            }
        }

        func loadedThreadListRequestCount() -> Int {
            lock.lock()
            let value = loadedThreadListRequestCountValue
            lock.unlock()
            return value
        }

        func loadedThreadListRequestCursors() -> [String?] {
            lock.lock()
            let value = loadedThreadListRequestCursorsValue
            lock.unlock()
            return value
        }

        func loadedThreadListRequestTimes() -> [TimeInterval] {
            lock.lock()
            let value = loadedThreadListRequestTimesValue
            lock.unlock()
            return value
        }

        private func accept(_ connection: NWConnection) {
            lock.lock()
            connections.append(connection)
            lock.unlock()
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .cancelled = state, let connection else { return }
                self?.remove(connection)
            }
            connection.start(queue: queue)
            receive(on: connection)
        }

        private func remove(_ connection: NWConnection) {
            lock.lock()
            connections.removeAll { $0 === connection }
            lock.unlock()
        }

        private func receive(on connection: NWConnection) {
            connection.receiveMessage { [weak self, weak connection] data, _, _, error in
                guard let self, let connection else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                if let data,
                   let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(request, on: connection)
                }
                self.receive(on: connection)
            }
        }

        private func handle(_ request: [String: Any], on connection: NWConnection) {
            guard let method = request["method"] as? String else { return }
            guard let requestId = request["id"] else { return }
            guard !ignoredMethods.contains(method) else { return }
            switch method {
            case "initialize":
                send([["id": requestId, "result": [:]]], on: connection)
            case "thread/loaded/list":
                let params = request["params"] as? [String: Any]
                let cursor = params?["cursor"] as? String
                if let loadedThreadPagesByCursor {
                    recordLoadedThreadListRequest(cursor: cursor)
                    guard let page = loadedThreadPagesByCursor[cursor ?? ""] else {
                        send([[
                            "id": requestId,
                            "error": ["code": -32_602, "message": "unknown test cursor"],
                        ]], on: connection)
                        return
                    }
                    var result: [String: Any] = ["data": page.data]
                    result["nextCursor"] = page.nextCursor ?? NSNull()
                    send([["id": requestId, "result": result]], on: connection)
                    return
                }
                let loadedThreadIds = nextLoadedThreadIds()
                send([["id": requestId, "result": ["data": loadedThreadIds]]], on: connection)
            case "thread/resume":
                guard let params = request["params"] as? [String: Any],
                      let threadId = params["threadId"] as? String,
                      let thread = threadsById[threadId] else {
                    send([[
                        "id": requestId,
                        "error": ["code": -32_602, "message": "unknown test thread"],
                    ]], on: connection)
                    return
                }
                var partialThread = thread
                partialThread.removeValue(forKey: "source")
                send([
                    [
                        "method": "thread/started",
                        "params": ["thread": thread],
                    ],
                    [
                        "id": requestId,
                        "result": ["thread": partialThread],
                    ],
                ], on: connection)
            default:
                send([[
                    "id": requestId,
                    "error": ["code": -32_601, "message": "unsupported test method \(method)"],
                ]], on: connection)
            }
        }

        private func nextLoadedThreadIds() -> [String] {
            lock.lock()
            let index = min(loadedThreadListRequestCountValue, loadedThreadIdBatches.count - 1)
            loadedThreadListRequestCountValue += 1
            loadedThreadListRequestCursorsValue.append(nil)
            loadedThreadListRequestTimesValue.append(ProcessInfo.processInfo.systemUptime)
            let value = loadedThreadIdBatches[index]
            lock.unlock()
            return value
        }

        private func recordLoadedThreadListRequest(cursor: String?) {
            lock.lock()
            loadedThreadListRequestCountValue += 1
            loadedThreadListRequestCursorsValue.append(cursor)
            loadedThreadListRequestTimesValue.append(ProcessInfo.processInfo.systemUptime)
            lock.unlock()
        }

        private func send(_ objects: [[String: Any]], on connection: NWConnection) {
            guard let first = objects.first,
                  let data = try? JSONSerialization.data(withJSONObject: first) else {
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: UUID().uuidString,
                metadata: [metadata]
            )
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard error == nil, let self, let connection else { return }
                    self.send(Array(objects.dropFirst()), on: connection)
                }
            )
        }
    }

    final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func set(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Value? {
            lock.lock()
            let current = value
            lock.unlock()
            return current
        }
    }

    struct LoopbackTCPListener {
        let fd: Int32
        let port: Int
    }

    func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cli-\(name.prefix(3))-\(shortID).sock"
    }

    func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        XCTAssertLessThan(utf8.count, maxPathLength)
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
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        return fd
    }

    func bindLoopbackTCP() throws -> LoopbackTCPListener {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to create TCP socket",
            ])
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to bind TCP socket",
            ])
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to listen on TCP socket",
            ])
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.getsockname(fd, sockaddrPtr, &boundLen)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to read TCP socket port",
            ])
        }

        return LoopbackTCPListener(fd: fd, port: Int(UInt16(bigEndian: boundAddr.sin_port)))
    }

    func waitForSocketFile(at path: String, timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return FileManager.default.fileExists(atPath: path)
    }

    func startBridgeErrorServer(listenerFD: Int32, message: String) -> XCTestExpectation {
        let handled = expectation(description: "pty bridge error server handled")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.fulfill() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let payload: [String: Any] = ["type": "error", "message": message]
            guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(clientFD, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
        return handled
    }

    func startBridgeReadyThenCloseServer(listenerFD: Int32) -> XCTestExpectation {
        let handled = expectation(description: "pty bridge ready close server handled")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.fulfill() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let payload: [String: Any] = ["type": "ready", "attachment_token": "attach-token"]
            guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(clientFD, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
        return handled
    }

    func startBridgeReadyThenResetAfterClientEOFServer(listenerFD: Int32) -> XCTestExpectation {
        let handled = expectation(description: "pty bridge ready reset server handled")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.fulfill() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let payload: [String: Any] = ["type": "ready", "attachment_token": "attach-token"]
            guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(clientFD, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }

            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                return
            }

            var lingerOption = linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_LINGER,
                &lingerOption,
                socklen_t(MemoryLayout.size(ofValue: lingerOption))
            )
        }
        return handled
    }

    func v2Response(
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

    func malformedRequestResponse(id: String? = nil, raw: String) -> String {
        v2Response(
            id: id ?? "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    func surfaceListResponse(id: String, surfaceId: String) -> String {
        v2Response(
            id: id,
            ok: true,
            result: ["surfaces": [["id": surfaceId, "ref": "surface:1", "index": 1, "focused": true]]]
        )
    }

    func processTimeout(_ requested: TimeInterval) -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" else {
            return requested
        }
        return max(requested, 20)
    }

    func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let outputLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        let outputGroup = DispatchGroup()

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stdoutData = data
            outputLock.unlock()
            outputGroup.leave()
        }

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stderrData = data
            outputLock.unlock()
            outputGroup.leave()
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + processTimeout(timeout)) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }
        _ = outputGroup.wait(timeout: .now() + 2)

        outputLock.lock()
        let finalStdoutData = stdoutData
        let finalStderrData = stderrData
        outputLock.unlock()
        let stdout = String(data: finalStdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: finalStderrData, encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
