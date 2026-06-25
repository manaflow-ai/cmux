import Foundation
import Testing
import Darwin

/// Behavior tests for the hook-payload source adapter used by agents whose
/// cmux hooks expose recent prompt/assistant text instead of a transcript file.
@Suite struct AutoNamingHookPayloadAdapterTests {
    private let engine = AutoNamingEngine()

    @Test(arguments: [
        "pi",
        "omp"
    ])
    func extractsDirectPromptAndAssistantFields(agent: String) {
        let object: [String: Any] = [
            "session_id": "\(agent)-session",
            "prompt": "Add \(agent) workspace naming",
            "last_assistant_message": "I will summarize the hook transcript."
        ]

        let messages = engine.extractHookMessages(fromPayloadObjects: [object])
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Add \(agent) workspace naming"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will summarize the hook transcript.")
        ])
    }

    @Test func extractsOpenCodeContextMessages() {
        let object: [String: Any] = [
            "session_id": "opencode-session",
            "hook_event_name": "session.idle",
            "context": [
                "lastUserMessage": "Implement OpenCode workspace naming",
                "assistantPreamble": "I found the plugin event stream."
            ]
        ]

        let messages = engine.extractHookMessages(fromPayloadObjects: [object])
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Implement OpenCode workspace naming"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I found the plugin event stream.")
        ])
    }

    @Test func hookMessageLineEquivalentsReachSharedThrottleFloor() {
        let messages = [
            AutoNamingTranscriptMessage(role: "user", text: "Name this workspace"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I can summarize it.")
        ]

        let lineCount = engine.hookMessageLineEquivalentCount(messages)
        #expect(lineCount == engine.config.minTranscriptLines)

        let decision = engine.throttleDecision(
            snapshot: AutoNamingSessionSnapshot(),
            transcriptLineCount: lineCount,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(decision == .proceed(baseline: lineCount))
    }

    @Test func hookMessageLineEquivalentsUseMonotonicTotalWhenCacheIsCapped() {
        let messages = [
            AutoNamingTranscriptMessage(role: "user", text: "Newest request"),
            AutoNamingTranscriptMessage(role: "assistant", text: "Newest answer")
        ]

        let lineCount = engine.hookMessageLineEquivalentCount(messages, totalMessageCount: 40)
        #expect(lineCount == 40 * engine.config.minLineGrowth)
    }

    @Test func sharedEnginePipelineParityWithHookContent() throws {
        let messages = engine.extractHookMessages(fromPayloadObjects: [[
            "prompt": "Name Pi and OpenCode sessions",
            "assistant_response": "Use the same auto-naming engine."
        ]])
        let context = try #require(engine.buildContext(from: messages))
        let prompt = engine.buildPrompt(currentTitle: nil, context: context)
        #expect(prompt.contains("Name Pi and OpenCode sessions"))
        #expect(prompt.contains("Use the same auto-naming engine."))
        #expect(!prompt.contains("current title"))
    }

    @Test func openCodeAutoNameSkipsEmptyCacheWithoutReportingExtractionFailure() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let socketPath = Self.makeSocketPath("opencode-auto-name-empty")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        let state = MockSocketState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-auto-name-empty-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "opencode-empty-cache-session"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let storeURL = root.appendingPathComponent("opencode-hook-sessions.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: storeURL, options: .atomic)

        let serverDone = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            guard method == "workspace.set_auto_title" else {
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            if params["probe"] as? Bool == true {
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "enabled": true,
                        "workspace_user_owned": false,
                        "summarizer_agent": "auto",
                        "auto_naming_language_name": "English",
                        "auto_naming_language_tag": "en",
                    ]
                )
            }
            return Self.v2Response(id: id, ok: true, result: ["ok": true])
        }

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLAUDE_HOOK_STATE_PATH": storeURL.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC": "2",
        ]
        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "opencode", "auto-name",
                "--session", sessionId,
                "--workspace", workspaceId,
                "--surface", surfaceId,
            ],
            environment: environment
        )

        #expect(serverDone.wait(timeout: .now() + 5) == .success)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == "OK\n")

        let autoTitleRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = Self.jsonObject(command),
                  payload["method"] as? String == "workspace.set_auto_title" else { return nil }
            return payload["params"] as? [String: Any]
        }
        #expect(
            autoTitleRequests.filter { $0["probe"] as? Bool == true }.count == 1,
            "expected exactly one auto-name probe, saw \(state.snapshot())"
        )
        #expect(
            !autoTitleRequests.contains { $0["failure"] as? String == "extraction_failed" },
            "an empty hook-message cache is an expected no-op and must not surface as a Settings error: \(state.snapshot())"
        )
    }

    // Test server state crosses a DispatchQueue callback and is read after the socket drains.
    private final class MockSocketState: @unchecked Sendable {
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

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
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
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else { throw POSIXError(.ENAMETOOLONG) }
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
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func startMockServer(
        listenerFD: Int32,
        state: MockSocketState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                done.signal()
                return
            }
            defer {
                Darwin.close(clientFD)
                done.signal()
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
        return done
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
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

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
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
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error))
        }
        process.waitUntilExit()
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
