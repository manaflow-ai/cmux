import Darwin
import Foundation
import XCTest


// MARK: - Open command
extension CMUXOpenCommandTests {
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

}
