import Darwin
import XCTest

final class CMUXOpenCommandTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }
    }

    func testOpenCommandDefaultsFilePreviewsToNoFocus() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-nf")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "notes\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            guard method == "file.open",
                  params["paths"] as? [String] == [fileURL.path],
                  params["focus"] as? Bool == false else {
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unexpected-focus",
                    "message": "\(method) params=\(params)"
                ])
            }
            return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id"])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", fileURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["file.open"])
    }

    func testOpenCommandDefaultsURLsToNoFocus() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-url")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            guard method == "browser.open_split",
                  params["url"] as? String == "https://example.com",
                  params["focus"] as? Bool == false else {
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unexpected-focus",
                    "message": "\(method) params=\(params)"
                ])
            }
            return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id", "created_split": true])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", "https://example.com"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["browser.open_split"])
    }

    func testOpenCommandFocusTrueOptInIsPreserved() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-f")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("focused.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "focused\n".write(to: fileURL, atomically: true, encoding: .utf8)

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: MockSocketServerState()) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            guard method == "file.open",
                  params["paths"] as? [String] == [fileURL.path],
                  params["focus"] as? Bool == true else {
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unexpected-focus",
                    "message": "\(method) params=\(params)"
                ])
            }
            return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id"])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", fileURL.path, "--focus", "true"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testOpenCommandBareFocusOptInIsPreservedBeforeTarget() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-bare-f")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("focused.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "focused\n".write(to: fileURL, atomically: true, encoding: .utf8)

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: MockSocketServerState()) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            guard method == "file.open",
                  params["paths"] as? [String] == [fileURL.path],
                  params["focus"] as? Bool == true else {
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unexpected-focus",
                    "message": "\(method) params=\(params)"
                ])
            }
            return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id"])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", "--focus", fileURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testOpenCommandRejectsFocusAndNoFocusTogetherBeforeConnecting() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-focus-conflict")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("conflict.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "conflict\n".write(to: fileURL, atomically: true, encoding: .utf8)

        defer {
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", fileURL.path, "--focus", "--no-focus"]
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("--focus and --no-focus cannot be used together"), result.stderr)
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    func testPathShorthandFocusOptInIsPreserved() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("path-focus")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            guard method == "workspace.create",
                  params["cwd"] as? String == rootURL.path,
                  params["focus"] as? Bool == true,
                  params["window_id"] == nil else {
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unexpected-path-open",
                    "message": "\(method) params=\(params)"
                ])
            }
            return Self.v2Response(id: id, ok: true, result: ["workspace_ref": "workspace:focused"])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: [rootURL.path, "--focus"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["workspace.create"])
    }

    func testPathShorthandRejectsInvalidFocusValueBeforeConnecting() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("path-bad-focus")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        defer {
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: [rootURL.path, "--focus", "maybe"]
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("path open: --focus must be true or false"), result.stderr)
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    func testPathShorthandRejectsWhitespacePaddedFocusValueBeforeConnecting() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("path-space-focus")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        defer {
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: [rootURL.path, "--focus", " true"]
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("path open: --focus must be true or false"), result.stderr)
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    func testGlobalWindowOptionRoutesWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-nf")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            switch method {
            case "window.focus":
                return Self.v2Response(id: id, ok: true, result: [:])
            case "workspace.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "window_id": "window-uuid",
                    "workspaces": [
                        ["id": "workspace-uuid", "ref": "workspace:1", "title": "Window Scoped", "selected": false]
                    ]
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "list-workspaces"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let payloads = state.commands.compactMap { Self.v2Payload(from: $0) }
        XCTAssertEqual(payloads.compactMap { $0["method"] as? String }, ["workspace.list"])
        XCTAssertEqual((payloads.first?["params"] as? [String: Any])?["window_id"] as? String, "window:2")
    }

    func testGlobalWindowOptionRoutesSendWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-send")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            if method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }
            guard method == "surface.send_text" else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            guard params["window_id"] as? String == "window:2",
                  params["workspace_id"] == nil,
                  params["surface_id"] == nil,
                  params["text"] as? String == "echo hi" else {
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unexpected-routing",
                    "message": "\(params)"
                ])
            }
            return Self.v2Response(id: id, ok: true, result: [
                "window_id": "window-uuid",
                "workspace_id": "workspace-uuid",
                "surface_id": "surface-uuid"
            ])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "send", "echo hi"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let payloads = state.commands.compactMap { Self.v2Payload(from: $0) }
        XCTAssertEqual(payloads.compactMap { $0["method"] as? String }, ["surface.send_text"])
    }

    func testGlobalWindowOptionRoutesOpenCommandWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-open")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }
            guard method == "browser.open_split" else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            guard params["window_id"] as? String == "window:2",
                  params["url"] as? String == "https://example.com",
                  params["focus"] as? Bool == false else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-routing", "message": "\(params)"])
            }
            return Self.v2Response(id: id, ok: true, result: [
                "window_id": "window-uuid",
                "surface_id": "surface-id",
                "pane_id": "pane-id",
                "created_split": true,
            ])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "open", "https://example.com"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["browser.open_split"])
    }

    func testGlobalWindowOptionDoesNotOverrideExplicitOpenSurfaceTarget() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-open-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("targeted.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "targeted\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }
            guard method == "file.open" else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            guard params["paths"] as? [String] == [fileURL.path],
                  params["surface_id"] as? String == "surface:7",
                  params["window_id"] == nil,
                  params["focus"] as? Bool == false else {
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unexpected-routing",
                    "message": "\(params)"
                ])
            }
            return Self.v2Response(id: id, ok: true, result: [
                "surface_id": "surface-id",
                "pane_id": "pane-id",
            ])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "open", "--surface", "surface:7", fileURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["file.open"])
    }

    func testGlobalWindowOptionRoutesBrowserAndMarkdownWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("README.md")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "# Window scoped\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-br",
            arguments: ["--window", "window:2", "browser", "open", "https://example.com"],
            expectedMethod: "browser.open_split"
        ) { params in
            params["window_id"] as? String == "window:2"
                && params["url"] as? String == "https://example.com"
                && params["focus"] as? Bool == false
        }

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-md",
            arguments: ["--window", "window:2", "markdown", "open", fileURL.path],
            expectedMethod: "markdown.open"
        ) { params in
            params["window_id"] as? String == "window:2"
                && params["path"] as? String == fileURL.path
                && params["focus"] as? Bool == false
        }
    }

    func testGlobalWindowOptionScopesCurrentWorkspaceLookupWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-cur")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.current":
                guard params["window_id"] as? String == "window:2" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "missing-window", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": "workspace-uuid"])
            case "workspace.action":
                guard params["workspace_id"] as? String == "workspace-uuid",
                      params["action"] as? String == "rename",
                      params["title"] as? String == "Window Title" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-action", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-uuid",
                    "window_id": "window-uuid",
                    "action": "rename",
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "workspace-action", "rename", "Window Title"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["workspace.current", "workspace.action"]
        )
    }

    func testGlobalWindowOptionResolvesWorkspaceIndexesInsideTargetWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-ws-index")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.list":
                guard params["window_id"] as? String == "window:2" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "missing-window", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspaces": [
                        ["id": "workspace-uuid", "ref": "workspace:0", "index": 0]
                    ]
                ])
            case "surface.split":
                guard params["workspace_id"] as? String == "workspace:0",
                      params["window_id"] == nil,
                      params["direction"] as? String == "right",
                      params["focus"] as? Bool == false else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-split", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-uuid",
                    "surface_id": "surface-uuid",
                    "pane_id": "pane-uuid"
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "new-split", "--workspace", "0", "right"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["workspace.list", "surface.split"]
        )
    }

    func testGlobalWindowOptionRoutesSurfaceIndexCommandsWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()

        try assertGlobalWindowResolvesSurfaceIndex(
            cliPath: cliPath,
            name: "win-split",
            arguments: ["--window", "window:2", "split-off", "--surface", "0", "right"],
            expectedMethod: "surface.split_off"
        ) { params in
            params["surface_id"] as? String == "surface:0"
                && params["window_id"] == nil
                && params["direction"] as? String == "right"
                && params["focus"] as? Bool == false
        }

        try assertGlobalWindowResolvesSurfaceIndex(
            cliPath: cliPath,
            name: "win-reorder",
            arguments: ["--window", "window:2", "reorder-surface", "--surface", "0", "--index", "1"],
            expectedMethod: "surface.reorder"
        ) { params in
            params["surface_id"] as? String == "surface:0"
                && params["window_id"] == nil
                && params["index"] as? Int == 1
                && params["focus"] as? Bool == false
        }
    }

    func testGlobalWindowOptionRoutesTreeTopAndLegacyStatusWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-tree",
            arguments: ["--window", "window:2", "tree", "--json"],
            expectedMethod: "system.tree"
        ) { params in
            params["window_id"] as? String == "window:2"
                && params["all_windows"] as? Bool == false
                && params["caller"] == nil
        }

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-top",
            arguments: ["--window", "window:2", "top", "--json"],
            expectedMethod: "system.top"
        ) { params in
            params["window_id"] as? String == "window:2"
                && params["all_windows"] as? Bool == false
                && params["include_processes"] as? Bool == false
                && params["caller"] == nil
        }

        let socketPath = makeSocketPath("win-v1")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let payload = Self.v2Payload(from: line),
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                if method == "window.focus" {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
                }
                guard method == "workspace.current",
                      (payload["params"] as? [String: Any])?["window_id"] as? String == "window:2" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
                }
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": "workspace-uuid"])
            }
            guard line == "set_status build ok --tab=workspace-uuid" else {
                return "ERROR: unexpected \(line)"
            }
            return "OK"
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "set-status", "build", "ok"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertEqual(state.commands.count, 2)
        if state.commands.count == 2 {
            XCTAssertEqual(Self.v2Payload(from: state.commands[0])?["method"] as? String, "workspace.current")
            XCTAssertEqual(state.commands[1], "set_status build ok --tab=workspace-uuid")
        }
    }

    func testGlobalWindowOptionRoutesActiveContextCommandsWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-current",
            arguments: ["--window", "window:2", "current-window"],
            expectedMethod: "window.current"
        ) { params in
            params["window_id"] as? String == "window:2"
        }

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-jump",
            arguments: ["--window", "window:2", "jump-to-unread"],
            expectedMethod: "notification.jump_to_unread"
        ) { params in
            params["window_id"] as? String == "window:2"
        }

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-notify",
            arguments: ["--window", "window:2", "notify", "--title", "Window", "--body", "Scoped"],
            expectedMethod: "notification.create_for_caller"
        ) { params in
            params["window_id"] as? String == "window:2"
                && params["title"] as? String == "Window"
                && params["body"] as? String == "Scoped"
        }

        let socketPath = makeSocketPath("win-refresh")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let payload = Self.v2Payload(from: line),
               let id = payload["id"] as? String,
               payload["method"] as? String == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }
            guard line == "refresh_surfaces --window window:2" else {
                return "ERROR: unexpected \(line)"
            }
            return "OK Refreshed 1 surfaces"
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "refresh-surfaces"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK Refreshed 1 surfaces\n")
        XCTAssertEqual(state.commands, ["refresh_surfaces --window window:2"])
    }

    func testGlobalWindowOptionRoutesSSHWorkspaceCreateWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-ssh")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" || method == "workspace.select" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.create":
                guard params["window_id"] as? String == "window:2",
                      params["focus"] as? Bool == false,
                      (params["initial_command"] as? String)?.isEmpty == false else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-create", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "window_id": "window-uuid",
                ])
            case "workspace.remote.configure":
                guard params["workspace_id"] as? String == "workspace-ssh",
                      params["destination"] as? String == "example.com" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-configure", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "remote": ["state": "configured"],
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "ssh", "example.com"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["workspace.create", "workspace.remote.configure"]
        )
    }

    func testGlobalWindowOptionRoutesSSHFocusOptInToScopedSelect() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-sshf")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-window-focus"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.create":
                guard params["window_id"] as? String == "window:2",
                      params["focus"] as? Bool == false else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-create", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "window_id": "window-uuid",
                ])
            case "workspace.remote.configure":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "remote": ["state": "configured"],
                ])
            case "workspace.select":
                guard params["workspace_id"] as? String == "workspace-ssh",
                      params["window_id"] as? String == "window-uuid" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-select", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "window_id": "window-uuid",
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "ssh", "example.com", "--focus"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["workspace.create", "workspace.remote.configure", "workspace.select"]
        )
    }

    func testBareSSHFocusDoesNotConsumeJSONPresentationFlag() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-focus-json")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            switch method {
            case "workspace.create":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "window_id": "window-uuid",
                ])
            case "workspace.remote.configure":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "remote": ["state": "configured"],
                ])
            case "workspace.select":
                let params = payload["params"] as? [String: Any] ?? [:]
                guard params["workspace_id"] as? String == "workspace-ssh",
                      params["window_id"] as? String == "window-uuid" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-select", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "window_id": "window-uuid",
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["ssh", "--focus", "--json", "example.com"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertNotNil(Self.v2Payload(from: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["workspace.create", "workspace.remote.configure", "workspace.select"]
        )
    }

    func testSSHFocusFalseConsumesBooleanValue() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-focus-false")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "workspace.select" || method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.create":
                guard params["focus"] as? Bool == false else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-create", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "window_id": "window-uuid",
                ])
            case "workspace.remote.configure":
                guard params["destination"] as? String == "example.com" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-configure", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-ssh",
                    "workspace_ref": "workspace:4",
                    "remote": ["state": "configured"],
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["ssh", "--focus", "false", "example.com"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["workspace.create", "workspace.remote.configure"]
        )
    }

    func testGlobalWindowOptionRoutesVMSSHWorkspaceCreateWithoutFocusingWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("win-vm")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" || method == "workspace.select" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "vm.attach_info":
                guard params["id"] as? String == "vm-123",
                      params["require_daemon"] as? Bool == true else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-attach", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "transport": "ssh",
                    "host": "vm.example.com",
                    "port": 22,
                    "username": "cmux",
                    "credential": ["kind": "password", "value": "token"],
                ])
            case "workspace.create":
                guard params["window_id"] as? String == "window:2",
                      params["focus"] as? Bool == false else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-create", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-vm",
                    "workspace_ref": "workspace:5",
                    "window_id": "window-uuid",
                ])
            case "workspace.rename":
                guard params["workspace_id"] as? String == "workspace-vm",
                      params["title"] as? String == "vm:vm-123" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-rename", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-vm",
                    "workspace_ref": "workspace:5",
                    "title": "vm:vm-123",
                ])
            case "workspace.remote.configure":
                guard params["workspace_id"] as? String == "workspace-vm",
                      params["destination"] as? String == "cmux@vm.example.com" else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-configure", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": "workspace-vm",
                    "workspace_ref": "workspace:5",
                    "remote": ["state": "configured"],
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", "window:2", "vm", "ssh", "--focus", "false", "vm-123"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["vm.attach_info", "workspace.create", "workspace.rename", "workspace.remote.configure"]
        )
    }

    func testGlobalWindowOptionScopesTmuxWindowNavigation() throws {
        let cliPath = try bundledCLIPath()

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-last",
            arguments: ["--window", "window:2", "last-window"],
            expectedMethod: "workspace.last"
        ) { params in
            params["window_id"] as? String == "window:2"
        }

        try assertGlobalWindowRoutesSingleCommand(
            cliPath: cliPath,
            name: "win-next",
            arguments: ["--window", "window:2", "next-window"],
            expectedMethod: "workspace.next"
        ) { params in
            params["window_id"] as? String == "window:2"
        }
    }

    func testOpenCommandHonorsTerminatorForDashPrefixedPath() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-dash")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("-notes.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "dash file\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            if method == "file.open",
               let paths = params["paths"] as? [String],
               paths == [fileURL.path] {
                return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id"])
            }
            return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", "--", fileURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK files=1 surface=surface-id pane=pane-id\n")
    }

    func testOpenCommandProcessesMixedTargetsInInputOrder() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-order")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("notes.txt")
        let directoryURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "notes\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "file.open":
                guard let paths = params["paths"] as? [String], paths == [fileURL.path] else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-file-paths"])
                }
                return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id"])
            case "workspace.create":
                guard params["cwd"] as? String == directoryURL.path else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-cwd"])
                }
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": "workspace-id"])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", fileURL.path, directoryURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK files=1 surface=surface-id pane=pane-id workspaces=1\n")
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["file.open", "workspace.create"])
    }

    func testMarkdownOpenCommandUsesMarkdownOpenEndpoint() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("markdown-open")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("README.md")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "# Smoke\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            guard method == "markdown.open",
                  params["path"] as? String == fileURL.path else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "path": fileURL.path]
            )
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["markdown", "open", fileURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK surface=surface-id pane=pane-id path=\(fileURL.path)\n")
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["markdown.open"])
    }

    func testTopCommandSortsWorkspacesByCPUDescending() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-cpu")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:low", cpu: 1, rss: 1_000, processCount: 1),
                        topNode(ref: "workspace:high", cpu: 10, rss: 10_000, processCount: 3),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--sort", "cpu"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = outputLines(result.stdout)
        XCTAssertGreaterThanOrEqual(lines.count, 4, result.stdout)
        XCTAssertTrue(lines[2].contains("workspace workspace:high"), result.stdout)
        XCTAssertTrue(lines[3].contains("workspace workspace:low"), result.stdout)
    }

    func testTopCommandSortsMixedWorkspaceChildrenByMemoryAlias() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-mem")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                            "tags": [
                                topTag(key: "codex", cpu: 1, rss: 10_000, processCount: 1),
                            ],
                            "panes": [
                                topNode(ref: "pane:1", cpu: 2, rss: 50_000, processCount: 2),
                            ],
                        ]),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--sort", "mem"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = outputLines(result.stdout)
        XCTAssertGreaterThanOrEqual(lines.count, 5, result.stdout)
        XCTAssertTrue(lines[3].contains("pane pane:1"), result.stdout)
        XCTAssertTrue(lines[4].contains("tag codex"), result.stdout)
    }

    func testTopCommandSortsSurfaceWebviewsAndProcessesTogetherByMemory() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-surface-mixed")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                            "panes": [
                                topNode(ref: "pane:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                                    "surfaces": [
                                        topNode(ref: "surface:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                                            "webviews": [
                                                topNode(ref: "webview:1", cpu: 1, rss: 1_000, processCount: 1, extra: [
                                                    "pid": 8000,
                                                    "title": "lighter webview",
                                                ]),
                                            ],
                                            "processes": [
                                                [
                                                    "pid": 9000,
                                                    "name": "high-proc",
                                                    "resources": topResources(cpu: 3, rss: 10_000, processCount: 1),
                                                    "children": [],
                                                ] as [String: Any],
                                            ],
                                        ]),
                                    ],
                                ]),
                            ],
                        ]),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--processes", "--sort", "mem"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = outputLines(result.stdout)
        let processLine = try XCTUnwrap(lines.firstIndex { $0.contains("process 9000 high-proc") })
        let webviewLine = try XCTUnwrap(lines.firstIndex { $0.contains("webview pid=8000") })
        XCTAssertLessThan(processLine, webviewLine, result.stdout)
    }

    func testTopCommandOutputsFlatTSVForShellSorting() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-tsv")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "totals": topResources(cpu: 12, rss: 12_000, processCount: 4),
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:1", cpu: 10, rss: 10_000, processCount: 3, extra: [
                            "title": "High\tCPU\nWorkspace",
                        ]),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--flat", "--format", "tsv"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "12.0\t12000\t4\ttotal\ttotal\t\t",
            "2.0\t2000\t2\twindow\twindow:1\ttotal\t",
            "10.0\t10000\t3\tworkspace\tworkspace:1\twindow:1\tHigh CPU Workspace",
        ])
    }

    func testTopCommandFormatTSVImpliesFlatOutput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-fmt")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--format", "tsv"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "2.0\t2000\t2\twindow\twindow:1\ttotal\t",
        ])
    }

    func testTopCommandOutputsWindowLevelProcessRows() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-proc")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 1, extra: [
                    "processes": [
                        [
                            "pid": 4129,
                            "name": "cmux",
                            "resources": topResources(cpu: 2, rss: 2_000, processCount: 1),
                            "children": [],
                        ] as [String: Any],
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--processes", "--format", "tsv"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "2.0\t2000\t1\twindow\twindow:1\ttotal\t",
            "2.0\t2000\t1\tprocess\t4129\twindow:1\tcmux",
        ])
    }

    func testTopCommandSortsFlatTSVSiblingsByMemory() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-tsv-sort")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:low", cpu: 1, rss: 1_000, processCount: 1),
                        topNode(ref: "workspace:high", cpu: 3, rss: 10_000, processCount: 3),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--format", "tsv", "--sort", "rss"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "2.0\t2000\t2\twindow\twindow:1\ttotal\t",
            "3.0\t10000\t3\tworkspace\tworkspace:high\twindow:1\t",
            "1.0\t1000\t1\tworkspace\tworkspace:low\twindow:1\t",
        ])
    }

    func testTopCommandSortsFlatWindowProcessesAndWorkspacesTogetherByMemory() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-tsv-window-process-sort")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "processes": [
                        [
                            "pid": 4129,
                            "name": "cmux",
                            "resources": topResources(cpu: 4, rss: 10_000, processCount: 1),
                            "children": [],
                        ] as [String: Any],
                    ],
                    "workspaces": [
                        topNode(ref: "workspace:low", cpu: 1, rss: 1_000, processCount: 1),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--processes", "--format", "tsv", "--sort", "mem"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "2.0\t2000\t2\twindow\twindow:1\ttotal\t",
            "4.0\t10000\t1\tprocess\t4129\twindow:1\tcmux",
            "1.0\t1000\t1\tworkspace\tworkspace:low\twindow:1\t",
        ])
    }

    private func runCLI(cliPath: String, socketPath: String, arguments: [String]) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        return runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 5)
    }

    private func assertGlobalWindowRoutesSingleCommand(
        cliPath: String,
        name: String,
        arguments: [String],
        expectedMethod: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        paramsMatch: @escaping ([String: Any]) -> Bool
    ) throws {
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { requestLine in
            guard let payload = Self.v2Payload(from: requestLine),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }
            guard method == expectedMethod else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            guard paramsMatch(params) else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-routing", "message": "\(params)"])
            }
            return Self.v2Response(id: id, ok: true, result: [
                "window_id": "window-uuid",
                "workspace_id": "workspace-uuid",
                "surface_id": "surface-id",
                "pane_id": "pane-id",
                "path": params["path"] as? String ?? "",
                "created_split": true,
            ])
        }

        let result = runCLI(cliPath: cliPath, socketPath: socketPath, arguments: arguments)

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr, file: file, line: line)
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            [expectedMethod],
            file: file,
            line: line
        )
    }

    private func assertGlobalWindowResolvesSurfaceIndex(
        cliPath: String,
        name: String,
        arguments: [String],
        expectedMethod: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        paramsMatch: @escaping ([String: Any]) -> Bool
    ) throws {
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { requestLine in
            guard let payload = Self.v2Payload(from: requestLine),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-focus"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                guard params["window_id"] as? String == "window:2",
                      params["workspace_id"] == nil else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-list", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "surfaces": [
                        ["id": "surface-uuid", "ref": "surface:0", "index": 0]
                    ]
                ])
            case expectedMethod:
                guard paramsMatch(params) else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-routing", "message": "\(params)"])
                }
                return Self.v2Response(id: id, ok: true, result: [
                    "window_id": "window-uuid",
                    "workspace_id": "workspace-uuid",
                    "surface_id": "surface-uuid",
                    "pane_id": "pane-uuid",
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(cliPath: cliPath, socketPath: socketPath, arguments: arguments)

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr, file: file, line: line)
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["surface.list", expectedMethod],
            file: file,
            line: line
        )
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func runProcess(
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

        let outputGroup = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        outputGroup.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return ProcessRunResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }

        return fd
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli open mock socket handled")
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.fulfill()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.fulfill()
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
        return handled
    }

    private func startTopMockServer(listenerFD: Int32, payload: [String: Any]) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: MockSocketServerState()) { line in
            guard let request = Self.v2Payload(from: line),
                  let id = request["id"] as? String,
                  request["method"] as? String == "system.top" else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(id: id, ok: true, result: payload)
        }
    }

    private func topNode(
        ref: String,
        cpu: Double,
        rss: Int,
        processCount: Int,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var result = extra
        result["ref"] = ref
        result["resources"] = topResources(cpu: cpu, rss: rss, processCount: processCount)
        return result
    }

    private func topTag(
        key: String,
        cpu: Double,
        rss: Int,
        processCount: Int
    ) -> [String: Any] {
        [
            "key": key,
            "resources": topResources(cpu: cpu, rss: rss, processCount: processCount),
        ]
    }

    private func topResources(cpu: Double, rss: Int, processCount: Int) -> [String: Any] {
        [
            "cpu_percent": cpu,
            "resident_bytes": rss,
            "process_count": processCount,
        ]
    }

    private func outputLines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }

    private static func v2Payload(from line: String) -> [String: Any]? {
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
}
