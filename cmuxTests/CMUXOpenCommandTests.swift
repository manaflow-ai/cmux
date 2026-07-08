import Darwin
import Foundation
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

    private final class AsyncValueBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func set(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Value {
            lock.lock()
            let value = self.value
            lock.unlock()
            return value
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

    func testWorkspaceLoadingResolvesWorkspaceRefBeforeV1Command() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("loading-ref")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = UUID().uuidString
        let workspaceId = UUID().uuidString

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let payload = Self.v2Payload(from: line),
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                switch method {
                case "window.list":
                    return Self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "windows": [
                                ["id": windowId, "ref": "window:1"] as [String: Any],
                            ],
                        ]
                    )
                case "workspace.list":
                    let params = payload["params"] as? [String: Any] ?? [:]
                    XCTAssertEqual(params["window_id"] as? String, windowId)
                    return Self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "workspaces": [
                                [
                                    "id": workspaceId,
                                    "ref": "workspace:1",
                                    "index": 1,
                                ] as [String: Any],
                            ],
                        ]
                    )
                default:
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
                }
            }

            XCTAssertEqual(line, "workspace_loading manual on --tab=\(workspaceId)")
            return "before=OFF;after=ON"
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["workspace", "loading", "on", "--workspace", "workspace:1"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "before=OFF;after=ON\n")
        XCTAssertEqual(state.commands.last, "workspace_loading manual on --tab=\(workspaceId)")
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

    func testDiffCommandGeneratesCodeViewAndOpensBrowserSplit() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("diff-open")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let patchURL = rootURL.appendingPathComponent("changes.patch")
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let ghosttyConfigURL = homeURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        let cmuxConfigURL = homeURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        let cmuxAppSupportConfigURL = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
        let ghosttyResourcesURL = rootURL.appendingPathComponent("ghostty-resources", isDirectory: true)
        let ghosttyThemesURL = ghosttyResourcesURL.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ghosttyConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cmuxConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cmuxAppSupportConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ghosttyThemesURL, withIntermediateDirectories: true)
        try """
        palette = 0=#002b36
        palette = 1=#dc322f
        palette = 2=#859900
        palette = 3=#b58900
        palette = 4=#268bd2
        palette = 5=#d33682
        palette = 6=#2aa198
        palette = 7=#eee8d5
        palette = 8=#93a1a1
        palette = 9=#cb4b16
        palette = 10=#586e75
        palette = 11=#657b83
        palette = 12=#839496
        palette = 13=#6c71c4
        palette = 14=#93a1a1
        palette = 15=#fdf6e3
        background = #fdf6e3
        foreground = #073642
        selection-background = #eee8d5
        selection-foreground = #002b36
        """.write(to: ghosttyThemesURL.appendingPathComponent("Unit Light"), atomically: true, encoding: .utf8)
        try """
        palette = 0=#101820
        palette = 1=#ff6b6b
        palette = 2=#7bd88f
        palette = 3=#f7cf6d
        palette = 4=#82aaff
        palette = 5=#c792ea
        palette = 6=#89ddff
        palette = 7=#d6deeb
        palette = 8=#637777
        palette = 9=#ff8f8f
        palette = 10=#a5f3b9
        palette = 11=#ffe59d
        palette = 12=#b4ccff
        palette = 13=#ddb6f2
        palette = 14=#b8ecff
        palette = 15=#ffffff
        background = #101820
        foreground = #f8f8f2
        selection-background = #264f78
        selection-foreground = #ffffff
        """.write(to: ghosttyThemesURL.appendingPathComponent("Unit Dark"), atomically: true, encoding: .utf8)
        let ghosttyConfigContents = """
        font-family = Unit Mono
        font-size = 15
        background-opacity = 0.42
        theme = light:Unit Light,dark:Unit Dark
        """
        try ghosttyConfigContents.write(to: ghosttyConfigURL, atomically: true, encoding: .utf8)
        try ghosttyConfigContents.write(to: cmuxAppSupportConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "shortcuts": {
            "bindings": {
              "diffViewerScrollDown": "ctrl+j",
              "diffViewerScrollToTop": ["g", "g"],
              "diffViewerOpenFileSearch": null
            }
          }
        }
        """.write(to: cmuxConfigURL, atomically: true, encoding: .utf8)
        try """
        diff --git a/hello.txt b/hello.txt
        index 8ab686e..d95f3ad 100644
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1,3 +1,4 @@
         one
        -two
        +three
        +literal </script> marker
         four
        """.write(to: patchURL, atomically: true, encoding: .utf8)
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
            guard method == "browser.open_split",
                  params["focus"] as? Bool == true,
                  let rawURL = params["url"] as? String,
                  let viewerURL = URL(string: rawURL),
                  viewerURL.scheme == "http",
                  viewerURL.host == "127.0.0.1",
                  viewerURL.fragment == "cmux-diff-viewer" else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "url": rawURL]
            )
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: [
                "diff", patchURL.path,
                "--title", "Review diff",
                "--layout", "unified",
                "--font-size", "13",
                "--focus", "true"
            ],
            environmentOverrides: [
                "HOME": homeURL.path,
                "CFFIXED_USER_HOME": homeURL.path,
                "GHOSTTY_RESOURCES_DIR": ghosttyResourcesURL.path
            ]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("OK surface=surface-id pane=pane-id path="), result.stdout)
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["browser.open_split"])

        let commandPayload = try XCTUnwrap(Self.v2Payload(from: try XCTUnwrap(state.commands.first)))
        let params = try XCTUnwrap(commandPayload["params"] as? [String: Any])
        XCTAssertEqual(params["show_omnibar"] as? Bool, false)
        XCTAssertEqual(params["transparent_background"] as? Bool, true)
        XCTAssertEqual(params["bypass_remote_proxy"] as? Bool, true)
        let rawURL = try XCTUnwrap(params["url"] as? String)
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        XCTAssertEqual(viewerURL.scheme, "http")
        XCTAssertEqual(viewerURL.host, "127.0.0.1")
        XCTAssertEqual(viewerURL.fragment, "cmux-diff-viewer")
        XCTAssertNil(params["diff_viewer_token"])
        XCTAssertNil(params["diff_viewer_files"])
        let viewerFileURL = try diffViewerHTMLFileURL(from: params)
        defer { try? FileManager.default.removeItem(at: viewerFileURL) }
        let patchSidecarURL = viewerFileURL.deletingPathExtension().appendingPathExtension("patch")
        defer { try? FileManager.default.removeItem(at: patchSidecarURL) }

        let html = try String(contentsOf: viewerFileURL, encoding: .utf8)
        let patchText = try String(contentsOf: patchSidecarURL, encoding: .utf8)
        let viewerConfig = try diffViewerConfig(from: html)
        let viewerPayload = try diffViewerPayload(from: viewerConfig)
        let viewerAssets = try diffViewerAssets(from: viewerConfig)
        let shortcuts = try XCTUnwrap(viewerPayload["shortcuts"] as? [String: Any])
        let scrollDown = try XCTUnwrap(shortcuts["diffViewerScrollDown"] as? [String: Any])
        let scrollDownFirst = try XCTUnwrap(scrollDown["first"] as? [String: Any])
        XCTAssertEqual(scrollDownFirst["key"] as? String, "j")
        XCTAssertEqual(scrollDownFirst["control"] as? Bool, true)
        let scrollUp = try XCTUnwrap(shortcuts["diffViewerScrollUp"] as? [String: Any])
        let scrollUpFirst = try XCTUnwrap(scrollUp["first"] as? [String: Any])
        XCTAssertEqual(scrollUpFirst["key"] as? String, "k")
        XCTAssertEqual(scrollUpFirst["control"] as? Bool, false)
        let scrollTop = try XCTUnwrap(shortcuts["diffViewerScrollToTop"] as? [String: Any])
        XCTAssertEqual((try XCTUnwrap(scrollTop["first"] as? [String: Any]))["key"] as? String, "g")
        XCTAssertEqual((try XCTUnwrap(scrollTop["second"] as? [String: Any]))["key"] as? String, "g")
        let fileSearch = try XCTUnwrap(shortcuts["diffViewerOpenFileSearch"] as? [String: Any])
        XCTAssertEqual(fileSearch["unbound"] as? Bool, true)
        let files = try diffViewerAllowedFiles(for: rawURL, from: params)
        XCTAssertTrue(html.contains("Review diff"), html)
        XCTAssertTrue(html.contains("<script id=\"cmux-diff-viewer-config\" type=\"application/json\">") && html.contains("background: transparent;"), html)
        XCTAssertTrue(html.contains("<div id=\"root\"></div>"), html)
        XCTAssertTrue(html.contains("<script type=\"module\" src=\"./assets/cmux-diff-viewer-app/main.mjs\"></script>"), html)
        let assetDirectory = viewerFileURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("pierre-diffs-1.2.7-trees-1.0.0-beta.4", isDirectory: true)
        let appAssetDirectory = viewerFileURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-app", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetDirectory.appendingPathComponent("diffs.mjs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetDirectory.appendingPathComponent("trees.mjs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetDirectory.appendingPathComponent("worker-pool/worker-pool.mjs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetDirectory.appendingPathComponent("worker-pool/worker-portable.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appAssetDirectory.appendingPathComponent("main.mjs").path))
        XCTAssertEqual(viewerAssets["diffsModuleURL"], "./assets/pierre-diffs-1.2.7-trees-1.0.0-beta.4/diffs.mjs")
        XCTAssertEqual(viewerAssets["treesModuleURL"], "./assets/pierre-diffs-1.2.7-trees-1.0.0-beta.4/trees.mjs")
        XCTAssertEqual(viewerAssets["workerPoolModuleURL"], "./assets/pierre-diffs-1.2.7-trees-1.0.0-beta.4/worker-pool/worker-pool.mjs")
        XCTAssertEqual(viewerAssets["workerModuleURL"], "./assets/pierre-diffs-1.2.7-trees-1.0.0-beta.4/worker-pool/worker-portable.js")
        let appearance = try XCTUnwrap(viewerPayload["appearance"] as? [String: Any])
        XCTAssertEqual(appearance["backgroundOpacity"] as? Double, 0.42)
        XCTAssertTrue(html.contains("\"fontFamily\":\"Unit Mono\""), html)
        XCTAssertTrue(html.contains("\"fontSize\":13"), html)
        XCTAssertFalse(html.contains("\"fontSize\":15"), html)
        XCTAssertTrue(html.contains("\"dark\":\"cmux-ghostty-dark-"), html)
        XCTAssertTrue(html.contains("\"light\":\"cmux-ghostty-light-"), html)
        XCTAssertTrue(html.contains("Unit Light"), html)
        XCTAssertTrue(html.contains("Unit Dark"), html)
        XCTAssertTrue(html.contains("#101820") && !html.contains("background: rgba(16, 24, 32, 0.420);"), html)
        XCTAssertTrue(html.contains("#f8f8f2") && !html.contains("background: rgba(248, 248, 242, 0.420);"), html)
        XCTAssertEqual(viewerPayload["patchURL"] as? String, "./\(patchSidecarURL.lastPathComponent)")
        XCTAssertNil(viewerPayload["patch"])
        XCTAssertTrue(files.contains { file in
            file["request_path"] as? String == "/\(patchSidecarURL.lastPathComponent)" &&
                file["mime_type"] as? String == "text/x-diff"
        })
        XCTAssertTrue(files.contains { file in
            file["request_path"] as? String == "/assets/cmux-diff-viewer-app/main.mjs" &&
                file["mime_type"] as? String == "text/javascript"
        })
        XCTAssertTrue(files.contains { file in
            file["request_path"] as? String == "/assets/pierre-diffs-1.2.7-trees-1.0.0-beta.4/worker-pool/worker-portable.js" &&
                file["mime_type"] as? String == "text/javascript"
        })
        XCTAssertFalse(html.contains("hello.txt"), html)
        XCTAssertFalse(html.contains("<\\/script> marker"), html)
        XCTAssertTrue(patchText.contains("hello.txt"), patchText)
        XCTAssertTrue(patchText.contains("literal </script> marker"), patchText)
        XCTAssertTrue(html.contains("\"layout\":\"unified\""), html)
        XCTAssertFalse(html.contains("git apply <<'PATCH'"), html)

        let darkOnlyConfigContents = """
        font-family = Unit Mono
        font-size = 14
        theme = dark:Unit Dark
        """
        try darkOnlyConfigContents.write(to: ghosttyConfigURL, atomically: true, encoding: .utf8)
        try darkOnlyConfigContents.write(to: cmuxAppSupportConfigURL, atomically: true, encoding: .utf8)
        let darkOnlyTheme = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", patchURL.path, "--title", "Configured appearance"],
            environmentOverrides: [
                "HOME": homeURL.path,
                "CFFIXED_USER_HOME": homeURL.path,
                "GHOSTTY_RESOURCES_DIR": ghosttyResourcesURL.path
            ]
        )
        XCTAssertTrue(darkOnlyTheme.html.contains("\"fontSize\":14"), darkOnlyTheme.html)
        XCTAssertTrue(darkOnlyTheme.html.contains("\"ghosttyName\":\"Apple System Colors Light\""), darkOnlyTheme.html)
        XCTAssertTrue(darkOnlyTheme.html.contains("\"ghosttyName\":\"Unit Dark\""), darkOnlyTheme.html)
    }

    func testDiffCommandUsesTaggedSocketAppAssetsAndServer() throws {
        let cliPath = try bundledCLIPath()
        let tag = "asset\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased())"
        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-debug-\(tag).sock", isDirectory: false)
            .path
        unlink(socketPath)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let targetCLIURL = homeURL
            .appendingPathComponent("Library/Developer/Xcode/DerivedData/cmux-\(tag)", isDirectory: true)
            .appendingPathComponent("Build/Products/Debug/cmux DEV \(tag).app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
        let targetResourcesURL = targetCLIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let patchURL = rootURL.appendingPathComponent("change.patch", isDirectory: false)
        let state = MockSocketServerState()

        try FileManager.default.createDirectory(at: targetCLIURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: cliPath), to: targetCLIURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetCLIURL.path)
        try writeTestDiffViewerAssets(
            resourcesURL: targetResourcesURL,
            appMain: "export const cmuxTaggedSocketAssetMarker = 'target-\(tag)';\n"
        )
        try """
        diff --git a/file.txt b/file.txt
        index 1111111..2222222 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        +new
        """.write(to: patchURL, atomically: true, encoding: .utf8)

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "browser.open_split",
                  let params = payload["params"] as? [String: Any],
                  let rawURL = params["url"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "url": rawURL]
            )
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["diff", patchURL.path, "--title", "Tagged assets", "--focus", "false"],
            environmentOverrides: [
                "HOME": homeURL.path,
                "CFFIXED_USER_HOME": homeURL.path
            ]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let payload = try XCTUnwrap(Self.v2Payload(from: try XCTUnwrap(state.commands.first)))
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        let rawURL = try XCTUnwrap(params["url"] as? String)
        let files = try diffViewerAllowedFiles(for: rawURL, from: params)
        let appEntry = try XCTUnwrap(files.first { file in
            (file["request_path"] as? String)?.hasSuffix("/assets/cmux-diff-viewer-app/main.mjs") == true
        })
        let appFilePath = try XCTUnwrap(appEntry["file_path"] as? String)
        let appMain = try String(contentsOfFile: appFilePath, encoding: .utf8)
        XCTAssertTrue(appMain.contains("cmuxTaggedSocketAssetMarker = 'target-\(tag)'"), appMain)

        let stateURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(".server-state", isDirectory: false)
        let serverState = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        XCTAssertEqual(serverState?["executablePath"] as? String, targetCLIURL.path)
    }

    func testDiffCommandLinksOriginalDiffshubPRURL() throws {
        let cliPath = try bundledCLIPath()

        let originalURL = "https://diffshub.com/oven-sh/bun/pull/30412"
        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", originalURL, "--title", "Bun PR"],
            environmentOverrides: ["CMUX_DIFF_VIEWER_STREAM_REMOTE": "1"],
            readPatchSidecar: false
        )

        XCTAssertEqual(result.params["show_omnibar"] as? Bool, false)
        let payload = try diffViewerPayload(from: result.html)
        XCTAssertEqual(payload["externalURL"] as? String, originalURL)
        XCTAssertEqual(payload["sourceLabel"] as? String, originalURL)
        let rawURL = try XCTUnwrap(result.params["url"] as? String)
        let files = try diffViewerAllowedFiles(for: rawURL, from: result.params)
        let patchFile = try XCTUnwrap(files.first { file in
            file["mime_type"] as? String == "text/x-diff"
        })
        XCTAssertEqual(patchFile["file_path"] as? String, "")
        XCTAssertEqual(patchFile["remote_url"] as? String, "https://github.com/oven-sh/bun/pull/30412.diff")
        let viewerFileURL = try diffViewerHTMLFileURL(for: rawURL, from: result.params)
        let patchSidecarURL = viewerFileURL.deletingPathExtension().appendingPathExtension("patch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchSidecarURL.path))
    }

    func testDiffViewerServerBoundsDeferredWaitRequests() throws {
        let cliPath = try bundledCLIPath()
        let token = "test-\(UUID().uuidString.lowercased())"
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-viewer-wait-\(UUID().uuidString)", isDirectory: true)
        let pendingURL = rootURL.appendingPathComponent("pending.html", isDirectory: false)
        let manifestURL = rootURL.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        chmod(rootURL.path, 0o700)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try """
        <!doctype html>
        <html data-cmux-diff-pending="true">
        <body>Loading diff...</body>
        </html>
        """.write(to: pendingURL, atomically: true, encoding: .utf8)
        let manifest: [String: Any] = [
            "token": token,
            "files": [
                [
                    "request_path": "/pending.html",
                    "file_path": pendingURL.path,
                    "mime_type": "text/html",
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        let process = Process()
        let stdoutPipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_DIFF_VIEWER_WAIT_TIMEOUT_SECONDS"] = "0.05"
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["diff-viewer-server", "--root", rootURL.path]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer { terminateProcess(process) }

        let portLine = try readLine(from: stdoutPipe.fileHandleForReading, timeout: 3)
        let port = try XCTUnwrap(Int(portLine), "invalid diff viewer server port: \(portLine)")
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/__cmux_diff_viewer_wait/\(token)/pending.html"))
        // The bounded deferred wait is the unit under test. With
        // CMUX_DIFF_VIEWER_WAIT_TIMEOUT_SECONDS=0.05 the server must give up on the
        // still-pending diff and answer the request instead of hanging. The deadline-
        // bounded fetch below (timeout: 3) is itself the "did not hang" guard: a server
        // that ignored the wait timeout would never respond and `fetchData` would throw.
        // We assert on the logical outcome of the bound rather than a wall-clock latency:
        // a 504 whose body has the pending marker stripped and the render-failed copy.
        let response = try fetchData(from: url, timeout: 3)

        XCTAssertEqual(response.statusCode, 504)
        let body = String(data: response.data, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("data-cmux-diff-pending=\"true\""), body)
        XCTAssertTrue(body.contains("Could not render this diff"), body)
    }

    func testDiffCommandTakesPrecedenceOverLocalPathNamedDiff() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shadowCommandURL = rootURL.appendingPathComponent("diff", isDirectory: false)
        let patchURL = rootURL.appendingPathComponent("changes.patch", isDirectory: false)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try "not a command\n".write(to: shadowCommandURL, atomically: true, encoding: .utf8)
        try """
        diff --git a/hello.txt b/hello.txt
        index 8ab686e..d95f3ad 100644
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1 +1 @@
        -old
        +new
        """.write(to: patchURL, atomically: true, encoding: .utf8)

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", patchURL.path, "--no-focus"],
            currentDirectoryURL: rootURL
        )

        XCTAssertTrue(result.patch.contains("hello.txt"), result.patch)
        XCTAssertEqual(result.params["show_omnibar"] as? Bool, false)
    }

    func testDiffCommandUsesBundledAppLocalizationsForViewerLabels() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let patchURL = rootURL.appendingPathComponent("localized.patch")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try """
        diff --git a/localized.txt b/localized.txt
        index 1111111..2222222 100644
        --- a/localized.txt
        +++ b/localized.txt
        @@ -1,2 +1,2 @@
         one
        -two
        +three
        """.write(to: patchURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", patchURL.path],
            environmentOverrides: [
                "AppleLanguages": "(ja)",
                "LANG": "ja_JP.UTF-8"
            ]
        )

        XCTAssertTrue(result.html.contains("インジケータースタイル"), result.html)
        XCTAssertTrue(result.html.contains("git apply コマンドをコピー"), result.html)
        XCTAssertFalse(result.html.contains("Indicator style"), result.html)
    }

    func testDiffCommandUsageDocumentsFocusTitleAndNoFocus() throws {
        let cliPath = try bundledCLIPath()
        let result = runCLI(
            cliPath: cliPath,
            socketPath: makeSocketPath("diff-help"),
            arguments: ["help"]
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("diff [patch-file|-]"), result.stdout)
        XCTAssertTrue(result.stdout.contains("[--focus <true|false>] [--no-focus] [--title <text>]"), result.stdout)
        XCTAssertTrue(result.stdout.contains("[--cwd <path>] [--base <ref>]"), result.stdout)
        XCTAssertTrue(result.stdout.contains("--base <ref>"), result.stdout)
    }

    func testDiffCommandFallsBackToNonEmptyGitSourceForSelector() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)

        let plainSiblingURL = rootURL.appendingPathComponent("plain-sibling", isDirectory: true)
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let gitWrapperURL = binURL.appendingPathComponent("git", isDirectory: false)
        let gitLogURL = rootURL.appendingPathComponent("git-log.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: plainSiblingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(gitLogURL.path)"
        case "$*" in
          *"\(plainSiblingURL.path)"*) echo "unexpected plain sibling probe" >&2; exit 99 ;;
        esac
        exec /usr/bin/git "$@"
        """.write(to: gitWrapperURL, atomically: true, encoding: .utf8)
        chmod(gitWrapperURL.path, 0o755)

        let stagedFallback = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            environmentOverrides: [
                "PATH": "\(binURL.path):/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            currentDirectoryURL: repoURL
        )

        XCTAssertTrue(stagedFallback.html.contains("Staged changes"), stagedFallback.html)
        XCTAssertTrue(stagedFallback.html.contains("\"sourceLabel\":\"git staged\""), stagedFallback.html)
        XCTAssertTrue(stagedFallback.patch.contains("+two"), stagedFallback.patch)
        let payload = try diffViewerPayload(from: stagedFallback.html)
        let sourceOptions = try XCTUnwrap(payload["sourceOptions"] as? [[String: Any]])
        let stagedOption = try XCTUnwrap(sourceOptions.first { $0["value"] as? String == "staged" })
        let unstagedOption = try XCTUnwrap(sourceOptions.first { $0["value"] as? String == "unstaged" })
        XCTAssertEqual(stagedOption["selected"] as? Bool, true)
        XCTAssertEqual(unstagedOption["selected"] as? Bool, false)
        let unstagedURLString = try diffViewerOptionURL(value: "unstaged", in: sourceOptions)
        let unstagedFileURL = try diffViewerHTMLFileURL(for: unstagedURLString, from: stagedFallback.params)
        let unstagedHTML = try String(contentsOf: unstagedFileURL, encoding: .utf8)
        XCTAssertTrue(unstagedHTML.contains("No unstaged changes to diff."), unstagedHTML)
        XCTAssertFalse(unstagedHTML.contains("+two"), unstagedHTML)
        let gitLog = try String(contentsOf: gitLogURL, encoding: .utf8)
        XCTAssertFalse(gitLog.contains(plainSiblingURL.path), gitLog)
    }

    func testDiffCommandShowsFriendlyEmptyStateWhenEveryGitSourceIsEmpty() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)

        let socketPath = makeSocketPath("diff-empty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "browser.open_split",
                  let params = payload["params"] as? [String: Any],
                  let rawURL = params["url"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "url": rawURL]
            )
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        // Empty diffs are a friendly state, not an error: the CLI exits 0 (so the
        // launcher never emits the "unable to click" beep) and prints nothing to
        // stderr. (issue #5246)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stderr.contains("No unstaged changes to diff."), result.stderr)
        XCTAssertFalse(result.stderr.contains("EmptyDiffSourceError"), result.stderr)

        let commandPayload = try XCTUnwrap(
            state.commands.compactMap { Self.v2Payload(from: $0) }.first { payload in
                payload["method"] as? String == "browser.open_split"
            }
        )
        let params = try XCTUnwrap(commandPayload["params"] as? [String: Any])
        let rawURL = try XCTUnwrap(params["url"] as? String)
        let openedFileURL = try diffViewerHTMLFileURL(for: rawURL, from: params)
        let viewerFileURL = try resolvedDiffViewerHTMLFileURL(openedFileURL, from: params)
        let html = try String(contentsOf: viewerFileURL, encoding: .utf8)
        XCTAssertTrue(html.contains("No unstaged changes to diff."), html)
        XCTAssertFalse(html.contains("No last-turn diff baseline recorded"), html)
        let payload = try diffViewerPayload(from: html)
        XCTAssertEqual(payload["statusIsError"] as? Bool, false, html)
    }

    func testDiffCommandShowsFriendlyEmptyStateForLastTurnWithoutBaseline() throws {
        // Regression: a last-turn diff with no recorded baseline must render the
        // friendly empty diff state (with the source switcher) and exit 0, not
        // surface the raw "No last-turn diff baseline recorded" CLI error. The
        // non-zero exit is what triggered the launcher's "unable to click" beep,
        // so a clean exit fixes both the bad copy and the beep (issue #5246).
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        // Staged changes exist on another source; last turn must NOT silently fall
        // back to them — it stays on its own empty state.
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": rootURL.appendingPathComponent("hook-state", isDirectory: true).path,
                "CMUX_WORKSPACE_ID": UUID().uuidString.lowercased(),
                "CMUX_SURFACE_ID": UUID().uuidString.lowercased()
            ],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )

        try assertFriendlyLastTurnEmptyState(html: result.html)
        // No silent fallback to the staged "+two" change.
        XCTAssertFalse(result.html.contains("+two"), result.html)
    }

    func testDiffCommandShowsFriendlyEmptyStateForEmptyLastTurnDiff() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("hook-state", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try runGit(["remote", "add", "origin", rootURL.appendingPathComponent("origin.git").path], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        let initialCommit = try runGitStdout(["rev-parse", "HEAD"], in: repoURL)
        try runGit(["update-ref", "refs/remotes/origin/main", initialCommit], in: repoURL)
        try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repoURL)
        try runGit(["checkout", "-b", "feature/diff-source"], in: repoURL)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "feature change"], in: repoURL)
        let featureCommit = try runGitStdout(["rev-parse", "HEAD"], in: repoURL)
        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        try writeDiffBaselineStore(
            stateDirectoryURL: stateURL,
            repoURL: repoURL,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            baseCommit: featureCommit
        )

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )

        try assertFriendlyLastTurnEmptyState(html: result.html)
    }

    func testDiffCommandSupportsGitSourcesAndSurfaceScopedLastTurn() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("hook-state", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        func assertNoANSIEscape(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(html.contains("\u{1B}"), html, file: file, line: line)
            XCTAssertFalse(html.contains("\\u001B"), html, file: file, line: line)
            XCTAssertFalse(html.contains("\\u001b"), html, file: file, line: line)
        }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try runGit(["config", "color.ui", "always"], in: repoURL)
        try runGit(["config", "color.diff", "always"], in: repoURL)
        try runGit(["remote", "add", "origin", rootURL.appendingPathComponent("origin.git").path], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        let initialCommit = try runGitStdout(["rev-parse", "HEAD"], in: repoURL)
        try runGit(["update-ref", "refs/remotes/origin/main", initialCommit], in: repoURL)
        try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repoURL)

        let siblingRepoURL = rootURL.appendingPathComponent("other-repo", isDirectory: true)
        let siblingFileURL = siblingRepoURL.appendingPathComponent("other.txt")
        try FileManager.default.createDirectory(at: siblingRepoURL, withIntermediateDirectories: true)
        try runGit(["init"], in: siblingRepoURL)
        try runGit(["checkout", "-b", "main"], in: siblingRepoURL)
        try runGit(["config", "user.name", "cmux tests"], in: siblingRepoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: siblingRepoURL)
        try "base\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "other.txt"], in: siblingRepoURL)
        try runGit(["commit", "-m", "initial"], in: siblingRepoURL)
        let siblingInitialCommit = try runGitStdout(["rev-parse", "HEAD"], in: siblingRepoURL)
        try runGit(["update-ref", "refs/remotes/origin/main", siblingInitialCommit], in: siblingRepoURL)
        try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: siblingRepoURL)
        try runGit(["checkout", "-b", "feature/other"], in: siblingRepoURL)
        try "base\nchanged\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)

        try runGit(["checkout", "-b", "feature/diff-source"], in: repoURL)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "add two"], in: repoURL)
        let featureCommit = try runGitStdout(["rev-parse", "HEAD"], in: repoURL)
        try runGit(["update-ref", "refs/remotes/origin/feature/diff-source", featureCommit], in: repoURL)
        try runGit(["branch", "--set-upstream-to=origin/feature/diff-source"], in: repoURL)
        try "one\ntwo\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let branch = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--branch", "--title", "Branch source"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(branch.html.contains("Branch source"), branch.html)
        XCTAssertTrue(branch.patch.contains("+two"), branch.patch)
        XCTAssertTrue(branch.patch.contains("+three"), branch.patch)
        XCTAssertTrue(branch.html.contains("\"sourceLabel\":\"git branch origin/main\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"sourceOptions\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"repoOptions\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"baseOptions\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"repoRoot\":\"\(repoURL.path)\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"branchBaseRef\":\"origin/main\""), branch.html)
        XCTAssertTrue(branch.html.contains("other-repo"), branch.html)
        XCTAssertTrue(branch.html.contains("\"label\":\"Unstaged\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"label\":\"Staged\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"label\":\"Branch\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"label\":\"Last turn\""), branch.html)
        assertNoANSIEscape(branch.html)

        let branchPayload = try diffViewerPayload(from: branch.html)
        let branchSourceOptions = try XCTUnwrap(branchPayload["sourceOptions"] as? [[String: Any]])
        let selectedRepoUnstagedURLString = try diffViewerOptionURL(value: "unstaged", in: branchSourceOptions)
        let selectedRepoUnstagedFileURL = try diffViewerHTMLFileURL(
            for: selectedRepoUnstagedURLString,
            from: branch.params
        )
        let selectedRepoUnstagedHTML = try String(contentsOf: selectedRepoUnstagedFileURL, encoding: .utf8)
        let selectedRepoUnstagedPayload = try diffViewerPayload(from: selectedRepoUnstagedHTML)
        let unstagedRepoOptions = try XCTUnwrap(selectedRepoUnstagedPayload["repoOptions"] as? [[String: Any]])
        let siblingRepoUnstagedURLString = try diffViewerOptionURL(value: siblingRepoURL.path, in: unstagedRepoOptions)
        XCTAssertTrue(siblingRepoUnstagedURLString.contains("-unstaged.html"), siblingRepoUnstagedURLString)
        let siblingRepoUnstagedFileURL = try diffViewerHTMLFileURL(
            for: siblingRepoUnstagedURLString,
            from: branch.params
        )
        let siblingRepoUnstagedHTML = try String(contentsOf: siblingRepoUnstagedFileURL, encoding: .utf8)
        let siblingRepoUnstagedPatch = try String(
            contentsOf: siblingRepoUnstagedFileURL.deletingPathExtension().appendingPathExtension("patch"),
            encoding: .utf8
        )
        XCTAssertTrue(siblingRepoUnstagedHTML.contains("\"sourceLabel\":\"git unstaged\""), siblingRepoUnstagedHTML)
        XCTAssertTrue(siblingRepoUnstagedHTML.contains("\"repoRoot\":\"\(siblingRepoURL.path)\""), siblingRepoUnstagedHTML)
        XCTAssertTrue(siblingRepoUnstagedPatch.contains("+changed"), siblingRepoUnstagedPatch)
        XCTAssertFalse(siblingRepoUnstagedHTML.contains("\"sourceLabel\":\"git branch"), siblingRepoUnstagedHTML)

        let branchWithBase = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--branch", "--base", "main"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(branchWithBase.html.contains("\"sourceLabel\":\"git branch main\""), branchWithBase.html)
        XCTAssertTrue(branchWithBase.html.contains("\"branchBaseRef\":\"main\""), branchWithBase.html)
        XCTAssertTrue(branchWithBase.patch.contains("+two"), branchWithBase.patch)
        let branchWithBasePayload = try diffViewerPayload(from: branchWithBase.html)
        let branchWithBaseRepoOptions = try XCTUnwrap(branchWithBasePayload["repoOptions"] as? [[String: Any]])
        let siblingRepoBranchURLString = try diffViewerOptionURL(value: siblingRepoURL.path, in: branchWithBaseRepoOptions)
        let siblingRepoBranchFileURL = try diffViewerHTMLFileURL(
            for: siblingRepoBranchURLString,
            from: branchWithBase.params
        )
        let siblingRepoBranchHTML = try String(contentsOf: siblingRepoBranchFileURL, encoding: .utf8)
        let siblingRepoBranchPatch = try String(
            contentsOf: siblingRepoBranchFileURL.deletingPathExtension().appendingPathExtension("patch"),
            encoding: .utf8
        )
        XCTAssertTrue(siblingRepoBranchHTML.contains("\"sourceLabel\":\"git branch main\""), siblingRepoBranchHTML)
        XCTAssertTrue(siblingRepoBranchHTML.contains("\"branchBaseRef\":\"main\""), siblingRepoBranchHTML)
        XCTAssertTrue(siblingRepoBranchHTML.contains("\"repoRoot\":\"\(siblingRepoURL.path)\""), siblingRepoBranchHTML)
        XCTAssertTrue(siblingRepoBranchPatch.contains("+changed"), siblingRepoBranchPatch)

        let repoOverride = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged", "--repo", repoURL.path],
            currentDirectoryURL: rootURL
        )
        XCTAssertTrue(repoOverride.html.contains("\"sourceLabel\":\"git unstaged\""), repoOverride.html)
        XCTAssertTrue(repoOverride.html.contains("\"repoRoot\":\"\(repoURL.path)\""), repoOverride.html)
        XCTAssertTrue(repoOverride.patch.contains("+three"), repoOverride.patch)

        let unstaged = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(unstaged.html.contains("Unstaged changes"), unstaged.html)
        XCTAssertTrue(unstaged.patch.contains("+three"), unstaged.patch)
        XCTAssertTrue(unstaged.html.contains("\"sourceLabel\":\"git unstaged\""), unstaged.html)
        assertNoANSIEscape(unstaged.patch)

        try runGit(["add", "story.txt"], in: repoURL)
        let staged = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--source", "staged"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(staged.html.contains("Staged changes"), staged.html)
        XCTAssertTrue(staged.patch.contains("+three"), staged.patch)
        XCTAssertTrue(staged.html.contains("\"sourceLabel\":\"git staged\""), staged.html)
        assertNoANSIEscape(staged.patch)

        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        try "before\n".write(to: repoURL.appendingPathComponent("preexisting.txt"), atomically: true, encoding: .utf8)
        try "same\n".write(to: repoURL.appendingPathComponent("unchanged-untracked.txt"), atomically: true, encoding: .utf8)
        try "remove me\n".write(to: repoURL.appendingPathComponent("deleted-untracked.txt"), atomically: true, encoding: .utf8)
        let quotedUntrackedPath = "quoted\tuntracked.txt"
        try "quoted before\n".write(to: repoURL.appendingPathComponent(quotedUntrackedPath), atomically: true, encoding: .utf8)
        try "tracked later\n".write(to: repoURL.appendingPathComponent("tracked-later.txt"), atomically: true, encoding: .utf8)
        try Data([0xff, 0x00, 0x6f, 0x6c, 0x64])
            .write(to: repoURL.appendingPathComponent("binary.dat"), options: .atomic)
        try writeDiffBaselineStore(
            stateDirectoryURL: stateURL,
            repoURL: repoURL,
            workspaceId: workspaceId.uppercased(),
            surfaceId: surfaceId.uppercased(),
            baseCommit: initialCommit,
            untrackedPaths: [
                "preexisting.txt",
                "unchanged-untracked.txt",
                "deleted-untracked.txt",
                quotedUntrackedPath,
                "tracked-later.txt",
                "binary.dat"
            ]
        )
        try "after\n".write(to: repoURL.appendingPathComponent("preexisting.txt"), atomically: true, encoding: .utf8)
        try "quoted after\n".write(to: repoURL.appendingPathComponent(quotedUntrackedPath), atomically: true, encoding: .utf8)
        try Data([0xff, 0x00, 0x6e, 0x65, 0x77])
            .write(to: repoURL.appendingPathComponent("binary.dat"), options: .atomic)
        try runGit(["add", "tracked-later.txt"], in: repoURL)
        try "created\n".write(to: repoURL.appendingPathComponent("new-turn-file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repoURL.appendingPathComponent("deleted-untracked.txt"))
        let lastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL
        )
        XCTAssertEqual(lastTurn.params["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(lastTurn.params["surface_id"] as? String, surfaceId)
        XCTAssertEqual(lastTurn.params["show_omnibar"] as? Bool, false)
        XCTAssertTrue(lastTurn.html.contains("Last turn diff"), lastTurn.html)
        XCTAssertTrue(lastTurn.patch.contains("+two"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+three"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("new-turn-file.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+created"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("preexisting.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("-before"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+after"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("\"a/quoted\\tuntracked.txt\""), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("\"b/quoted\\tuntracked.txt\""), lastTurn.patch)
        XCTAssertFalse(lastTurn.patch.contains("baseline/quoted"), lastTurn.patch)
        XCTAssertFalse(lastTurn.patch.contains("current/quoted"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("-quoted before"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+quoted after"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("binary.dat"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("GIT binary patch"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("tracked-later.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+tracked later"), lastTurn.patch)
        XCTAssertFalse(lastTurn.patch.contains("-tracked later"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("deleted-untracked.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("-remove me"), lastTurn.patch)
        XCTAssertFalse(lastTurn.patch.contains("unchanged-untracked.txt"), lastTurn.patch)
        assertNoANSIEscape(lastTurn.patch)

        let refLastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn", "--workspace", "workspace:1", "--surface", "surface:1"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path
            ],
            currentDirectoryURL: repoURL
        ) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return nil
            }
            switch method {
            case "workspace.list":
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": workspaceId,
                                "ref": "workspace:1",
                                "index": 1
                            ] as [String: Any]
                        ]
                    ]
                )
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true
                            ] as [String: Any]
                        ]
                    ]
                )
            default:
                return nil
            }
        }
        XCTAssertEqual(refLastTurn.params["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(refLastTurn.params["surface_id"] as? String, surfaceId)
        XCTAssertTrue(refLastTurn.html.contains("Last turn diff"), refLastTurn.html)

        let homeURL = rootURL.appendingPathComponent("custom-home", isDirectory: true)
        let homeStateURL = homeURL.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: homeStateURL, withIntermediateDirectories: true)
        try writeDiffBaselineStore(
            stateDirectoryURL: homeStateURL,
            repoURL: repoURL,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            baseCommit: initialCommit,
            untrackedPaths: ["preexisting.txt"]
        )
        let homeLastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "HOME": homeURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(homeLastTurn.html.contains("Last turn diff"), homeLastTurn.html)
        XCTAssertTrue(homeLastTurn.patch.contains("new-turn-file.txt"), homeLastTurn.patch)

        let wrongSurfaceResult = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": UUID().uuidString.lowercased()
            ],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )
        try assertFriendlyLastTurnEmptyState(html: wrongSurfaceResult.html)
    }

    /// Asserts the diff viewer HTML renders the friendly, non-error last-turn empty
    /// state: plain-language copy (never the raw baseline CLI error), `statusIsError`
    /// false, and the source switcher still present with last turn selected.
    private func assertFriendlyLastTurnEmptyState(html: String) throws {
        XCTAssertFalse(html.contains("No last-turn diff baseline recorded"), html)
        let payload = try diffViewerPayload(from: html)
        XCTAssertEqual(payload["statusMessage"] as? String, "No last-turn changes to diff.", html)
        XCTAssertEqual(payload["statusIsError"] as? Bool, false, html)
        let sourceOptions = try XCTUnwrap(payload["sourceOptions"] as? [[String: Any]], html)
        let lastTurnOption = try XCTUnwrap(
            sourceOptions.first { $0["value"] as? String == "last-turn" },
            html
        )
        XCTAssertEqual(lastTurnOption["selected"] as? Bool, true, html)
    }

    func testAgentTurnDiffBaselineStoresUntrackedSnapshotsOutsideGit() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "tracked\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        let secretURL = repoURL.appendingPathComponent("secret.txt")
        try "before\n".write(to: secretURL, atomically: true, encoding: .utf8)
        chmod(secretURL.path, 0o644)

        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        let socketPath = makeSocketPath("hook-diff")
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
            if method == "surface.list" {
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true
                            ] as [String: Any]
                        ]
                    ]
                )
            }
            return Self.v2Response(id: id, ok: true, result: [:])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["hooks", "codex", "prompt-submit", "--workspace", workspaceId, "--surface", surfaceId],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "PWD": repoURL.path
            ],
            currentDirectoryURL: repoURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let untrackedRefs = try runGitStdout(
            ["for-each-ref", "--format=%(refname)", "refs/cmux/last-turn/untracked"],
            in: repoURL
        )
        XCTAssertEqual(untrackedRefs.trimmingCharacters(in: .whitespacesAndNewlines), "")

        let storeURL = stateURL.appendingPathComponent("agent-turn-diff-baselines.json")
        let lockURL = stateURL.appendingPathComponent("agent-turn-diff-baselines.json.lock")
        let storeData = try Data(contentsOf: storeURL)
        let store = try JSONSerialization.jsonObject(with: storeData, options: []) as? [String: Any]
        let records = try XCTUnwrap(store?["records"] as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        let snapshotId = try XCTUnwrap(record["untrackedSnapshotId"] as? String)
        let hashes = try XCTUnwrap(record["untrackedPathHashes"] as? [String: String])
        XCTAssertNotNil(hashes["secret.txt"])
        let snapshotRoot = stateURL
            .appendingPathComponent("agent-turn-diff-baseline-snapshots", isDirectory: true)
        let snapshotDirectory = snapshotRoot
            .appendingPathComponent(snapshotId, isDirectory: true)
        let filesDirectory = snapshotDirectory
            .appendingPathComponent("files", isDirectory: true)
        let snapshotFile = filesDirectory
            .appendingPathComponent("secret.txt", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotFile.path))
        XCTAssertEqual(try posixPermissions(at: stateURL), 0o700)
        XCTAssertEqual(try posixPermissions(at: storeURL), 0o600)
        XCTAssertEqual(try posixPermissions(at: lockURL), 0o600)
        XCTAssertEqual(try posixPermissions(at: snapshotRoot), 0o700)
        XCTAssertEqual(try posixPermissions(at: snapshotDirectory), 0o700)
        XCTAssertEqual(try posixPermissions(at: filesDirectory), 0o700)
        XCTAssertEqual(try posixPermissions(at: snapshotFile), 0o600)
    }

    func testAgentTurnDiffBaselineUsesEmptyTreeForUnbornGitRepo() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        let emptyTree = try runGitStdout(["hash-object", "-t", "tree", "/dev/null"], in: repoURL)

        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        let socketPath = makeSocketPath("hook-empty")
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
            if method == "surface.list" {
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true
                            ] as [String: Any]
                        ]
                    ]
                )
            }
            return Self.v2Response(id: id, ok: true, result: [:])
        }

        let hook = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["hooks", "codex", "prompt-submit", "--workspace", workspaceId, "--surface", surfaceId],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "PWD": repoURL.path
            ],
            currentDirectoryURL: repoURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(hook.timedOut, hook.stderr)
        XCTAssertEqual(hook.status, 0, hook.stderr)

        let storeURL = stateURL.appendingPathComponent("agent-turn-diff-baselines.json")
        let storeData = try Data(contentsOf: storeURL)
        let store = try XCTUnwrap(JSONSerialization.jsonObject(with: storeData) as? [String: Any])
        let records = try XCTUnwrap(store["records"] as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record["baseCommit"] as? String, emptyTree)

        try "created before first commit\n".write(
            to: repoURL.appendingPathComponent("new-file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let lastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(lastTurn.patch.contains("new-file.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+created before first commit"), lastTurn.patch)
    }

    func testAgentTurnDiffBaselineKeepsFirstSnapshotForDuplicateTurnHook() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("state", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)

        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        let sessionId = "session-duplicate-turn"
        let turnId = "turn-duplicate"

        func runHook(subcommand: String, input: [String: Any]) throws -> ProcessRunResult {
            let socketPath = makeSocketPath("hookdu")
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
                if method == "surface.list" {
                    return Self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": surfaceId,
                                    "ref": "surface:1",
                                    "index": 1,
                                    "focused": true
                                ] as [String: Any]
                            ]
                        ]
                    )
                }
                return Self.v2Response(id: id, ok: true, result: [:])
            }
            let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            let result = runCLI(
                cliPath: cliPath,
                socketPath: socketPath,
                arguments: ["hooks", "codex", subcommand, "--workspace", workspaceId, "--surface", surfaceId],
                environmentOverrides: [
                    "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                    "PWD": repoURL.path
                ],
                currentDirectoryURL: repoURL,
                stdinText: String(data: inputData, encoding: .utf8)
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        func runPromptSubmit() throws -> ProcessRunResult {
            try runHook(
                subcommand: "prompt-submit",
                input: [
                    "session_id": sessionId,
                    "turn_id": turnId,
                    "cwd": repoURL.path
                ]
            )
        }

        func runStop() throws -> ProcessRunResult {
            try runHook(
                subcommand: "stop",
                input: [
                    "session_id": sessionId,
                    "turn_id": turnId,
                    "cwd": repoURL.path,
                    "last_assistant_message": "done"
                ]
            )
        }

        func diffBaselineRecords() throws -> [[String: Any]] {
            let storeData = try Data(contentsOf: stateURL.appendingPathComponent("agent-turn-diff-baselines.json"))
            let store = try JSONSerialization.jsonObject(with: storeData, options: []) as? [String: Any]
            return try XCTUnwrap(store?["records"] as? [[String: Any]])
        }

        let firstHook = try runPromptSubmit()
        XCTAssertFalse(firstHook.timedOut, firstHook.stderr)
        XCTAssertEqual(firstHook.status, 0, firstHook.stderr)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let duplicateHook = try runPromptSubmit()
        XCTAssertFalse(duplicateHook.timedOut, duplicateHook.stderr)
        XCTAssertEqual(duplicateHook.status, 0, duplicateHook.stderr)

        let records = try diffBaselineRecords()
        XCTAssertEqual(records.filter { $0["turnId"] as? String == turnId }.count, 1)
        let duplicateBaseCommit = try XCTUnwrap(records.first?["baseCommit"] as? String)

        let lastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(lastTurn.patch.contains("+two"), lastTurn.patch)

        let stopHook = try runStop()
        XCTAssertFalse(stopHook.timedOut, stopHook.stderr)
        XCTAssertEqual(stopHook.status, 0, stopHook.stderr)
        try "one\ntwo\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let nextHook = try runPromptSubmit()
        XCTAssertFalse(nextHook.timedOut, nextHook.stderr)
        XCTAssertEqual(nextHook.status, 0, nextHook.stderr)

        let refreshedRecords = try diffBaselineRecords()
        XCTAssertEqual(refreshedRecords.filter { $0["turnId"] as? String == turnId }.count, 1)
        let refreshedBaseCommit = try XCTUnwrap(refreshedRecords.first?["baseCommit"] as? String)
        XCTAssertNotEqual(refreshedBaseCommit, duplicateBaseCommit)
    }

    func testDiffCommandGitSourcesDrainLargeDiffOutput() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("large.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try (0..<5_000)
            .map { "old line \($0)" }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "large.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        try (0..<5_000)
            .map { "new line \($0)" }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let large = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged", "--title", "Large git source"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(large.html.contains("Large git source"), large.html)
        XCTAssertTrue(large.patch.contains("large.txt"), large.patch)
        XCTAssertTrue(large.patch.contains("+new line 4999"), large.patch)
    }

    func testDiffCommandOpensPendingViewerBeforeGitDiffCompletes() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fakeBinURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let fakeGitURL = fakeBinURL.appendingPathComponent("git", isDirectory: false)
        let diffStartedURL = rootURL.appendingPathComponent("diff-started", isDirectory: false)
        let releaseDiffURL = rootURL.appendingPathComponent("release-diff", isDirectory: false)
        let alternateStartedURL = rootURL.appendingPathComponent("alternate-started", isDirectory: false)
        let releaseAlternateURL = rootURL.appendingPathComponent("release-alternate", isDirectory: false)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try """
        #!/bin/sh
        if [ "${1:-}" = "-C" ]; then
          shift 2
        fi
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
          printf '%s\\n' "$CMUX_FAKE_GIT_REPO_ROOT"
          exit 0
        fi
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--verify" ]; then
          : > "$CMUX_FAKE_GIT_STARTED"
          while [ ! -f "$CMUX_FAKE_GIT_RELEASE" ]; do
            sleep 0.05
          done
          exit 1
        fi
        if [ "${1:-}" = "diff" ] && [ "${2:-}" = "--cached" ]; then
          : > "$CMUX_FAKE_GIT_ALTERNATE_STARTED"
          while [ ! -f "$CMUX_FAKE_GIT_RELEASE_ALTERNATE" ]; do
            sleep 0.05
          done
          exit 0
        fi
        if [ "${1:-}" = "diff" ]; then
          : > "$CMUX_FAKE_GIT_STARTED"
          while [ ! -f "$CMUX_FAKE_GIT_RELEASE" ]; do
            sleep 0.05
          done
          cat <<'PATCH'
        diff --git a/large.txt b/large.txt
        index 1111111..2222222 100644
        --- a/large.txt
        +++ b/large.txt
        @@ -1 +1 @@
        -old line
        +new line
        PATCH
          exit 0
        fi
        if [ "${1:-}" = "for-each-ref" ]; then
          exit 0
        fi
        exit 1
        """.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGitURL.path)

        let socketPath = makeSocketPath("diff-pending")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let openedURLBox = AsyncValueBox<String?>(nil)
        let openedHTMLURLBox = AsyncValueBox<URL?>(nil)
        let pendingHTMLBox = AsyncValueBox<String?>(nil)
        let diffHadStartedWhenOpenedBox = AsyncValueBox<Bool?>(nil)
        let openHandled = expectation(description: "browser opened before fake git diff completed")
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverClosed = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "browser.open_split",
                  let params = payload["params"] as? [String: Any],
                  let rawURL = params["url"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            openedURLBox.set(rawURL)
            diffHadStartedWhenOpenedBox.set(FileManager.default.fileExists(atPath: diffStartedURL.path))
            if let htmlURL = Self.diffViewerHTMLFileURLFromHTTPManifest(for: rawURL) {
                openedHTMLURLBox.set(htmlURL)
                pendingHTMLBox.set(try? String(contentsOf: htmlURL, encoding: .utf8))
            }
            openHandled.fulfill()
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "url": rawURL]
            )
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(fakeBinURL.path):\(environment["PATH"] ?? "")"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["CMUX_FAKE_GIT_REPO_ROOT"] = repoURL.path
        environment["CMUX_FAKE_GIT_STARTED"] = diffStartedURL.path
        environment["CMUX_FAKE_GIT_RELEASE"] = releaseDiffURL.path
        environment["CMUX_FAKE_GIT_ALTERNATE_STARTED"] = alternateStartedURL.path
        environment["CMUX_FAKE_GIT_RELEASE_ALTERNATE"] = releaseAlternateURL.path
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["diff", "--unstaged", "--cwd", repoURL.path, "--title", "Slow diff", "--no-focus"]
        process.environment = environment
        process.currentDirectoryURL = repoURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        defer { terminateProcess(process) }

        wait(for: [openHandled], timeout: 5)
        XCTAssertNotNil(openedURLBox.get())
        XCTAssertEqual(diffHadStartedWhenOpenedBox.get() ?? true, false)
        let pendingHTML = try XCTUnwrap(pendingHTMLBox.get())
        let pendingPayload = try diffViewerPayload(from: pendingHTML)
        XCTAssertTrue(pendingHTML.contains("data-cmux-diff-pending=\"true\""), pendingHTML)
        XCTAssertFalse(pendingHTML.contains("data-status-only=\"true\""), pendingHTML)
        XCTAssertTrue(pendingHTML.contains("<div id=\"root\"></div>"), pendingHTML)
        XCTAssertEqual(pendingPayload["pendingReplacement"] as? Bool, true)
        XCTAssertEqual(pendingPayload["title"] as? String, "Slow diff")
        XCTAssertEqual(pendingPayload["statusIsError"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: releaseDiffURL.path))
        FileManager.default.createFile(atPath: releaseDiffURL.path, contents: Data())
        let openingHTMLURL = try XCTUnwrap(openedHTMLURLBox.get())
        XCTAssertTrue(waitUntil(timeout: 5) {
            let html = (try? String(contentsOf: openingHTMLURL, encoding: .utf8)) ?? ""
            return html.contains("data-cmux-diff-redirect=")
                && FileManager.default.fileExists(atPath: alternateStartedURL.path)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: releaseAlternateURL.path))
        XCTAssertTrue(process.isRunning)
        FileManager.default.createFile(atPath: releaseAlternateURL.path, contents: Data())

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        wait(for: [serverClosed], timeout: 5)

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertTrue(stdout.contains("OK surface=surface-id pane=pane-id"), stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diffStartedURL.path))

        let openingURL = try XCTUnwrap(openedURLBox.get())
        let htmlURL = try resolvedDiffViewerHTMLFileURL(openingHTMLURL, from: ["url": openingURL])
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let patch = try String(contentsOf: htmlURL.deletingPathExtension().appendingPathExtension("patch"), encoding: .utf8)
        XCTAssertFalse(html.contains("data-cmux-diff-pending=\"true\""), html)
        XCTAssertTrue(html.contains("Slow diff"), html)
        XCTAssertTrue(patch.contains("+new line"), patch)
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

    func testTopCommandForwardsWindowFlag() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let windowId = "11111111-1111-1111-1111-111111111111"
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:2", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "id": windowId,
                    "workspaces": [],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload) { params in
            XCTAssertEqual(params["window_id"] as? String, windowId)
            XCTAssertEqual(params["all_windows"] as? Bool, false)
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--window", windowId]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("window window:2"), result.stdout)
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

    private func runCLI(
        cliPath: String,
        socketPath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        stdinText: String? = nil
    ) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        return runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 15,
            currentDirectoryURL: currentDirectoryURL,
            stdinText: stdinText
        )
    }

    private func runDiffCLIAndReadHTML(
        cliPath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        readPatchSidecar: Bool = true,
        socketResponse: (@Sendable (String) -> String?)? = nil
    ) throws -> (html: String, patch: String, params: [String: Any], stdout: String) {
        let socketPath = makeSocketPath("diff-src")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let response = socketResponse?(line) {
                return response
            }
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "browser.open_split",
                  let params = payload["params"] as? [String: Any],
                  let rawURL = params["url"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "url": rawURL]
            )
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            currentDirectoryURL: currentDirectoryURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let commandPayload = try XCTUnwrap(
            state.commands.compactMap { Self.v2Payload(from: $0) }.first { payload in
                payload["method"] as? String == "browser.open_split"
            }
        )
        let params = try XCTUnwrap(commandPayload["params"] as? [String: Any])
        let rawURL = try XCTUnwrap(params["url"] as? String)
        XCTAssertEqual(params["bypass_remote_proxy"] as? Bool, true)
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        XCTAssertEqual(viewerURL.scheme, "http")
        XCTAssertEqual(viewerURL.host, "127.0.0.1")
        XCTAssertEqual(viewerURL.fragment, "cmux-diff-viewer")
        XCTAssertNil(params["diff_viewer_token"])
        XCTAssertNil(params["diff_viewer_files"])
        let openedFileURL = try diffViewerHTMLFileURL(for: rawURL, from: params)
        let viewerFileURL = try resolvedDiffViewerHTMLFileURL(openedFileURL, from: params)
        if openedFileURL != viewerFileURL {
            defer { try? FileManager.default.removeItem(at: openedFileURL) }
        }
        defer { try? FileManager.default.removeItem(at: viewerFileURL) }
        let html = try String(contentsOf: viewerFileURL, encoding: .utf8)
        let patchURL = viewerFileURL.deletingPathExtension().appendingPathExtension("patch")
        let patch: String
        if readPatchSidecar {
            defer { try? FileManager.default.removeItem(at: patchURL) }
            patch = try String(contentsOf: patchURL, encoding: .utf8)
        } else {
            patch = ""
        }
        return (html, patch, params, result.stdout)
    }

    private func resolvedDiffViewerHTMLFileURL(_ fileURL: URL, from params: [String: Any]) throws -> URL {
        var current = fileURL
        for _ in 0..<4 {
            let html = try String(contentsOf: current, encoding: .utf8)
            guard let redirectURL = Self.diffViewerRedirectURL(from: html) else {
                return current
            }
            current = try diffViewerHTMLFileURL(for: redirectURL, from: params)
        }
        return current
    }

    private static func diffViewerRedirectURL(from html: String) -> String? {
        let marker = "data-cmux-diff-redirect=\""
        guard let start = html.range(of: marker)?.upperBound else { return nil }
        let tail = html[start...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private func diffViewerHTMLFileURL(from params: [String: Any]) throws -> URL {
        let rawURL = try XCTUnwrap(params["url"] as? String)
        return try diffViewerHTMLFileURL(for: rawURL, from: params)
    }

    private static func diffViewerHTMLFileURLFromHTTPManifest(for rawURL: String) -> URL? {
        guard let viewerURL = URL(string: rawURL),
              viewerURL.scheme == "http",
              viewerURL.host == "127.0.0.1" else {
            return nil
        }
        let requestPath = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? viewerURL.path
        let pathParts = requestPath.split(separator: "/", omittingEmptySubsequences: true)
        guard let token = pathParts.first.map(String.init),
              !token.isEmpty else {
            return nil
        }
        let manifestRequestPath = "/" + pathParts.dropFirst().joined(separator: "/")
        let manifestURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = manifest["files"] as? [[String: Any]],
              let entry = files.first(where: { file in
                  file["request_path"] as? String == manifestRequestPath &&
                      file["mime_type"] as? String == "text/html"
              }),
              let filePath = entry["file_path"] as? String else {
            return nil
        }
        return URL(fileURLWithPath: filePath, isDirectory: false)
    }

    private func diffViewerHTMLFileURL(for rawURL: String, from params: [String: Any]) throws -> URL {
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        if viewerURL.scheme == "http" {
            XCTAssertEqual(viewerURL.host, "127.0.0.1")
            let files = try diffViewerAllowedFiles(for: rawURL, from: params)
            let manifestRequestPath = try diffViewerManifestRequestPath(for: viewerURL)
            let entry = try XCTUnwrap(files.first { file in
                file["request_path"] as? String == manifestRequestPath &&
                    file["mime_type"] as? String == "text/html"
            })
            let filePath = try XCTUnwrap(entry["file_path"] as? String)
            return URL(fileURLWithPath: filePath, isDirectory: false)
        }

        let files = try XCTUnwrap(params["diff_viewer_files"] as? [[String: Any]])
        let rawRequestPath = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? viewerURL.path
        let requestPath = rawRequestPath.isEmpty ? "/" : rawRequestPath
        let entry = try XCTUnwrap(files.first { file in
            file["request_path"] as? String == requestPath &&
            file["mime_type"] as? String == "text/html"
        })
        let filePath = try XCTUnwrap(entry["file_path"] as? String)
        return URL(fileURLWithPath: filePath, isDirectory: false)
    }

    private func diffViewerAllowedFiles(for rawURL: String, from params: [String: Any]) throws -> [[String: Any]] {
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        if viewerURL.scheme == "http" {
            let token = try diffViewerHTTPToken(for: viewerURL)
            let manifestURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
                .appendingPathComponent(".manifest-\(token).json", isDirectory: false)
            let manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            )
            return try XCTUnwrap(manifest["files"] as? [[String: Any]])
        }
        return try XCTUnwrap(params["diff_viewer_files"] as? [[String: Any]])
    }

    private func diffViewerHTTPToken(for url: URL) throws -> String {
        let requestPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let pathParts = requestPath.split(separator: "/", omittingEmptySubsequences: true)
        return try XCTUnwrap(pathParts.first.map(String.init))
    }

    private func diffViewerManifestRequestPath(for url: URL) throws -> String {
        let requestPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let pathParts = requestPath.split(separator: "/", omittingEmptySubsequences: true)
        _ = try XCTUnwrap(pathParts.first)
        return "/" + pathParts.dropFirst().joined(separator: "/")
    }

    private func diffViewerConfig(from html: String) throws -> [String: Any] {
        let marker = "<script id=\"cmux-diff-viewer-config\" type=\"application/json\">"
        let start = try XCTUnwrap(html.range(of: marker)?.upperBound)
        let tail = html[start...]
        let end = try XCTUnwrap(tail.range(of: "</script>")?.lowerBound)
        let json = String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func diffViewerPayload(from html: String) throws -> [String: Any] {
        try diffViewerPayload(from: diffViewerConfig(from: html))
    }

    private func diffViewerPayload(from config: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(config["payload"] as? [String: Any])
    }

    private func diffViewerAssets(from config: [String: Any]) throws -> [String: String] {
        let assets = try XCTUnwrap(config["assets"] as? [String: Any])
        var result: [String: String] = [:]
        for (key, value) in assets {
            result[key] = try XCTUnwrap(value as? String)
        }
        return result
    }

    private func diffViewerOptionURL(value: String, in options: [[String: Any]]) throws -> String {
        let option = try XCTUnwrap(options.first { option in
            option["value"] as? String == value
        })
        XCTAssertEqual(option["disabled"] as? Bool, false)
        return try XCTUnwrap(option["url"] as? String)
    }

    private func runDiffCLIExpectingNoOpen(
        cliPath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL? = nil
    ) -> ProcessRunResult {
        let socketPath = makeSocketPath("diff-no")
        guard let listenerFD = try? bindUnixSocket(at: socketPath) else {
            return ProcessRunResult(status: -1, stdout: "", stderr: "failed to bind socket", timedOut: false)
        }
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        _ = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-open"])
        }
        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            currentDirectoryURL: currentDirectoryURL
        )
        XCTAssertTrue(state.commands.isEmpty, state.commands.joined(separator: "\n"))
        return result
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let result = runGitProcess(arguments, in: directory)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.timedOut, result.stderr)
        if result.status != 0 {
            throw NSError(domain: "CMUXOpenCommandTests.git", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
    }

    private func runGitStdout(_ arguments: [String], in directory: URL) throws -> String {
        let result = runGitProcess(arguments, in: directory)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.timedOut, result.stderr)
        guard result.status == 0 else {
            throw NSError(domain: "CMUXOpenCommandTests.git", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue) & 0o777
    }

    private func runGitProcess(_ arguments: [String], in directory: URL) -> ProcessRunResult {
        runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git"] + arguments,
            environment: ProcessInfo.processInfo.environment,
            timeout: 30,
            currentDirectoryURL: directory
        )
    }

    private func writeDiffBaselineStore(
        stateDirectoryURL: URL,
        repoURL: URL,
        workspaceId: String,
        surfaceId: String,
        baseCommit: String,
        untrackedPaths: [String]? = nil
    ) throws {
        var record: [String: Any] = [
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "sessionId": "session-1",
            "turnId": "turn-1",
            "agent": "codex",
            "repoRoot": repoURL.standardizedFileURL.path,
            "baseCommit": baseCommit,
            "capturedAt": Date().timeIntervalSince1970
        ]
        if let untrackedPaths {
            record["untrackedPaths"] = untrackedPaths
            var untrackedPathHashes: [String: String] = [:]
            let snapshotId = UUID().uuidString
            let snapshotRoot = stateDirectoryURL
                .appendingPathComponent("agent-turn-diff-baseline-snapshots", isDirectory: true)
                .appendingPathComponent(snapshotId, isDirectory: true)
                .appendingPathComponent("files", isDirectory: true)
            for path in untrackedPaths {
                let hash = try runGitStdout(["hash-object", "--no-filters", "--", path], in: repoURL)
                let snapshotURL = snapshotRoot.appendingPathComponent(path, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(
                    at: repoURL.appendingPathComponent(path, isDirectory: false),
                    to: snapshotURL
                )
                untrackedPathHashes[path] = hash
            }
            record["untrackedPathHashes"] = untrackedPathHashes
            record["untrackedSnapshotId"] = snapshotId
        }
        let payload: [String: Any] = [
            "version": 1,
            "records": [record]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: stateDirectoryURL.appendingPathComponent("agent-turn-diff-baselines.json"), options: .atomic)
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func writeTestDiffViewerAssets(resourcesURL: URL, appMain: String) throws {
        let diffViewerURL = resourcesURL
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("diff-viewer", isDirectory: true)
        let appURL = resourcesURL
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("diff-viewer-app", isDirectory: true)
        let workerPoolURL = diffViewerURL.appendingPathComponent("worker-pool", isDirectory: true)
        try FileManager.default.createDirectory(at: workerPoolURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try "export const diffsFixture = true;\n".write(
            to: diffViewerURL.appendingPathComponent("diffs.mjs", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "export const treesFixture = true;\n".write(
            to: diffViewerURL.appendingPathComponent("trees.mjs", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "export const workerPoolFixture = true;\n".write(
            to: workerPoolURL.appendingPathComponent("worker-pool.mjs", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "self.cmuxWorkerFixture = true;\n".write(
            to: workerPoolURL.appendingPathComponent("worker-portable.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try appMain.write(
            to: appURL.appendingPathComponent("main.mjs", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        currentDirectoryURL: URL? = nil,
        stdinText: String? = nil
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe?
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        if let stdinText, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(stdinText.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(status: timedOut ? 124 : process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    private func readLine(from handle: FileHandle, timeout: TimeInterval) throws -> String {
        let finished = DispatchSemaphore(value: 0)
        let dataBox = AsyncValueBox(Data())
        DispatchQueue.global(qos: .userInitiated).async {
            var line = Data()
            while line.count < 1024 {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty || byte == Data([0x0a]) {
                    break
                }
                line.append(byte)
            }
            dataBox.set(line)
            finished.signal()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "cmux.tests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "timed out reading process line",
            ])
        }
        return String(data: dataBox.get(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func fetchData(from url: URL, timeout: TimeInterval) throws -> (data: Data, statusCode: Int) {
        let finished = DispatchSemaphore(value: 0)
        let resultBox = AsyncValueBox<(Data?, Int?, Error?)>((nil, nil, nil))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: url) { data, response, error in
            resultBox.set((data, (response as? HTTPURLResponse)?.statusCode, error))
            finished.signal()
        }
        task.resume()

        guard finished.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            throw NSError(domain: "cmux.tests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "timed out fetching \(url.absoluteString)",
            ])
        }
        session.invalidateAndCancel()

        let (data, statusCode, error) = resultBox.get()
        if let error {
            throw error
        }
        return (data ?? Data(), statusCode ?? 0)
    }

    private func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1)
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
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

    private func startTopMockServer(
        listenerFD: Int32,
        payload: [String: Any],
        assertParams: (([String: Any]) -> Void)? = nil
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: MockSocketServerState()) { line in
            guard let request = Self.v2Payload(from: line),
                  let id = request["id"] as? String,
                  request["method"] as? String == "system.top" else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            assertParams?(request["params"] as? [String: Any] ?? [:])
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
