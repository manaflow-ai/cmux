import XCTest
import Foundation
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Codex monitor and launchd-parented attribution
extension CmuxTopSnapshotScopeTests {
    func testCodexMonitorArgumentsSupportJoinedUUIDOptions() throws {
        let workspaceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let surfaceID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

        let scope = try XCTUnwrap(CmuxTopProcessSnapshot.cmuxScope(
            arguments: [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "hooks",
                "codex",
                "monitor",
                "--workspace=\(workspaceID.uuidString)",
                "--surface=\(surfaceID.uuidString)"
            ],
            environment: [:]
        ))

        XCTAssertEqual(scope.workspaceID, workspaceID)
        XCTAssertEqual(scope.surfaceID, surfaceID)
        XCTAssertEqual(scope.attributionReason, "cmux-hook-arguments")
    }

    func testCodexMonitorArgumentsIgnorePathValuedSubcommandLookalikes() {
        let workspaceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        let scope = CmuxTopProcessSnapshot.cmuxScope(
            arguments: [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "other",
                "/tmp/hooks",
                "/tmp/codex",
                "/tmp/monitor",
                "--workspace",
                workspaceID.uuidString
            ],
            environment: [:]
        )

        XCTAssertNil(scope)
    }

    func testCodexMonitorArgumentsRequireCmuxExecutable() {
        let workspaceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        let scope = CmuxTopProcessSnapshot.cmuxScope(
            arguments: [
                "hooks",
                "codex",
                "monitor",
                "--workspace",
                workspaceID.uuidString
            ],
            environment: [:]
        )

        XCTAssertNil(scope)
    }

    @MainActor
    func testLaunchdParentedCodexMonitorArgumentsAttachToOwningSurface() throws {
        let workspaceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let surfaceID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let monitorPID = 4242
        let bytes = kernProcArgs(
            arguments: [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "hooks",
                "codex",
                "monitor",
                "--workspace",
                workspaceID.uuidString,
                "--surface",
                surfaceID.uuidString,
                "--session",
                "session-1"
            ],
            environment: []
        )
        let scope = try XCTUnwrap(CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes))
        XCTAssertEqual(scope.workspaceID, workspaceID)
        XCTAssertEqual(scope.surfaceID, surfaceID)

        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: monitorPID,
                    parentPID: 1,
                    name: "cmux",
                    path: "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    ttyDevice: nil,
                    cmuxWorkspaceID: scope.workspaceID,
                    cmuxSurfaceID: scope.surfaceID,
                    cmuxAttributionReason: scope.attributionReason,
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 64 * 1024 * 1024,
                    virtualBytes: 128 * 1024 * 1024,
                    threadCount: 4
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        var windows: [[String: Any]] = [[
            "kind": "window",
            "id": UUID().uuidString,
            "index": 0,
            "key": true,
            "visible": true,
            "app_process_pids": [],
            "workspaces": [[
                "kind": "workspace",
                "id": workspaceID.uuidString,
                "index": 0,
                "title": "hook monitor fixture",
                "selected": true,
                "pinned": false,
                "tags": [],
                "panes": [[
                    "kind": "pane",
                    "id": UUID().uuidString,
                    "index": 0,
                    "surfaces": [[
                        "kind": "surface",
                        "id": surfaceID.uuidString,
                        "index": 0,
                        "type": "terminal",
                        "title": "codex monitor owner",
                        "webviews": []
                    ] as [String: Any]]
                ] as [String: Any]]
            ] as [String: Any]]
        ]]

        let totalPIDs = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot,
            browserPIDOccurrences: [:],
            includeProcesses: true
        )
        let surface = try firstSurface(in: windows)
        let resources = try XCTUnwrap(surface["resources"] as? [String: Any])
        let processes = try XCTUnwrap(surface["processes"] as? [[String: Any]])
        let monitorProcess = try XCTUnwrap(processes.first)

        XCTAssertEqual(intArray(resources["pids"]), [monitorPID])
        XCTAssertEqual(int(resources["process_count"]), 1)
        XCTAssertEqual(int(monitorProcess["pid"]), monitorPID)
        XCTAssertEqual(int(monitorProcess["ppid"]), 1)
        XCTAssertEqual(monitorProcess["attribution_reason"] as? String, "cmux-hook-arguments")
        XCTAssertTrue(totalPIDs.contains(monitorPID))
    }

    @MainActor
    func testLaunchdParentedWebKitRootProcessStaysUnderBrowserWebView() throws {
        let workspaceID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let surfaceID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let webContentPID = 4343
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: webContentPID,
                    parentPID: 1,
                    name: "com.apple.WebKit.WebContent",
                    path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                    ttyDevice: nil,
                    cmuxWorkspaceID: nil,
                    cmuxSurfaceID: nil,
                    cmuxAttributionReason: nil,
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 32 * 1024 * 1024,
                    virtualBytes: 256 * 1024 * 1024,
                    threadCount: 8
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        var windows: [[String: Any]] = [[
            "kind": "window",
            "id": UUID().uuidString,
            "index": 0,
            "key": true,
            "visible": true,
            "app_process_pids": [],
            "workspaces": [[
                "kind": "workspace",
                "id": workspaceID.uuidString,
                "index": 0,
                "title": "webkit fixture",
                "selected": true,
                "pinned": false,
                "tags": [],
                "panes": [[
                    "kind": "pane",
                    "id": UUID().uuidString,
                    "index": 0,
                    "surfaces": [[
                        "kind": "surface",
                        "id": surfaceID.uuidString,
                        "index": 0,
                        "type": "browser",
                        "title": "browser owner",
                        "webviews": [[
                            "kind": "webview",
                            "id": "\(surfaceID.uuidString):webview",
                            "index": 0,
                            "title": "WebView",
                            "pid": webContentPID
                        ] as [String: Any]]
                    ] as [String: Any]]
                ] as [String: Any]]
            ] as [String: Any]]
        ]]
        let browserPIDOccurrences = TerminalController.shared.v2TopBrowserPIDOccurrences(in: windows)

        let totalPIDs = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: true
        )
        let webview = try firstWebView(in: windows)
        let resources = try XCTUnwrap(webview["resources"] as? [String: Any])
        let processes = try XCTUnwrap(webview["processes"] as? [[String: Any]])
        let webContentProcess = try XCTUnwrap(processes.first)

        XCTAssertEqual(intArray(resources["pids"]), [webContentPID])
        XCTAssertEqual(int(resources["process_count"]), 1)
        XCTAssertEqual(int(webContentProcess["pid"]), webContentPID)
        XCTAssertEqual(int(webContentProcess["ppid"]), 1)
        XCTAssertEqual(webContentProcess["attribution_reason"] as? String, "webview-root-pid")
        XCTAssertTrue(totalPIDs.contains(webContentPID))
    }

    private func firstSurface(in windows: [[String: Any]]) throws -> [String: Any] {
        let workspaces = try XCTUnwrap(windows[0]["workspaces"] as? [[String: Any]])
        let panes = try XCTUnwrap(workspaces[0]["panes"] as? [[String: Any]])
        let surfaces = try XCTUnwrap(panes[0]["surfaces"] as? [[String: Any]])
        return try XCTUnwrap(surfaces.first)
    }

    private func firstWebView(in windows: [[String: Any]]) throws -> [String: Any] {
        let surface = try firstSurface(in: windows)
        let webviews = try XCTUnwrap(surface["webviews"] as? [[String: Any]])
        return try XCTUnwrap(webviews.first)
    }

}
