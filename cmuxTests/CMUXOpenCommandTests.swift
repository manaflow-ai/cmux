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
        let cmuxAppSupportConfigURL = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
        let ghosttyResourcesURL = rootURL.appendingPathComponent("ghostty-resources", isDirectory: true)
        let ghosttyThemesURL = ghosttyResourcesURL.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ghosttyConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        theme = light:Unit Light,dark:Unit Dark
        """
        try ghosttyConfigContents.write(to: ghosttyConfigURL, atomically: true, encoding: .utf8)
        try ghosttyConfigContents.write(to: cmuxAppSupportConfigURL, atomically: true, encoding: .utf8)
        try """
        diff --git a/hello.txt b/hello.txt
        index 8ab686e..d95f3ad 100644
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +three
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
                  viewerURL.isFileURL else {
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
        let rawURL = try XCTUnwrap(params["url"] as? String)
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        defer { try? FileManager.default.removeItem(at: viewerURL) }

        let html = try String(contentsOf: viewerURL, encoding: .utf8)
        XCTAssertTrue(html.contains("Review diff"), html)
        XCTAssertTrue(html.contains("CodeView"), html)
        XCTAssertTrue(html.contains("parsePatchFiles"), html)
        XCTAssertTrue(html.contains("preloadHighlighter"), html)
        XCTAssertTrue(html.contains("registerCustomTheme"), html)
        XCTAssertTrue(html.contains("renderUntilCodeViewReady"), html)
        XCTAssertTrue(html.contains("forceRenderReadyCodeViewItems"), html)
        XCTAssertTrue(html.contains("stickyHeaders: true"), html)
        XCTAssertTrue(html.contains("--diffs-font-size"), html)
        XCTAssertTrue(html.contains("\"fontFamily\":\"Unit Mono\""), html)
        XCTAssertTrue(html.contains("\"fontSize\":13"), html)
        XCTAssertFalse(html.contains("\"fontSize\":15"), html)
        XCTAssertTrue(html.contains("\"dark\":\"cmux-ghostty-dark-"), html)
        XCTAssertTrue(html.contains("\"light\":\"cmux-ghostty-light-"), html)
        XCTAssertTrue(html.contains("Unit Light"), html)
        XCTAssertTrue(html.contains("Unit Dark"), html)
        XCTAssertTrue(html.contains("#101820"), html)
        XCTAssertTrue(html.contains("#f8f8f2"), html)
        XCTAssertTrue(html.contains("hello.txt"), html)
        XCTAssertTrue(html.contains("\"layout\":\"unified\""), html)
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
        environmentOverrides: [String: String] = [:]
    ) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        return runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 5)
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

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
