import XCTest
import Darwin
import Foundation

func bundledCLINotFoundError(appBundleURL: URL, file: StaticString = #filePath, line: UInt = #line) -> Error {
    let message = "Bundled cmux CLI not found in \(appBundleURL.path)"
    let environment = ProcessInfo.processInfo.environment
    if environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true" {
        XCTFail(message, file: file, line: line)
        return NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
    return XCTSkip(message)
}

extension CLINotifyProcessIntegrationRegressionTests {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class ProcessPipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func stringValue() -> String {
            lock.lock()
            let value = data
            lock.unlock()
            return String(data: value, encoding: .utf8) ?? ""
        }
    }

    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

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

    final class MockSocketConnectionTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var acceptedConnections = 0
        private var activeConnections = 0
        private var lastActivity = Date()
        private var didFulfill = false

        func accepted() {
            lock.lock()
            acceptedConnections += 1
            activeConnections += 1
            lastActivity = Date()
            lock.unlock()
        }

        func closed() {
            lock.lock()
            activeConnections = max(0, activeConnections - 1)
            lastActivity = Date()
            lock.unlock()
        }

        func activity() {
            lock.lock()
            lastActivity = Date()
            lock.unlock()
        }

        func shouldFinish(idleFor interval: TimeInterval, allowOpenConnections: Bool) -> Bool {
            lock.lock()
            let shouldFinish = acceptedConnections > 0
                && (allowOpenConnections || activeConnections == 0)
                && Date().timeIntervalSince(lastActivity) >= interval
            lock.unlock()
            return shouldFinish
        }

        func markFulfilled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if didFulfill { return false }
            didFulfill = true
            return true
        }
    }

    struct LoopbackTCPListener {
        let fd: Int32
        let port: Int
    }

    func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw bundledCLINotFoundError(appBundleURL: appBundleURL)
    }

    func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cx-\(name.prefix(3))-\(shortID).sock"
    }

    func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG), userInfo: [
                NSLocalizedDescriptionKey: "Unix socket path is too long for sockaddr_un: \(path)",
            ])
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
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(fd, 16), 0)
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

            let payload: [String: Any] = ["type": "ready"]
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

    func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        finishOnIdle: Bool = true,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        startMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: fulfillWhen,
            finishOnIdle: finishOnIdle,
            allowOpenConnectionsAfterIdle: false
        ) { line in
            handler(line)
        }
    }

    func startMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        finishOnIdle: Bool = true,
        allowOpenConnectionsAfterIdle: Bool = true,
        handler: @escaping @Sendable (String) -> String?
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli mock socket handled")
        DispatchQueue.global(qos: .userInitiated).async {
            let tracker = MockSocketConnectionTracker()
            func fulfillOnce() {
                if tracker.markFulfilled() {
                    handled.fulfill()
                }
            }

            func handleClient(_ clientFD: Int32) {
                defer {
                    Darwin.close(clientFD)
                    tracker.closed()
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
                        tracker.activity()
                        state.append(line)
                        if fulfillWhen?(line) == true {
                            fulfillOnce()
                        }
                        guard let responsePayload = handler(line) else { continue }
                        let response = responsePayload + "\n"
                        _ = response.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
                        tracker.activity()
                    }
                }
            }

            let idleGrace: TimeInterval = 0.15
            while true {
                var descriptor = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 25)
                if ready < 0 {
                    if errno == EINTR { continue }
                    fulfillOnce()
                    return
                }

                if ready > 0, descriptor.revents & Int16(POLLIN) != 0 {
                    var clientAddr = sockaddr_un()
                    var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                            Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                        }
                    }
                    guard clientFD >= 0 else {
                        if errno == EINTR { continue }
                        fulfillOnce()
                        return
                    }

                    tracker.accepted()
                    DispatchQueue.global(qos: .userInitiated).async {
                        handleClient(clientFD)
                    }
                }

                if finishOnIdle && tracker.shouldFinish(idleFor: idleGrace, allowOpenConnections: allowOpenConnectionsAfterIdle) {
                    fulfillOnce()
                    return
                }
            }
        }
        return handled
    }

    func startDetachedMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) {
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
            result: ["surfaces": [["id": surfaceId, "ref": "surface:1", "focused": true]]]
        )
    }

    func systemTopResponse(id: String) -> String {
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let paneId = "33333333-3333-3333-3333-333333333333"
        let windowId = "44444444-4444-4444-4444-444444444444"
        return v2Response(
            id: id,
            ok: true,
            result: [
                "active": NSNull(),
                "caller": NSNull(),
                "include_processes": true,
                "windows": [
                    [
                        "kind": "window",
                        "id": windowId,
                        "ref": "window:\(windowId)",
                        "index": 0,
                        "key": true,
                        "visible": true,
                        "workspace_count": 1,
                        "selected_workspace_id": workspaceId,
                        "selected_workspace_ref": "workspace:\(workspaceId)",
                        "workspaces": [
                            [
                                "kind": "workspace",
                                "id": workspaceId,
                                "ref": "workspace:\(workspaceId)",
                                "index": 0,
                                "title": "Test Workspace",
                                "description": NSNull(),
                                "selected": true,
                                "pinned": false,
                                "panes": [
                                    [
                                        "kind": "pane",
                                        "id": paneId,
                                        "ref": "pane:\(paneId)",
                                        "index": 0,
                                        "focused": true,
                                        "surface_ids": [surfaceId],
                                        "surface_refs": ["surface:\(surfaceId)"],
                                        "selected_surface_id": surfaceId,
                                        "selected_surface_ref": "surface:\(surfaceId)",
                                        "surface_count": 1,
                                        "surfaces": [
                                            [
                                                "kind": "surface",
                                                "id": surfaceId,
                                                "ref": "surface:\(surfaceId)",
                                                "index": 0,
                                                "type": "terminal",
                                                "title": "Terminal",
                                                "focused": true,
                                                "selected": true,
                                                "selected_in_pane": true,
                                                "pane_id": paneId,
                                                "pane_ref": "pane:\(paneId)",
                                                "index_in_pane": 0,
                                                "tty": NSNull(),
                                                "webviews": [],
                                                "url": NSNull(),
                                                "browser_web_content_pid": NSNull(),
                                                "processes": [],
                                            ] as [String: Any],
                                        ],
                                    ] as [String: Any],
                                ],
                                "tags": [],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ],
            ]
        )
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
        let stdoutCapture = ProcessPipeCapture()
        let stderrCapture = ProcessPipeCapture()
        let ioGroup = DispatchGroup()
        ioGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutCapture.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            ioGroup.leave()
        }
        ioGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrCapture.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            ioGroup.leave()
        }
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timeoutFloor = ProcessInfo.processInfo.environment["CMUX_CLI_NOTIFY_PROCESS_TIMEOUT_SECONDS"]
            .flatMap(TimeInterval.init) ?? timeout
        let effectiveTimeout = max(timeout, timeoutFloor)
        let timedOut = exitSignal.wait(timeout: .now() + effectiveTimeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }
        _ = ioGroup.wait(timeout: .now() + 1)

        let stdout = stdoutCapture.stringValue()
        let stderr = stderrCapture.stringValue()
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
