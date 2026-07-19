import Darwin
import Dispatch
import Foundation
import Testing

@Suite(.serialized)
struct ClaudeHookFeedTelemetrySwiftTests {
    @Test func sessionStartFeedTelemetryUsesResolvedTTYSurface() throws {
        let context = try FeedTelemetryTestContext(name: "feed")
        defer { _ = context }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let leakedSurfaceID = "22222222-2222-2222-2222-222222222222"
        let resolvedSurfaceID = "33333333-3333-3333-3333-333333333333"
        let ttyName = "ttys-claude-feed-surface"
        let feedSeen = DispatchSemaphore(value: 0)
        startServer(
            listenerFD: context.listenerFD,
            state: context.state,
            workspaceID: workspaceID,
            focusedSurfaceID: leakedSurfaceID,
            ttyName: ttyName,
            resolvedSurfaceID: resolvedSurfaceID,
            feedSeen: feedSeen
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: context.environment(
                workspaceID: workspaceID,
                surfaceID: leakedSurfaceID,
                ttyName: ttyName
            ),
            standardInput: #"{"session_id":"claude-feed-session","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(result.timedOut == false, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(feedSeen.wait(timeout: .now() + 5) == .success, "Expected feed.push, saw \(context.state.commandsSnapshot())")
        let event = try #require(
            context.state.feedEventsSnapshot().last { $0["hook_event_name"] as? String == "SessionStart" },
            "Expected SessionStart feed telemetry, saw \(context.state.commandsSnapshot())"
        )
        #expect(
            event["surface_id"] as? String == resolvedSurfaceID,
            "Feed telemetry must use the resolved agent TTY surface, not leaked CMUX_SURFACE_ID; event=\(event)"
        )
    }

    // Regression for https://github.com/manaflow-ai/cmux/issues/7962: Claude Code
    // renders any plain-text hook stdout as a visible "hook success" block in the
    // conversation transcript — for prompt-submit hooks, a bare "OK" on every
    // prompt. A bare JSON object is consumed as structured hook output with
    // nothing rendered — the same contract the `echo '{}'` no-op fallback in
    // AgentHookDefinitions already relies on — and success is signaled by the
    // exit code, so hook stdout must stay machine-consumable.
    @Test func sessionStartStdoutIsSilentJSONAck() throws {
        let context = try FeedTelemetryTestContext(name: "silent-ack")
        defer { _ = context }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let ttyName = "ttys-claude-silent-ack"
        let feedSeen = DispatchSemaphore(value: 0)
        startServer(
            listenerFD: context.listenerFD,
            state: context.state,
            workspaceID: workspaceID,
            focusedSurfaceID: surfaceID,
            ttyName: ttyName,
            resolvedSurfaceID: surfaceID,
            feedSeen: feedSeen
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: context.environment(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                ttyName: ttyName
            ),
            standardInput: #"{"session_id":"claude-silent-ack-session","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(result.timedOut == false, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }
}

private final class FeedTelemetryTestContext {
    let root: URL
    let socketPath: String
    let listenerFD: Int32
    let state: FeedTelemetryMockState

    init(name: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = makeSocketPath(name)
        do {
            let listenerFD = try bindUnixSocket(at: socketPath)
            self.root = root
            self.socketPath = socketPath
            self.listenerFD = listenerFD
            self.state = FeedTelemetryMockState()
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit {
        Darwin.close(listenerFD)
        unlink(socketPath)
        try? FileManager.default.removeItem(at: root)
    }

    func environment(workspaceID: String, surfaceID: String, ttyName: String) -> [String: String] {
        [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_CLI_TTY_NAME": ttyName,
            "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/claude"]),
        ]
    }
}

private final class FeedTelemetryMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var feedEvents: [[String: Any]] = []

    func appendCommand(_ command: String) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func appendFeedEvent(_ event: [String: Any]) {
        lock.lock()
        feedEvents.append(event)
        lock.unlock()
    }

    func commandsSnapshot() -> [String] {
        lock.lock()
        let value = commands
        lock.unlock()
        return value
    }

    func feedEventsSnapshot() -> [[String: Any]] {
        lock.lock()
        let value = feedEvents
        lock.unlock()
        return value
    }
}

private struct ProcessRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

