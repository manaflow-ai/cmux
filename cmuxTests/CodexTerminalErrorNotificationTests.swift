import Darwin
import Foundation
import Testing

private final class CodexTerminalErrorBundleMarker: NSObject {}

@Suite("Codex terminal error notifications", .serialized)
struct CodexTerminalErrorNotificationTests {
    @Test("A persisted terminal error wins over partial assistant output")
    func nestedTurnCompleteErrorNotifies() throws {
        let root = URL(
            fileURLWithPath: "/tmp/cmux-cterr-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketPath = root.appendingPathComponent("c.sock").path
        let transcriptURL = root.appendingPathComponent("rollout.jsonl")
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let sessionID = "codex-session-terminal-error"
        let turnID = "turn-terminal-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"timestamp":"2026-07-15T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"\(root.path)"}}
        {"timestamp":"2026-07-15T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\(turnID)","started_at":1784102129}}
        {"timestamp":"2026-07-15T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial response"}]}}
        {"timestamp":"2026-07-15T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turnID)","last_agent_message":"Partial response","error":{"message":"Selected model is at capacity. Please try a different model.","codex_error_info":"server_overloaded"}}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let server = try CodexTerminalErrorSocketServer(
            socketPath: socketPath,
            surfaceID: surfaceID
        )
        server.start()
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = surfaceID
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionID)","turn_id":"\(turnID)","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Partial response"}
        """
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: CodexTerminalErrorBundleMarker.self
        )
        let result = CodexTerminalErrorProcess().run(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        #expect(!result.timedOut, "\(result.stderr)")
        #expect(result.status == 0, "\(result.stderr)")
        #expect(
            server.commands.contains { command in
                command.contains(
                    "notify_target \(workspaceID) \(surfaceID) Codex|Error|Selected model is at capacity. Please try a different model."
                )
            },
            "Expected the nested terminal error to notify, saw \(server.commands)"
        )
        #expect(
            server.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100")
            },
            "Expected the nested terminal error to set error status, saw \(server.commands)"
        )
    }
}

private final class CodexTerminalErrorSocketServer: @unchecked Sendable {
    private let listenerFD: Int32
    private let surfaceID: String
    private let lock = NSLock()
    private var recordedCommands: [String] = []
    private let finished = DispatchSemaphore(value: 0)

    var commands: [String] {
        lock.withLock { recordedCommands }
    }

    init(socketPath: String, surfaceID: String) throws {
        unlink(socketPath)
        let listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw Self.posixError("socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            Darwin.close(listenerFD)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Socket path exceeds sockaddr_un.sun_path: \(socketPath)"]
            )
        }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(
                    UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self),
                    source,
                    maxPathLength - 1
                )
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listenerFD, 1) == 0 else {
            Darwin.close(listenerFD)
            throw Self.posixError("bind/listen")
        }
        self.listenerFD = listenerFD
        self.surfaceID = surfaceID
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { finished.signal() }
            var address = sockaddr_un()
            var addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenerFD, $0, &addressLength)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

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

                while let newline = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newline.lowerBound)
                    pending.removeSubrange(0...newline.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    lock.withLock { recordedCommands.append(line) }
                    let response = response(for: line) + "\n"
                    guard Self.writeAll(response, to: clientFD) else { return }
                }
            }
        }
    }

    func stop() {
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        _ = finished.wait(timeout: .now() + 1)
    }

    private func response(for line: String) -> String {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = payload["id"] as? String else {
            return "OK"
        }
        let response: [String: Any] = [
            "id": id,
            "ok": true,
            "result": ["surfaces": [["id": surfaceID, "ref": surfaceID, "focused": true]]],
        ]
        let responseData = try? JSONSerialization.data(withJSONObject: response)
        return String(data: responseData ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func writeAll(_ string: String, to fd: Int32) -> Bool {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}

private struct CodexTerminalErrorProcess {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String,
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        stdin.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdin.fileHandleForWriting.close()

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                guard finished.wait(timeout: .now() + 1) == .success else {
                    return Result(
                        status: -1,
                        stdout: "",
                        stderr: "Process did not terminate after timeout",
                        timedOut: true
                    )
                }
            }
        }
        return Result(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
