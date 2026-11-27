import Darwin
import Foundation
import Testing

/// Regression coverage for the CLI resolving `workspace:N` handle refs before it
/// sends them, whether or not `--window` was given.
///
/// The regression: `normalizeWorkspaceHandle` short-circuited handle refs with
/// `guard windowHandle != nil else { return trimmed }`, so without `--window` the
/// raw ref reached the host as a `workspace_id`. A stale ref then came back as the
/// host's generic `not_found` naming a workspace the caller never typed, while the
/// same ref *with* `--window` failed client-side with the ref itself. That
/// asymmetry is what made https://github.com/manaflow-ai/cmux/issues/13506 hard to
/// diagnose.
///
/// The pass-through is still correct in exactly one case: a remote CLI relay
/// denies `window.list` (`RemoteRelayRoutingSchema`), so the scan cannot run and
/// the relay's host must resolve the ref itself. `windowListDeniedFallsBackToPassThrough`
/// pins that carve-out so the fix cannot regress `cmux ssh`.
@Suite(.serialized)
struct CLIWorkspaceRefResolutionTests {
    /// A stale ref with no `--window` must fail client-side naming the ref, and must
    /// never reach the host as a `workspace_id` the host will misattribute.
    @Test func staleRefWithoutWindowFailsClientSide() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--workspace", Self.staleRef, "--index", "0"],
            topology: .oneWindow
        )

        #expect(result.status != 0, Comment(rawValue: "expected nonzero exit, got \(result.status)"))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("workspace.reorder"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(methods.contains("window.list"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(
            result.stderr.contains(Self.staleRef),
            Comment(rawValue: "stderr should name the unresolvable ref, got: \(result.stderr)")
        )
    }

    /// A live ref with no `--window` must resolve to its UUID client-side, so the
    /// host receives an id it can act on rather than a ref it has to re-resolve.
    @Test func liveRefWithoutWindowResolvesToUUID() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--workspace", Self.liveRef, "--index", "0"],
            topology: .oneWindow
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        let reorder = try #require(requests.last { $0["method"] as? String == "workspace.reorder" })
        let params = try #require(reorder["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.liveWorkspaceId)
        #expect(params["index"] as? Int == 0)
    }

    /// An unresolvable `--before` target must also fail client-side naming that
    /// target. Pre-fix this reached the host, which answered `not_found` against the
    /// *subject* workspace instead (https://github.com/manaflow-ai/cmux/issues/13906).
    @Test func staleBeforeTargetWithoutWindowFailsClientSide() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--workspace", Self.liveRef, "--before", Self.staleRef],
            topology: .oneWindow
        )

        #expect(result.status != 0, Comment(rawValue: "expected nonzero exit, got \(result.status)"))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("workspace.reorder"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(
            result.stderr.contains(Self.staleRef),
            Comment(rawValue: "stderr should name the unresolvable target ref, got: \(result.stderr)")
        )
    }

    /// When `window.list` is unavailable the CLI cannot enumerate every window, so a
    /// ref the parameterless `workspace.list` snapshot did not contain must keep the
    /// historical pass-through instead of inventing a "not found". A remote CLI relay
    /// denies `window.list` outright, and its host still resolves the ref.
    ///
    /// The ref here is one the snapshot does not hold: a ref the snapshot does hold
    /// resolves to its UUID before `window.list` is ever consulted.
    @Test func windowListDeniedFallsBackToPassThrough() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--workspace", Self.staleRef, "--index", "0"],
            topology: .windowListDenied
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods.contains("window.list"), Comment(rawValue: methods.joined(separator: ",")))
        let reorder = try #require(requests.last { $0["method"] as? String == "workspace.reorder" })
        let params = try #require(reorder["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.staleRef)
        #expect(
            !result.stderr.contains("not found"),
            Comment(rawValue: "a denied window.list must not be reported as absence: \(result.stderr)")
        )
    }

    /// A window that goes away between `window.list` and its `workspace.list` leaves
    /// a hole in the scan. The CLI must hand the ref to the host rather than claim it
    /// is absent — a ref living in the window that failed would otherwise come back as
    /// "not found", which is the same confidently-wrong error this change removes, and
    /// worse than what it replaced: the old code surfaced the transport failure.
    ///
    /// Reordering workspaces is exactly what closes windows, so this is ordinary, not
    /// exotic.
    @Test func partialWindowScanFallsBackToPassThrough() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--workspace", Self.staleRef, "--index", "0"],
            topology: .twoWindowsSecondFails
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        let reorder = try #require(requests.last { $0["method"] as? String == "workspace.reorder" })
        let params = try #require(reorder["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.staleRef)
        #expect(
            !result.stderr.contains("not found"),
            Comment(rawValue: "a hole in the scan must not be reported as absence: \(result.stderr)")
        )
    }

    /// A window whose `workspace.list` answers `ok` but carries no readable
    /// `workspaces` array was not actually read. Treating it as an empty window
    /// would complete the scan and report a ref that may live there as "not found".
    @Test func unreadableWindowPayloadFallsBackToPassThrough() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--workspace", Self.staleRef, "--index", "0"],
            topology: .twoWindowsSecondUnreadable
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        let reorder = try #require(requests.last { $0["method"] as? String == "workspace.reorder" })
        let params = try #require(reorder["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.staleRef)
        #expect(
            !result.stderr.contains("not found"),
            Comment(rawValue: "an unreadable window must not be reported as absence: \(result.stderr)")
        )
    }

    /// `window.list` succeeding with an empty list is not the same evidence as having
    /// read every window: no `workspace.list` ran, so nothing was observed. The CLI
    /// stays conservative and passes the ref through.
    @Test func emptyWindowListFallsBackToPassThrough() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--workspace", Self.staleRef, "--index", "0"],
            topology: .noWindows
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        let reorder = try #require(requests.last { $0["method"] as? String == "workspace.reorder" })
        let params = try #require(reorder["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.staleRef)
    }

    /// `reorder-workspace --index 0` must report the missing `--workspace` instead of
    /// reading the literal `--index` as the workspace selector.
    @Test func leadingFlagIsNotReadAsPositionalWorkspace() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--index", "0"],
            topology: .oneWindow
        )

        #expect(result.status != 0, Comment(rawValue: "expected nonzero exit, got \(result.status)"))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("workspace.reorder"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(
            result.stderr.contains("--workspace"),
            Comment(rawValue: "stderr should ask for --workspace, got: \(result.stderr)")
        )
        #expect(
            !result.stderr.contains("Invalid workspace handle"),
            Comment(rawValue: "--index must not be read as a workspace handle, got: \(result.stderr)")
        )
    }

    /// A positional workspace ref placed after a flag and its value must still be
    /// found, so `--index` no longer shadows it.
    @Test func positionalWorkspaceAfterFlagStillResolves() throws {
        let (requests, result) = try runReorderWorkspace(
            arguments: ["--index", "0", Self.liveRef],
            topology: .oneWindow
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        let reorder = try #require(requests.last { $0["method"] as? String == "workspace.reorder" })
        let params = try #require(reorder["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.liveWorkspaceId)
    }

    /// Drives `reorder-workspace` against a mock socket holding one window with one
    /// workspace, and returns the recorded JSON-RPC requests plus the process result.
    ///
    /// `topology: .windowListDenied` answers `window.list` with a relay-shaped denial so
    /// the caller can assert the pass-through carve-out.
    /// What the mock host's `window.list` / `workspace.list` pair reports, so a
    /// test can pick the shape of the scan the CLI has to survive.
    private enum Topology {
        /// One window holding ``liveRef``.
        case oneWindow
        /// `window.list` answers with a relay-shaped denial.
        case windowListDenied
        /// `window.list` succeeds and reports no windows at all.
        case noWindows
        /// Two windows; the second one's `workspace.list` fails, the way a window
        /// closing mid-scan or an admission backoff leaves a hole.
        case twoWindowsSecondFails
        /// Two windows; the second one's `workspace.list` succeeds but has no
        /// readable `workspaces` array.
        case twoWindowsSecondUnreadable
    }

    private func runReorderWorkspace(
        arguments: [String],
        topology: Topology
    ) throws -> ([[String: Any]], ProcessRunResult) {
        let socketPath = Self.makeSocketPath("ws-ref")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
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
            case "window.list":
                switch topology {
                case .windowListDenied:
                    return Self.v2Response(id: id, ok: false, error: [
                        "code": "forbidden",
                        "message": "method 'window.list' is not permitted through a remote relay",
                    ])
                case .noWindows:
                    return Self.v2Response(id: id, ok: true, result: ["windows": []])
                case .oneWindow:
                    return Self.v2Response(id: id, ok: true, result: [
                        "windows": [["id": Self.windowId, "ref": "window:1000000001", "index": 0]],
                    ])
                case .twoWindowsSecondFails, .twoWindowsSecondUnreadable:
                    return Self.v2Response(id: id, ok: true, result: [
                        "windows": [
                            ["id": Self.windowId, "ref": "window:1000000001", "index": 0],
                            ["id": Self.secondWindowId, "ref": "window:1000000002", "index": 1],
                        ],
                    ])
                }
            case "workspace.list":
                let requestedWindow = (payload["params"] as? [String: Any])?["window_id"] as? String
                // The window that went away answers the way the host does when the
                // id no longer routes. The CLI must treat that as a hole in the
                // scan, not as proof the ref is absent.
                if requestedWindow == Self.secondWindowId, topology == .twoWindowsSecondUnreadable {
                    return Self.v2Response(id: id, ok: true, result: ["workspaces": NSNull()])
                }
                if requestedWindow == Self.secondWindowId {
                    return Self.v2Response(id: id, ok: false, error: [
                        "code": "not_found", "message": "Window not found",
                    ])
                }
                if topology == .noWindows, requestedWindow == nil {
                    return Self.v2Response(id: id, ok: true, result: ["workspaces": []])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspaces": [[
                        "id": Self.liveWorkspaceId,
                        "ref": Self.liveRef,
                        "index": 0,
                    ]],
                ])
            case "workspace.reorder":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": Self.liveWorkspaceId,
                    "index": 0,
                ])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_WINDOW_ID")

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: ["reorder-workspace"] + arguments,
            environment: environment,
            timeout: 5
        )

        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))

        return (try state.requestObjects(), result)
    }

    // Post-#13633 ordinals start at 1_000_000_000, so these are realistic live refs.
    private static let liveRef = "workspace:1000000003"
    private static let staleRef = "workspace:1000000009"
    private static let liveWorkspaceId = "33333333-3333-3333-3333-333333333333"
    private static let windowId = "55555555-5555-5555-5555-555555555555"
    private static let secondWindowId = "66666666-6666-6666-6666-666666666666"

    private final class CLIWorkspaceRefResolutionBundleToken {}

    // Records socket callbacks from background threads; `lock` guards both arrays.
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
                try #require(CLIWorkspaceRefResolutionTests.jsonObject(line))
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
        try BundledCLITestSupport.bundledCLIPath(for: CLIWorkspaceRefResolutionBundleToken.self)
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
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer {
                    Darwin.close(clientFD)
                    handled.signal()
                }
                cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                    state.record(line)
                    return handler(line)
                }
            },
            onListenerClosed: {
                state.recordError("mock socket server failed to accept a client")
                handled.signal()
            }
        )
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

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
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
