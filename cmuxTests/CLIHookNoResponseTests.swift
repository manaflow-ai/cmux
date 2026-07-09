import Darwin
import Foundation
import Testing

@Suite("CLI hook no-response telemetry")
struct CLIHookNoResponseTests {
    final class BundleProbe {}

    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
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

    struct MockSocketServer {
        let handled: DispatchSemaphore

        func wait(timeout: TimeInterval) -> Bool {
            handled.wait(timeout: .now() + timeout) == .success
        }
    }

    struct FeedHookCase {
        let source: String
        let event: String
        let toolName: String
        let pidKey: String
    }

    @Test func nonActionableFeedHooksDoNotWaitForSocketResponseAcrossAgents() throws {
        let cases = [
            FeedHookCase(source: "codex", event: "PreToolUse", toolName: "apply_patch", pidKey: "CMUX_CODEX_PID"),
            FeedHookCase(source: "gemini", event: "PreToolUse", toolName: "read", pidKey: "CMUX_GEMINI_PID"),
            FeedHookCase(source: "kiro", event: "postToolUse", toolName: "fs_write", pidKey: "CMUX_KIRO_PID"),
            FeedHookCase(source: "hermes-agent", event: "pre_tool_call", toolName: "terminal", pidKey: "CMUX_HERMES_AGENT_PID"),
            FeedHookCase(source: "antigravity", event: "PostToolUse", toolName: "run_command", pidKey: "CMUX_ANTIGRAVITY_PID"),
        ]

        for testCase in cases {
            let cliPath = try Self.bundledCLIPath()
            let socketPath = Self.makeSocketPath("feed-no-reply-\(testCase.source.prefix(6))")
            let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 1)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-feed-no-reply-\(testCase.source)-\(UUID().uuidString)", isDirectory: true)

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let server = Self.startMockServerAllowingNoResponse(
                listenerFD: listenerFD,
                state: state,
                fulfillWhen: { line in
                    Self.jsonObject(line)?["method"] as? String == "feed.push"
                }
            ) { line in
                guard let payload = Self.jsonObject(line),
                      payload["method"] as? String == "feed.push" else {
                    return Self.malformedRequestResponse(raw: line)
                }
                return nil
            }

            var environment = [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
            environment[testCase.pidKey] = "626262"

            let input = """
            {"hook_event_name":"\(testCase.event)","session_id":"\(testCase.source)-session-123","cwd":"\(root.path)","tool_name":"\(testCase.toolName)","tool_input":{"path":"\(root.appendingPathComponent("README.md").path)"}}
            """
            let result = Self.runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", testCase.source, "--event", testCase.event],
                environment: environment,
                standardInput: input,
                timeout: 0.5
            )

            #expect(server.wait(timeout: 5), "\(testCase.source): socket server did not observe feed.push")
            #expect(!result.timedOut, "\(testCase.source): \(result.stderr)")
            #expect(result.status == 0, "\(testCase.source): \(result.stderr)")
            #expect(result.stdout == "{}\n")
            #expect(state.snapshot().filter { $0.contains(#""method":"feed.push""#) }.count == 1)
        }
    }

    @Test func genericLifecycleFeedTelemetryDoesNotWaitForSocketResponse() throws {
        let cliPath = try Self.bundledCLIPath()
        let socketPath = Self.makeSocketPath("generic-lifecycle-no-response")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 8)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-lifecycle-no-response-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let server = Self.startMultiConnectionMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionLimit: 8,
            fulfillWhen: { line in
                Self.jsonObject(line)?["method"] as? String == "feed.push"
            }
        ) { line in
            guard let payload = Self.jsonObject(line) else {
                return "OK"
            }
            guard let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "feed.push" {
                return nil
            }
            guard let id = payload["id"] as? String else {
                return Self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return Self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "surface.resume.set":
                return Self.v2Response(id: id, ok: true, result: ["ok": true])
            default:
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unrecognized_method",
                    "message": "unexpected method: \(method)",
                ])
            }
        }

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "kiro", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_AGENT_LAUNCH_KIND": "kiro",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/Users/example/.cargo/bin/kiro-cli",
                "CMUX_AGENT_LAUNCH_ARGV_B64": Self.base64NULSeparated([
                    "/Users/example/.cargo/bin/kiro-cli",
                    "chat",
                    "--agent",
                    "cmux",
                    "--resume-id",
                    "old-session",
                ]),
                "CMUX_AGENT_LAUNCH_CWD": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_SOCKET_PASSWORD": "test-password",
            ],
            standardInput: #"{"session_id":"kiro-lifecycle-no-response","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 0.5
        )

        #expect(server.wait(timeout: 5), "socket server did not observe lifecycle feed.push")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(
            state.snapshot().contains { $0.contains(#""method":"feed.push""#) },
            "Expected lifecycle hook to still emit Feed telemetry"
        )
    }

    @Test func nonActionableFeedHookDoesNotBlockWhenAcceptedSocketStopsReading() throws {
        let cliPath = try Self.bundledCLIPath()
        let socketPath = Self.makeSocketPath("feed-no-read")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feed-no-read-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let server = Self.startAcceptedSocketThatDoesNotRead(listenerFD: listenerFD, holdFor: 1.0)
        let largeToolInput = String(repeating: "x", count: 8 * 1024 * 1024)
        let input = """
        {"hook_event_name":"PreToolUse","session_id":"codex-session-no-read","cwd":"\(root.path)","tool_name":"apply_patch","tool_input":{"payload":"\(largeToolInput)"}}
        """

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "codex", "--event", "PreToolUse"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                "CMUX_CODEX_PID": "626262",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: input,
            timeout: 0.5
        )

        #expect(server.wait(timeout: 5), "socket server did not accept feed.push connection")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }

    private static func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: BundleProbe.self)
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

        throw NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Bundled cmux CLI not found in \(appBundleURL.path)",
        ])
    }

    private static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private static func bindUnixSocket(at path: String, backlog: Int32) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("failed to create Unix socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "socket path too long: \(path)",
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
            throw posixError("failed to bind Unix socket")
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            Darwin.close(fd)
            throw posixError("failed to listen on Unix socket")
        }
        return fd
    }

    private static func startMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> MockSocketServer {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var didFulfill = false
            func fulfillOnce() {
                if !didFulfill {
                    didFulfill = true
                    handled.signal()
                }
            }

            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                fulfillOnce()
                return
            }
            defer { Darwin.close(clientFD) }

            readLines(from: clientFD) { line in
                state.append(line)
                if fulfillWhen?(line) == true {
                    fulfillOnce()
                }
                guard let responsePayload = handler(line) else { return }
                writeLine(responsePayload, to: clientFD)
            }
        }
        return MockSocketServer(handled: handled)
    }

    private static func startMultiConnectionMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionLimit: Int,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> MockSocketServer {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fulfillmentLock = NSLock()
            var didFulfill = false
            func fulfillOnce() {
                fulfillmentLock.lock()
                let shouldFulfill = !didFulfill
                if shouldFulfill {
                    didFulfill = true
                }
                fulfillmentLock.unlock()
                if shouldFulfill {
                    handled.signal()
                }
            }

            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    fulfillOnce()
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    readLines(from: clientFD) { line in
                        state.append(line)
                        if fulfillWhen?(line) == true {
                            fulfillOnce()
                        }
                        guard let responsePayload = handler(line) else { return }
                        writeLine(responsePayload, to: clientFD)
                    }
                }
            }
        }
        return MockSocketServer(handled: handled)
    }

    private static func startAcceptedSocketThatDoesNotRead(listenerFD: Int32, holdFor: TimeInterval) -> MockSocketServer {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.signal()
                return
            }
            handled.signal()
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + holdFor)
            Darwin.close(clientFD)
        }
        return MockSocketServer(handled: handled)
    }

    private static func readLines(from fd: Int32, handle: (String) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
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
                handle(line)
            }
        }
    }

    private static func writeLine(_ line: String, to fd: Int32) {
        let response = line + "\n"
        _ = response.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }
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

    private static func surfaceListResponse(id: String, surfaceId: String) -> String {
        v2Response(
            id: id,
            ok: true,
            result: ["surfaces": [["id": surfaceId, "ref": "surface:1", "focused": true]]]
        )
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func base64NULSeparated(_ values: [String]) -> String {
        values.joined(separator: "\0").data(using: .utf8)?.base64EncodedString() ?? ""
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdinHandle: FileHandle?
        let stdinURL: URL?
        if let standardInput {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-test-stdin-\(UUID().uuidString).json")
            do {
                try Data(standardInput.utf8).write(to: url)
                let handle = try FileHandle(forReadingFrom: url)
                process.standardInput = handle
                stdinHandle = handle
                stdinURL = url
            } catch {
                try? FileManager.default.removeItem(at: url)
                return ProcessRunResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
            }
        } else {
            stdinHandle = nil
            stdinURL = nil
        }
        defer {
            try? stdinHandle?.close()
            if let stdinURL {
                try? FileManager.default.removeItem(at: stdinURL)
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }

        let timedOut = finished.wait(timeout: .now() + timeout) != .success
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(message): errno \(errno)",
        ])
    }
}
