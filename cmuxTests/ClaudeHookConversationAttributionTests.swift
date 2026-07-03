import Darwin
import Dispatch
import Foundation
import XCTest

/// Regression coverage for
/// https://github.com/manaflow-ai/cmux/issues/7132 — "Sidebar conversation
/// subtitle attributed to the wrong workspace".
///
/// In iMessage mode the sidebar subtitle falls through to
/// `Workspace.latestConversationMessage`, which the app records strictly by the
/// `workspace_id` carried on the Claude `Stop` feed event
/// (`TerminalController.v2ApplyIMessageModeSideEffects` →
/// `handleAssistantFinalMessage`). The bug is upstream in the CLI: when a
/// `Stop` hook cannot authoritatively resolve its own workspace (no mapped
/// session, no TTY/PID binding, and no `CMUX_WORKSPACE_ID` — the detached /
/// shared-daemon case, cf. #7100), `runClaudeHook` falls through to
/// `workspace.current` (the *focused* workspace) and then stamps that focused
/// id onto its feed telemetry — even though the very same event's visible
/// status mutation is correctly suppressed because the resolved surface is
/// non-authoritative. The feed telemetry then records one workspace's assistant
/// message onto whichever workspace happens to be selected.
///
/// The generic-agent hook path (`runGenericAgentHook`) already returns `nil`
/// (dropping the event) when workspace identity is unknown; these tests pin the
/// Claude path to the same "attribute to the emitter or nowhere — never the
/// focused workspace" contract, mirroring the surface-less notification rule in
/// #7133.
///
/// Uses XCTest (not Swift Testing) deliberately: the app-host unit-test lane
/// gates on the XCTest `Executed … (N unexpected)` summary, so a regression
/// must fail as an XCTest assertion to turn CI red.
///
/// Exercises the real bundled `cmux` CLI against a mock socket so the assertion
/// is on the actual `feed.push` payload the app would receive.
final class ClaudeHookConversationAttributionTests: XCTestCase {
    private static let focusedWorkspaceId = "99999999-9999-9999-9999-999999999999"
    private static let focusedSurfaceId = "98989898-9898-9898-9898-989898989898"
    private static let callerWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let callerSurfaceId = "22222222-2222-2222-2222-222222222222"
    /// A `CMUX_SURFACE_ID` that exists in no listed workspace — enough to clear
    /// the "no cmux target" hook guard while forcing a non-authoritative surface
    /// resolution, exactly like a detached/re-hosted session's leaked env.
    private static let strayEnvSurfaceId = "55555555-5555-5555-5555-555555555555"

    /// A `Stop` hook whose emitting workspace cannot be authoritatively resolved
    /// must NOT attribute its conversation message to the focused workspace.
    func testStopWithoutIdentityDoesNotAttributeToFocusedWorkspace() throws {
        let capture = try runClaudeStopHook(
            callerWorkspaceId: nil,
            surfaceEnvId: Self.strayEnvSurfaceId
        )
        let event = try XCTUnwrap(
            capture.feedEvent,
            "Expected the Stop hook to emit a feed.push, saw \(capture.commands)"
        )
        let attributed = event["workspace_id"] as? String
        // Pre-fix the resolver falls through to `workspace.current`
        // (`focusedWorkspaceId`) and stamps it here; the fix drops attribution
        // entirely so the message is never mis-homed onto the selected workspace.
        XCTAssertNil(
            attributed,
            "Stop feed telemetry must omit workspace_id when the emitting workspace is unknown; got \(String(describing: attributed)) (focused=\(Self.focusedWorkspaceId))"
        )
    }

    /// A stale or malformed caller workspace value may still make the resolver
    /// fall back to the focused workspace, but that fallback must not become feed
    /// telemetry attribution just because the original env value was non-empty.
    func testStopWithInvalidCallerWorkspaceDoesNotAttributeToFocusedFallback() throws {
        let capture = try runClaudeStopHook(
            callerWorkspaceId: "not-a-workspace",
            surfaceEnvId: Self.strayEnvSurfaceId
        )
        let event = try XCTUnwrap(
            capture.feedEvent,
            "Expected the Stop hook to emit a feed.push, saw \(capture.commands)"
        )
        XCTAssertNil(
            event["workspace_id"] as? String,
            "Invalid caller workspace must not make focused fallback authoritative; got \(String(describing: event["workspace_id"]))"
        )
        XCTAssertTrue(
            capture.commands.contains { $0.contains("\"workspace.current\"") },
            "Invalid caller workspace should still exercise the focused fallback; saw \(capture.commands)"
        )
    }

    /// The caller's own `CMUX_WORKSPACE_ID` stays an authoritative attribution
    /// source: the normal per-surface case must keep recording the conversation
    /// subtitle on the caller's workspace. Guards against the fix over-dropping.
    func testStopWithCallerWorkspaceStaysAttributedToCaller() throws {
        let capture = try runClaudeStopHook(
            callerWorkspaceId: Self.callerWorkspaceId,
            surfaceEnvId: Self.callerSurfaceId
        )
        let event = try XCTUnwrap(
            capture.feedEvent,
            "Expected the Stop hook to emit a feed.push, saw \(capture.commands)"
        )
        XCTAssertEqual(
            event["workspace_id"] as? String,
            Self.callerWorkspaceId,
            "Stop feed telemetry must keep the caller's own workspace, got \(String(describing: event["workspace_id"]))"
        )
        // The caller's env is authoritative, so the focused workspace must never
        // be consulted.
        XCTAssertFalse(
            capture.commands.contains { $0.contains("\"workspace.current\"") },
            "Caller-owned Stop hook must not fall back to workspace.current; saw \(capture.commands)"
        )
    }

