import Darwin
import Foundation
import Testing

/// Regression coverage for workspace-scoped CLI commands defaulting to the *caller's*
/// workspace (the `CMUX_WORKSPACE_ID` the app injects into every terminal surface)
/// instead of silently falling back to the focused workspace.
///
/// The regression: `resolveWorkspaceId` treated a missing/blank `--workspace` as
/// "no handle" and fell through to `workspace.current`, i.e. whatever workspace is
/// selected in the foreground. The skill-recommended pattern
/// `--workspace "${CMUX_WORKSPACE_ID:-}"` expands to an empty value whenever a
/// background agent's environment is thin, so the command would act on the user's
/// visible workspace rather than the agent's own.
@Suite(.serialized)
struct CLICallerWorkspaceDefaultTests {
    /// Every noun-style workspace command that permits an omitted target must use
    /// the invoking terminal's workspace instead of global foreground selection.
    @Test func workspaceScopedNamespaceCommandsDefaultToCallerWorkspace() throws {
        let cases: [(arguments: [String], method: String)] = [
            (["workspace", "env"], "workspace.env"),
            (["workspace", "close"], "workspace.close"),
            (["workspace", "select"], "workspace.select"),
            (["workspace", "rename", "--title", "renamed"], "workspace.rename"),
            (["workspace", "reconnect"], "workspace.remote.reconnect"),
            (["workspace", "disconnect"], "workspace.remote.disconnect"),
            (["canvas", "info"], "canvas.info"),
        ]

        for testCase in cases {
            let (requests, result) = try runWorkspaceNamespaceCommand(
                arguments: testCase.arguments,
                expectedMethod: testCase.method,
                focusedWorkspaceId: Self.focusedWorkspaceId,
                callerWorkspaceId: Self.callerWorkspaceId
            )
            #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))

            let methods = requests.compactMap { $0["method"] as? String }
            #expect(methods == [testCase.method], Comment(rawValue: methods.joined(separator: ",")))
            #expect(!methods.contains("workspace.current"))

            let params = try #require(requests.first?["params"] as? [String: Any])
            #expect(params["workspace_id"] as? String == Self.callerWorkspaceId)
        }
    }