private func startServer(
    listenerFD: Int32,
    state: FeedTelemetryMockState,
    workspaceID: String,
    focusedSurfaceID: String,
    ttyName: String,
    resolvedSurfaceID: String,
    feedSeen: DispatchSemaphore
) {
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                handleClient(
                    clientFD,
                    state: state,
                    workspaceID: workspaceID,
                    focusedSurfaceID: focusedSurfaceID,
                    ttyName: ttyName,
                    resolvedSurfaceID: resolvedSurfaceID,
                    feedSeen: feedSeen
                )
            }
        }
    }
}

private func handleClient(
    _ clientFD: Int32,
    state: FeedTelemetryMockState,
    workspaceID: String,
    focusedSurfaceID: String,
    ttyName: String,
    resolvedSurfaceID: String,
    feedSeen: DispatchSemaphore
) {
    defer { Darwin.close(clientFD) }

    func writeResponse(_ response: String) {
        let line = response + "\n"
        _ = line.withCString { pointer in
            Darwin.write(clientFD, pointer, strlen(pointer))
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
            state.appendCommand(line)
            writeResponse(
                response(
                    for: line,
                    state: state,
                    workspaceID: workspaceID,
                    focusedSurfaceID: focusedSurfaceID,
                    ttyName: ttyName,
                    resolvedSurfaceID: resolvedSurfaceID,
                    feedSeen: feedSeen
                )
            )
        }
    }
}

private func response(
    for line: String,
    state: FeedTelemetryMockState,
    workspaceID: String,
    focusedSurfaceID: String,
    ttyName: String,
    resolvedSurfaceID: String,
    feedSeen: DispatchSemaphore
) -> String {
    guard let payload = jsonObject(line),
          let method = payload["method"] as? String else {
        return "OK"
    }
    if method == "feed.push" {
        if let params = payload["params"] as? [String: Any],
           let event = params["event"] as? [String: Any] {
            state.appendFeedEvent(event)
            feedSeen.signal()
        }
        return "OK"
    }
    guard let id = payload["id"] as? String else {
        return "OK"
    }
    switch method {
    case "surface.list":
        return v2Response(id: id, ok: true, result: [
            "surfaces": [
                ["id": focusedSurfaceID, "ref": "surface:1", "focused": true],
                ["id": resolvedSurfaceID, "ref": "surface:2", "focused": false],
            ],
        ])
    case "debug.terminals":
        return v2Response(id: id, ok: true, result: [
            "terminals": [[
                "tty": ttyName,
                "workspace_id": workspaceID,
                "surface_id": resolvedSurfaceID,
            ]],
        ])
    case "surface.resume.set":
        return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
    default:
        return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": method])
    }
}

private func makeSocketPath(_ name: String) -> String {
    let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cli-\(name)-\(shortID).sock")
        .path
}

private func bindUnixSocket(at path: String) throws -> Int32 {
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
        pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { pathBuffer in
            for index in 0..<utf8.count {
                pathBuffer[index] = CChar(bitPattern: utf8[index])
            }
            pathBuffer[utf8.count] = 0
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

private func base64NULSeparated(_ values: [String]) -> String {
    var bytes: [UInt8] = []
    for value in values {
        bytes.append(contentsOf: value.utf8)
        bytes.append(0)
    }
    return Data(bytes).base64EncodedString()
}

private func runProcess(
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

    var stdinPipe: Pipe?
    if let standardInput {
        let input = Pipe()
        process.standardInput = input
        stdinPipe = input
        input.fileHandleForWriting.write(Data(standardInput.utf8))
        input.fileHandleForWriting.closeFile()
    }

    let exitSignal = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exitSignal.signal() }
    do {
        try process.run()
    } catch {
        return ProcessRunResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
    }
    _ = stdinPipe
    let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
    if timedOut {
        process.terminate()
        _ = exitSignal.wait(timeout: .now() + 1)
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

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func v2Response(
    id: String,
    ok: Bool,
    result: [String: Any]? = nil,
    error: [String: Any]? = nil
) -> String {
    var object: [String: Any] = [
        "id": id,
        "ok": ok,
    ]
    if let result { object["result"] = result }
    if let error { object["error"] = error }
    let data = try? JSONSerialization.data(withJSONObject: object)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
}
