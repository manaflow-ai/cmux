import Darwin
import Foundation
import XCTest


// MARK: - Diff command viewer
extension CMUXOpenCommandTests {
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
        XCTAssertTrue(html.contains("<script id=\"cmux-diff-viewer-config\" type=\"application/json\">"), html)
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
        XCTAssertTrue(html.contains("#101820"), html)
        XCTAssertTrue(html.contains("#f8f8f2"), html)
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
        let startedAt = Date()
        let response = try fetchData(from: url, timeout: 3)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
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

    func diffViewerPayload(from html: String) throws -> [String: Any] {
        try diffViewerPayload(from: diffViewerConfig(from: html))
    }

    private func diffViewerPayload(from config: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(config["payload"] as? [String: Any])
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

}
