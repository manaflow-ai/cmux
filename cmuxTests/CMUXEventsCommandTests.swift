import Darwin
import XCTest

final class CMUXEventsCommandTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class EventStreamRequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var methods: [String] = []

        func append(method: String) {
            lock.lock()
            methods.append(method)
            lock.unlock()
        }
    }

    func testEventsCommandRejectsMalformedAckFrame() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("events-ack")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let requestLog = EventStreamRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startEventStreamServer(
            listenerFD: listenerFD,
            requestLog: requestLog,
            frames: [
                #"{"type":"ack","protocol":"cmux-events","version":1}"#
            ]
        )

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["events", "--no-heartbeat"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("Invalid event stream ack: missing resume"), result.stderr)
        XCTAssertEqual(requestLog.methods, ["events.stream"])
    }

    func testEventsCommandRejectsMalformedEventFrame() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("events-event")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let requestLog = EventStreamRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startEventStreamServer(
            listenerFD: listenerFD,
            requestLog: requestLog,
            frames: [
                validAckFrame(),
                #"{"type":"event","protocol":"cmux-events","version":1,"boot_id":"boot","seq":true,"id":"boot-1","name":"notification.created","category":"notification","source":"test","occurred_at":"2026-05-06T19:18:03.421Z","payload":{}}"#
            ]
        )

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["events", "--no-ack", "--no-heartbeat"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("Invalid event stream frame: event missing numeric seq"), result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(requestLog.methods, ["events.stream"])
    }

    func testEventsCommandRejectsMalformedCursorFileBeforeConnecting() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cursorURL = rootURL.appendingPathComponent("events.seq")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "not-a-sequence\n".write(to: cursorURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: makeSocketPath("events-cursor"),
            arguments: ["events", "--cursor-file", cursorURL.path]
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("Malformed events cursor file"), result.stderr)
        XCTAssertTrue(result.stderr.contains("expected a non-negative sequence number"), result.stderr)
    }

    private func runCLI(cliPath: String, socketPath: String, arguments: [String]) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        return runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 5)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }

        return fd
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func startEventStreamServer(
        listenerFD: Int32,
        requestLog: EventStreamRequestLog,
        frames: [String]
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli events mock socket handled")
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.fulfill()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.fulfill()
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
                    if line.hasPrefix("auth ") {
                        Self.writeLine("OK", to: clientFD)
                        continue
                    }
                    guard let payload = Self.v2Payload(from: line),
                          let method = payload["method"] as? String else {
                        return
                    }
                    requestLog.append(method: method)
                    guard method == "events.stream" else { return }
                    for frame in frames {
                        Self.writeLine(frame, to: clientFD)
                    }
                    return
                }
            }
        }
        return handled
    }

    private static func writeLine(_ line: String, to fd: Int32) {
        let data = Data((line + "\n").utf8)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = Darwin.write(fd, baseAddress, data.count)
        }
    }

    private static func v2Payload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func validAckFrame() -> String {
        #"{"type":"ack","protocol":"cmux-events","version":1,"boot_id":"boot","subscription_id":"subscription","heartbeat_interval_seconds":15,"replay_count":0,"resume":{"after_seq":0,"requested_after_seq":0,"oldest_seq":1,"latest_seq":0,"next_seq":1,"gap":false},"filters":{"names":[],"categories":[]}}"#
    }
}
