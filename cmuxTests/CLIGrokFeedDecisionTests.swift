import Darwin
import Foundation
import Testing

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/6303.
///
/// Grok Build honors a *native* PreToolUse blocking decision of the shape
/// `{"decision":"allow"|"deny","reason":"…"}` — the same shape Antigravity
/// uses — and ignores Claude's `hookSpecificOutput.permissionDecision` /
/// `"approve"` shape. Before the fix, `cmux hooks feed --source grok` routed
/// the resolved Feed decision through `nonClaudePreToolDecision`, emitting the
/// Claude-shaped JSON that Grok could not parse. The PreToolUse hook therefore
/// only ever cleared via the 120s fail-open timeout, adding ~2 minutes of dead
/// time to every approved `Write`/`Bash`.
///
/// These tests drive the real bundled CLI against a mock Feed socket that
/// resolves the pending decision, and assert the emitted stdout is the
/// Grok-native shape (not the Claude shape).
@Suite(.serialized)
struct CLIGrokFeedDecisionTests {
    final class BundleProbe {}

    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @Test func grokAllowDecisionUsesNativeShape() throws {
        let stdout = try runFeedDecision(toolName: "Write", mode: "once")
        let json = try #require(Self.jsonObject(stdout))
        // Grok-native shape: top-level `decision` is `allow`/`deny`, NOT the
        // Claude `approve`/`block`, and there is no `hookSpecificOutput`.
        #expect(json["decision"] as? String == "allow")
        #expect(json["reason"] as? String == "User approved via cmux Feed.")
        #expect(json["hookSpecificOutput"] == nil)
        #expect(json.count == 2)
    }

    @Test func grokDenyDecisionUsesNativeShape() throws {
        let stdout = try runFeedDecision(toolName: "Write", mode: "deny")
        let json = try #require(Self.jsonObject(stdout))
        #expect(json["decision"] as? String == "deny")
        #expect(json["reason"] as? String == "User denied permission via cmux Feed.")
        #expect(json["hookSpecificOutput"] == nil)
        #expect(json.count == 2)
    }

    /// Drives `cmux hooks feed --source grok --event PreToolUse` against a
    /// mock socket that resolves the pending Feed card with the given
    /// permission `mode`, and returns the CLI's stdout.
    private func runFeedDecision(toolName: String, mode: String) throws -> String {
        let cliPath = try Self.bundledCLIPath()
        let socketPath = Self.makeSocketPath("grok-feed-\(mode.prefix(4))")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 4)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-feed-\(mode)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        Self.startMockFeedServer(listenerFD: listenerFD, resolveMode: mode)

        let input = """
        {"hook_event_name":"PreToolUse","session_id":"grok-session-6303","cwd":"\(root.path)","tool_name":"\(toolName)","tool_input":{"path":"\(root.appendingPathComponent("README.md").path)"}}
        """
        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "grok", "--event", "PreToolUse"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                "CMUX_GROK_PID": "626262",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: input,
            timeout: 15
        )

        #expect(!result.timedOut, Comment(rawValue: "timed out; stderr: \(result.stderr)"))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        return result.stdout
    }

    /// Accepts a single client connection and, for every `feed.push` request,
    /// replies with a resolved permission decision. All other JSON requests
    /// (auth handshake, etc.) get a generic ok so the CLI proceeds.
    private static func startMockFeedServer(listenerFD: Int32, resolveMode: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            readLines(from: clientFD) { line in
                guard let payload = jsonObject(line) else { return }
                let id = payload["id"] as? String ?? "unknown"
                if payload["method"] as? String == "feed.push" {
                    writeLine(
                        v2Response(
                            id: id,
                            ok: true,
                            result: [
                                "status": "resolved",
                                "decision": ["kind": "permission", "mode": resolveMode],
                            ]
                        ),
                        to: clientFD
                    )
                } else if payload["id"] != nil {
                    writeLine(v2Response(id: id, ok: true, result: [:]), to: clientFD)
                }
            }
        }
    }

    // MARK: - Shared subprocess + socket helpers (mirrors CLIHookNoResponseTests)

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
            .appendingPathComponent("cli-\(name.prefix(10))-\(shortID).sock")
            .path
    }

    private static func bindUnixSocket(at path: String, backlog: Int32) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("failed to create Unix socket") }

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
        guard Darwin.listen(fd, backlog) == 0 else {
            Darwin.close(fd)
            throw posixError("failed to listen on Unix socket")
        }
        return fd
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
        result: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
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
        NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(message): errno \(errno)",
        ])
    }
}
