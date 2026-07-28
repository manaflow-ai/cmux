import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIExplicitSurfaceRoutingTests {
    @Test func explicitSurfaceCommandsDoNotInheritCallerWorkspace() throws {
        try assertExplicitSurfaceCommand(
            arguments: ["read-screen", "--surface", Self.targetSurfaceRef, "--lines", "5"],
            expectedMethod: "surface.read_text"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["send", "--surface", Self.targetSurfaceRef, "hello"],
            expectedMethod: "surface.send_text",
            expectedText: "hello"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["send-key", "--surface", Self.targetSurfaceRef, "enter"],
            expectedMethod: "surface.send_key",
            expectedKey: "enter"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["send-panel", "--panel", Self.targetSurfaceRef, "hello"],
            expectedMethod: "surface.send_text",
            expectedText: "hello"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["send-key-panel", "--panel", Self.targetSurfaceRef, "enter"],
            expectedMethod: "surface.send_key",
            expectedKey: "enter"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["capture-pane", "--surface", Self.targetSurfaceRef, "--lines", "5"],
            expectedMethod: "surface.read_text"
        )
        try assertExplicitSurfaceCommand(
            arguments: ["pipe-pane", "--surface", Self.targetSurfaceRef, "--command", "cat"],
            expectedMethod: "surface.read_text"
        )
    }

    @Test func numericSurfaceHandleStillInheritsCallerWorkspaceForIndexResolution() throws {
        let socketPath = Self.makeSocketPath("numeric")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "surface.list":
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: ["surfaces": [["id": Self.numericSurfaceId, "ref": "surface:5", "index": 5]]]
                )
            case "surface.read_text":
                return Self.v2Response(id: id, ok: true, result: ["text": "numeric screen\n"])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: ["read-screen", "--surface", "5", "--lines", "1"],
            environment: cliEnvironment(socketPath: socketPath),
            timeout: 5
        )

        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        #expect(result.stdout.contains("numeric screen"), Comment(rawValue: result.stdout))

        let requests = try state.requestObjects()
        #expect(requests.compactMap { $0["method"] as? String } == ["surface.list", "surface.read_text"])

        let listParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(listParams["workspace_id"] as? String == Self.callerWorkspaceId)

        let readParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(readParams["workspace_id"] as? String == Self.callerWorkspaceId)
        #expect(readParams["surface_id"] as? String == Self.numericSurfaceId)
    }

    private func assertExplicitSurfaceCommand(
        arguments: [String],
        expectedMethod: String,
        expectedText: String? = nil,
        expectedKey: String? = nil
    ) throws {
        let socketPath = Self.makeSocketPath(expectedMethod)
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "surface.read_text":
                return Self.v2Response(id: id, ok: true, result: ["text": "agent screen\n"])
            case "surface.send_text", "surface.send_key":
                return Self.v2Response(id: id, ok: true, result: ["surface_id": Self.targetSurfaceRef])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: arguments,
            environment: cliEnvironment(socketPath: socketPath),
            timeout: 5
        )

        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))

        let requests = try state.requestObjects()
        #expect(requests.compactMap { $0["method"] as? String } == [expectedMethod])
        let request = try #require(requests.first)
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["surface_id"] as? String == Self.targetSurfaceRef)
        #expect(params["workspace_id"] == nil)
        #expect(params["window_id"] == nil)
        if let expectedText {
            #expect(params["text"] as? String == expectedText)
        }
        if let expectedKey {
            #expect(params["key"] as? String == expectedKey)
        }
    }

    private func cliEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = Self.callerWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.callerSurfaceId
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        return environment
    }

    private static let callerWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let callerSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let targetSurfaceRef = "surface:11"
    private static let numericSurfaceId = "33333333-3333-3333-3333-333333333333"

    private final class CLIExplicitSurfaceRoutingBundleToken {}

    // Records socket callbacks from a background queue; `lock` guards both arrays.
    private final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var requestLines: [String] = []
        private var errors: [String] = []

        func record(_ line: String) {
            lock.lock()
            requestLines.append(line)
            lock.unlock()
        }

        func recordError(_ message: String) {
            lock.lock()
            errors.append(message)
            lock.unlock()
        }

        func errorsSnapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return errors
        }

        func requestObjects() throws -> [[String: Any]] {
            lock.lock()
            let lines = requestLines
            lock.unlock()
            return try lines.map { line in
                try #require(CLIExplicitSurfaceRoutingTests.jsonObject(line))
            }
        }
    }

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: CLIExplicitSurfaceRoutingBundleToken.self)
    }

    private static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG), userInfo: [
                NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)",
            ])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
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
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
            defer { handled.signal() }

            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                state.recordError("mock socket server failed to accept a client")
                return
            }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    state.recordError("mock socket server read failed with errno \(errno)")
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.record(line)
                    let response = handler(line) + "\n"
                    _ = response.withCString { pointer in
                        Darwin.write(clientFD, pointer, strlen(pointer))
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

    private static func malformedRequestResponse(id: String? = nil, raw: String) -> String {
        v2Response(
            id: id ?? "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func runProcess(
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
}