    /// An explicit window changes the defaulting scope: the caller workspace may
    /// belong to another window, so the target must be that window's selection.
    @Test func workspaceNamespaceExplicitWindowDefaultsWithinThatWindow() throws {
        let windowId = "77777777-7777-7777-7777-777777777777"
        let (requests, result) = try runWorkspaceNamespaceCommand(
            arguments: ["workspace", "rename", "--window", windowId, "--title", "renamed"],
            expectedMethod: "workspace.rename",
            focusedWorkspaceId: Self.focusedWorkspaceId,
            callerWorkspaceId: Self.callerWorkspaceId
        )
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))

        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods == ["workspace.current", "workspace.rename"])
        let currentParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(currentParams["window_id"] as? String == windowId)
        let renameParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(renameParams["window_id"] as? String == windowId)
        #expect(renameParams["workspace_id"] as? String == Self.focusedWorkspaceId)
    }

    /// A global window override must reach canvas commands just like a namespace-local
    /// `--window`, instead of being discarded and leaving canvas scoped to the caller.
    @Test func canvasGlobalWindowDefaultsWithinThatWindow() throws {
        let windowId = "77777777-7777-7777-7777-777777777777"
        let (requests, result) = try runWorkspaceNamespaceCommand(
            arguments: ["--window", windowId, "canvas", "info"],
            expectedMethod: "canvas.info",
            focusedWorkspaceId: Self.focusedWorkspaceId,
            callerWorkspaceId: Self.callerWorkspaceId
        )
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))

        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods == ["workspace.current", "canvas.info"])
        let currentParams = try #require(requests.first?["params"] as? [String: Any])
        #expect(currentParams["window_id"] as? String == windowId)
        let canvasParams = try #require(requests.last?["params"] as? [String: Any])
        #expect(canvasParams["workspace_id"] as? String == Self.focusedWorkspaceId)
    }

    /// A malformed injected caller ID must fail closed rather than being treated as
    /// absent and silently redirecting a mutating command to the focused workspace.
    @Test func malformedCallerWorkspaceFailsClosed() throws {
        let (requests, result) = try runWorkspaceNamespaceCommand(
            arguments: ["workspace", "rename", "--title", "renamed"],
            expectedMethod: "workspace.rename",
            focusedWorkspaceId: Self.focusedWorkspaceId,
            callerWorkspaceId: "malformed-caller-workspace"
        )

        #expect(result.status != 0, Comment(rawValue: "expected nonzero exit, got \(result.status)"))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("workspace.current"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(!methods.contains("workspace.rename"), Comment(rawValue: methods.joined(separator: ",")))
    }

    /// A blank `--workspace` from a caller pane must target the caller's workspace and
    /// must never consult `workspace.current` (the focused workspace).
    @Test func blankWorkspaceArgDefaultsToCallerWorkspace() throws {
        let (requests, result) = try runMarkNotificationRead(
            workspaceArgument: "   ",
            focusedWorkspaceId: Self.focusedWorkspaceId,
            callerWorkspaceId: Self.callerWorkspaceId
        )
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))

        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods == ["notification.mark_read"], Comment(rawValue: methods.joined(separator: ",")))
        #expect(!methods.contains("workspace.current"))

        let params = try #require(requests.first?["params"] as? [String: Any])
        #expect(params["tab_id"] as? String == Self.callerWorkspaceId)
    }

    /// A blank `--workspace` with no caller workspace in the environment must fail closed
    /// (nonzero exit) rather than silently retargeting the focused workspace. This is the
    /// dangerous case where `--workspace "${CMUX_WORKSPACE_ID:-}"` expands to an empty
    /// argument because the caller environment is thin.
    @Test func blankWorkspaceArgWithoutCallerFailsClosed() throws {
        let (requests, result) = try runMarkNotificationRead(
            workspaceArgument: "   ",
            focusedWorkspaceId: Self.focusedWorkspaceId,
            callerWorkspaceId: nil
        )

        #expect(result.status != 0, Comment(rawValue: "expected nonzero exit, got \(result.status)"))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("workspace.current"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(!methods.contains("notification.mark_read"), Comment(rawValue: methods.joined(separator: ",")))
    }

    /// An explicit but unrecognized `--workspace` (e.g. a typo) must fail closed even when
    /// a caller workspace is present, so a malformed name never silently resolves to — and
    /// mutates — the caller's workspace.
    @Test func invalidWorkspaceArgFailsClosedEvenWithCaller() throws {
        let (requests, result) = try runMarkNotificationRead(
            workspaceArgument: "not-a-real-workspace",
            focusedWorkspaceId: Self.focusedWorkspaceId,
            callerWorkspaceId: Self.callerWorkspaceId
        )

        #expect(result.status != 0, Comment(rawValue: "expected nonzero exit, got \(result.status)"))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("notification.mark_read"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(!methods.contains("workspace.current"), Comment(rawValue: methods.joined(separator: ",")))
    }

    /// An explicit `--workspace <uuid>` must still win over the caller's environment, so
    /// the caller default never hijacks a command that names another workspace.
    @Test func explicitWorkspaceArgStillWins() throws {
        let (requests, result) = try runMarkNotificationRead(
            workspaceArgument: Self.otherWorkspaceId,
            focusedWorkspaceId: Self.focusedWorkspaceId,
            callerWorkspaceId: Self.callerWorkspaceId
        )
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))

        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods == ["notification.mark_read"], Comment(rawValue: methods.joined(separator: ",")))
        #expect(!methods.contains("workspace.current"))

        let params = try #require(requests.first?["params"] as? [String: Any])
        #expect(params["tab_id"] as? String == Self.otherWorkspaceId)
    }

    /// Drives `mark-notification-read --workspace <argument>` against a mock socket and
    /// returns the recorded JSON-RPC requests plus the process result. The mock answers
    /// `workspace.current` with `focusedWorkspaceId` so that, pre-fix, the command would
    /// visibly retarget there. Pass `callerWorkspaceId: nil` to omit `CMUX_WORKSPACE_ID`.
    private func runMarkNotificationRead(
        workspaceArgument: String,
        focusedWorkspaceId: String,
        callerWorkspaceId: String?
    ) throws -> ([[String: Any]], ProcessRunResult) {
        let socketPath = Self.makeSocketPath("caller-ws")
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
            case "workspace.current":
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": focusedWorkspaceId])
            case "notification.mark_read":
                return Self.v2Response(id: id, ok: true, result: ["ok": true])
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
            arguments: ["mark-notification-read", "--workspace", workspaceArgument],
            environment: cliEnvironment(socketPath: socketPath, callerWorkspaceId: callerWorkspaceId),
            timeout: 5
        )

        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))

        return (try state.requestObjects(), result)
    }

    private func runWorkspaceNamespaceCommand(
        arguments: [String],
        expectedMethod: String,
        focusedWorkspaceId: String,
        callerWorkspaceId: String
    ) throws -> ([[String: Any]], ProcessRunResult) {
        let socketPath = Self.makeSocketPath("rename-ws")
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
            case "workspace.current":
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": focusedWorkspaceId])
            case expectedMethod:
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": callerWorkspaceId, "env": [String: String]()]
                )
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
            environment: cliEnvironment(socketPath: socketPath, callerWorkspaceId: callerWorkspaceId),
            timeout: 5
        )

        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))

        return (try state.requestObjects(), result)
    }

    private func cliEnvironment(socketPath: String, callerWorkspaceId: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        // Clear any ambient caller/window context inherited from the test host's own pane,
        // then set only what this scenario needs.
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment.removeValue(forKey: "CMUX_WINDOW_ID")
        if let callerWorkspaceId {
            environment["CMUX_WORKSPACE_ID"] = callerWorkspaceId
        } else {
            environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        }
        return environment
    }

    private static let callerWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let callerSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let focusedWorkspaceId = "99999999-9999-9999-9999-999999999999"
    private static let otherWorkspaceId = "44444444-4444-4444-4444-444444444444"

    final class CLICallerWorkspaceDefaultBundleToken {}

    // Records socket callbacks from a background queue; `lock` guards both arrays.
    final class ServerState: @unchecked Sendable {
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
                try #require(CLICallerWorkspaceDefaultTests.jsonObject(line))
            }
        }
    }

    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

}
