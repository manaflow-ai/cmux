import Darwin
import Foundation
import Testing

@Suite("CLI Copilot hook feed")
struct CLICopilotHookFeedTests {
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

    @Test func copilotHookInstallWritesToHooksSubdirectory() throws {
        let cliPath = try Self.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-copilot-hook-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "copilot", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let hookURL = root
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any],
            "Expected hook file at ~/.copilot/hooks/cmux.json"
        )

        #expect(json["version"] as? Int == 1)
        let hooks = try #require(json["hooks"] as? [String: Any])

        #expect(hooks["sessionStart"] != nil, "Missing sessionStart hook")
        #expect(hooks["userPromptSubmitted"] != nil, "Missing userPromptSubmitted hook")
        #expect(hooks["agentStop"] != nil, "Missing agentStop hook")
        #expect(hooks["errorOccurred"] != nil, "Missing errorOccurred hook")
        #expect(hooks["Notification"] == nil, "Copilot notifications must not be installed as stop hooks")
        #expect(hooks["sessionEnd"] != nil, "Missing sessionEnd hook")
        #expect(hooks["SessionStart"] == nil, "Copilot must use canonical camelCase hook names")
        #expect(hooks["Stop"] == nil, "Copilot must use canonical agentStop/errorOccurred hook names")
        #expect(hooks["SessionEnd"] == nil, "Copilot must use canonical camelCase hook names")
        #expect(hooks["PreToolUse"] == nil, "Copilot must install canonical preToolUse hooks")
        #expect(hooks["PermissionRequest"] == nil, "Copilot must install canonical permissionRequest hooks")
        let errorOccurred = try #require(hooks["errorOccurred"] as? [[String: Any]])
        #expect(
            errorOccurred.contains {
                ($0["bash"] as? String)?.contains("hooks copilot notification") == true
                    && ($0["type"] as? String) == "command"
                    && $0["command"] == nil
            },
            "Expected errorOccurred to route through notification handling, saw \(errorOccurred)"
        )
        let preToolUse = try #require(hooks["preToolUse"] as? [[String: Any]])
        #expect(
            preToolUse.contains {
                ($0["bash"] as? String)?.contains("hooks feed --source copilot --event preToolUse") == true
                    && ($0["type"] as? String) == "command"
                    && ($0["timeoutSec"] as? Int) == 125
                    && $0["command"] == nil
                    && $0["hooks"] == nil
            },
            "Expected direct preToolUse bash hook with timeout slack, saw \(preToolUse)"
        )
        let permissionRequest = try #require(hooks["permissionRequest"] as? [[String: Any]])
        #expect(
            permissionRequest.contains {
                ($0["bash"] as? String)?.contains("hooks feed --source copilot --event permissionRequest") == true
                    && ($0["type"] as? String) == "command"
                    && ($0["timeoutSec"] as? Int) == 125
                    && $0["command"] == nil
                    && $0["hooks"] == nil
            },
            "Expected direct permissionRequest bash hook with timeout slack, saw \(permissionRequest)"
        )
    }

    @Test func copilotFeedDecisionEmitsPreToolUsePermissionDecision() throws {
        func runCopilotDecision(mode: String, event: String = "preToolUse") throws -> (ProcessRunResult, [String: Any]) {
            let cliPath = try Self.bundledCLIPath()
            let socketPath = Self.makeSocketPath("copilot-feed-decision")
            let listenerFD = try Self.bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-copilot-feed-decision-\(UUID().uuidString)", isDirectory: true)
            let workspaceId = "33333333-3333-3333-3333-333333333333"
            let surfaceId = "44444444-4444-4444-4444-444444444444"

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let server = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = Self.jsonObject(line) else {
                    return Self.malformedRequestResponse(raw: line)
                }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return Self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                #expect(method == "feed.push")
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "status": "resolved",
                        "decision": ["kind": "permission", "mode": mode],
                    ]
                )
            }

            let result = Self.runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", "copilot", "--event", event],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": workspaceId,
                    "CMUX_SURFACE_ID": surfaceId,
                    "CMUX_COPILOT_PID": "525252",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"sessionId":"copilot-session-123","cwd":"\#(root.path)","toolName":"bash","toolArgs":{"command":"touch \#(root.appendingPathComponent("README.md").path)"}}"#,
                timeout: 5
            )
            #expect(server.wait(timeout: 5), "socket server did not observe feed.push")

            let feedEvents = state.snapshot().compactMap { command -> [String: Any]? in
                guard let payload = Self.jsonObject(command),
                      payload["method"] as? String == "feed.push",
                      let params = payload["params"] as? [String: Any],
                      let event = params["event"] as? [String: Any] else {
                    return nil
                }
                return event
            }
            #expect(feedEvents.count == 1, "Expected one Copilot Feed event, saw \(state.snapshot())")
            return (result, try #require(feedEvents.first))
        }

        let (allow, allowEvent) = try runCopilotDecision(mode: "once")
        #expect(!allow.timedOut, Comment(rawValue: allow.stderr))
        #expect(allow.status == 0, Comment(rawValue: allow.stderr))
        #expect(allowEvent["hook_event_name"] as? String == "PermissionRequest")
        #expect(allowEvent["_source"] as? String == "copilot")
        #expect(allowEvent["_ppid"] as? Int == 525252)
        let allowOutput = try #require(Self.jsonObject(allow.stdout))
        #expect(allowOutput["permissionDecision"] as? String == "allow")
        #expect(allowOutput["hookSpecificOutput"] == nil)

        let (deny, _) = try runCopilotDecision(mode: "deny")
        #expect(!deny.timedOut, Comment(rawValue: deny.stderr))
        #expect(deny.status == 0, Comment(rawValue: deny.stderr))
        let denyOutput = try #require(Self.jsonObject(deny.stdout))
        #expect(denyOutput["permissionDecision"] as? String == "deny")
        #expect(denyOutput["permissionDecisionReason"] as? String == "User denied permission via cmux Feed.")
        #expect(denyOutput["hookSpecificOutput"] == nil)

        let (unsupported, _) = try runCopilotDecision(mode: "always")
        #expect(!unsupported.timedOut, Comment(rawValue: unsupported.stderr))
        #expect(unsupported.status == 0, Comment(rawValue: unsupported.stderr))
        let unsupportedOutput = try #require(Self.jsonObject(unsupported.stdout))
        #expect(unsupportedOutput["permissionDecision"] as? String == "deny")
        #expect(unsupportedOutput["permissionDecisionReason"] as? String == "User denied permission via cmux Feed.")
        #expect(unsupportedOutput["hookSpecificOutput"] == nil)

        let (permissionAllow, permissionAllowEvent) = try runCopilotDecision(mode: "once", event: "permissionRequest")
        #expect(!permissionAllow.timedOut, Comment(rawValue: permissionAllow.stderr))
        #expect(permissionAllow.status == 0, Comment(rawValue: permissionAllow.stderr))
        #expect(permissionAllowEvent["hook_event_name"] as? String == "PermissionRequest")
        let permissionAllowOutput = try #require(Self.jsonObject(permissionAllow.stdout))
        #expect(permissionAllowOutput["behavior"] as? String == "allow")
        #expect(permissionAllowOutput["permissionDecision"] == nil)
        #expect(permissionAllowOutput["hookSpecificOutput"] == nil)

        let (permissionDeny, _) = try runCopilotDecision(mode: "deny", event: "permissionRequest")
        #expect(!permissionDeny.timedOut, Comment(rawValue: permissionDeny.stderr))
        #expect(permissionDeny.status == 0, Comment(rawValue: permissionDeny.stderr))
        let permissionDenyOutput = try #require(Self.jsonObject(permissionDeny.stdout))
        #expect(permissionDenyOutput["behavior"] as? String == "deny")
        #expect(permissionDenyOutput["message"] as? String == "User denied permission via cmux Feed.")
        #expect(permissionDenyOutput["permissionDecision"] == nil)
        #expect(permissionDenyOutput["hookSpecificOutput"] == nil)
    }

    private static func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundleProbe.self)
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
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw posixError("failed to bind Unix socket")
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw posixError("failed to listen on Unix socket")
        }
        return fd
    }

    private static func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> MockSocketServer {
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
            defer { Darwin.close(clientFD) }

            readLines(from: clientFD) { line in
                state.append(line)
                writeLine(handler(line), to: clientFD)
                handled.signal()
            }
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

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
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
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"]
        )
    }
}