    /// When the caller's `CMUX_WORKSPACE_ID` is authoritative but its surface is
    /// only a focused/first fallback (the leaked `CMUX_SURFACE_ID` no longer
    /// lists), the workspace attribution must survive — the fix keys on the
    /// authoritative *workspace*, not merely on an authoritative surface, so the
    /// normal per-surface subtitle is not dropped.
    func testStopWithCallerWorkspaceSurvivesNonAuthoritativeSurface() throws {
        let capture = try runClaudeStopHook(
            callerWorkspaceId: Self.callerWorkspaceId,
            surfaceEnvId: Self.strayEnvSurfaceId
        )
        let event = try XCTUnwrap(
            capture.feedEvent,
            "Expected the Stop hook to emit a feed.push, saw \(capture.commands)"
        )
        XCTAssertEqual(
            event["workspace_id"] as? String,
            Self.callerWorkspaceId,
            "Authoritative caller workspace must survive a non-authoritative surface, got \(String(describing: event["workspace_id"]))"
        )
        XCTAssertNotEqual(event["workspace_id"] as? String, Self.focusedWorkspaceId)
    }

    // MARK: - Harness

    private struct FeedCapture {
        let feedEvent: [String: Any]?
        let commands: [String]
    }

    private func runClaudeStopHook(
        callerWorkspaceId: String?,
        surfaceEnvId: String
    ) throws -> FeedCapture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-7132-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = Self.makeSocketPath("cv7132")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockServerState()
        Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                // v1 space-delimited commands (set_status, notify_target_async, …).
                return "OK"
            }
            switch method {
            case "workspace.current":
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": Self.focusedWorkspaceId])
            case "surface.list":
                let params = payload["params"] as? [String: Any]
                let workspaceId = params?["workspace_id"] as? String
                return Self.v2Response(id: id, ok: true, result: ["surfaces": Self.surfaces(forWorkspace: workspaceId)])
            case "system.top":
                return Self.v2Response(id: id, ok: true, result: ["windows": []])
            case "debug.terminals":
                return Self.v2Response(id: id, ok: true, result: ["terminals": []])
            case "feed.push":
                return Self.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return Self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            default:
                // Tolerate anything else the hook happens to probe.
                return Self.v2Response(id: id, ok: true, result: [:])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        for key in [
            "CMUX_SOCKET",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_SOCKET_PATH",
            "CMUX_PANEL_ID",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
            "CMUX_WINDOW_ID",
            "CMUX_WORKSPACE_ID",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = root.path
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SURFACE_ID"] = surfaceEnvId
        environment["CMUX_CLAUDE_HOOK_STATE_PATH"] = root.appendingPathComponent("claude-hook-sessions.json").path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        if let callerWorkspaceId {
            environment["CMUX_WORKSPACE_ID"] = callerWorkspaceId
        }

        let sessionId = "claude-7132-\(UUID().uuidString)"
        let stdin = #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"Stop"}"#

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: stdin,
            timeout: 10
        )
        XCTAssertFalse(result.timedOut, "hooks claude stop timed out; stderr=\(result.stderr)")

        // Feed telemetry is delivered best-effort on a separate one-way socket
        // connection; the CLI writes it before exiting but the mock records it
        // asynchronously, so poll the recorded commands for the Stop event.
        let event = Self.pollForStopFeedEvent(state: state, timeout: 5)
        return FeedCapture(feedEvent: event, commands: state.snapshot())
    }

    private static func surfaces(forWorkspace workspaceId: String?) -> [[String: Any]] {
        if workspaceId == focusedWorkspaceId {
            return [["id": focusedSurfaceId, "ref": "surface:1", "focused": true]]
        }
        if workspaceId == callerWorkspaceId {
            return [["id": callerSurfaceId, "ref": "surface:1", "focused": true]]
        }
        return []
    }

    private static func pollForStopFeedEvent(state: MockServerState, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = stopFeedEvent(in: state.snapshot()) {
                return event
            }
            usleep(50_000)
        }
        return stopFeedEvent(in: state.snapshot())
    }

    private static func stopFeedEvent(in commands: [String]) -> [String: Any]? {
        for line in commands {
            guard let payload = jsonObject(line),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any],
                  let event = params["event"] as? [String: Any],
                  (event["hook_event_name"] as? String) == "Stop" else {
                continue
            }
            return event
        }
        return nil
    }

    private final class MockServerState: @unchecked Sendable {
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
        let timedOut: Bool
    }

    private final class BundleToken {}

    private static func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
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
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(code))
        }
        return fd
    }

    private static func startMockServer(
        listenerFD: Int32,
        state: MockServerState,
        handler: @escaping @Sendable (String) -> String
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    if errno == EINTR { continue }
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        Darwin.close(clientFD)
                    }

                    func writeResponse(_ response: String) {
                        let line = response + "\n"
                        _ = line.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
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
                            state.append(line)
                            writeResponse(handler(line))
                        }
                    }
                }
            }
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
