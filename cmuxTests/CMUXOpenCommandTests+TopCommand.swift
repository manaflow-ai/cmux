import Darwin
import Foundation
import XCTest


// MARK: - Top command
extension CMUXOpenCommandTests {
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

    static func v2Payload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    static func v2Response(
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
