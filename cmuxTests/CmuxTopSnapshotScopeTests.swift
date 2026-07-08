import XCTest
import Foundation
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxTopSnapshotScopeTests: XCTestCase {
    func testProcessForegroundGroupRequiresTerminalForegroundMatch() {
        let foreground = makeProcessInfo(processGroupID: 10, terminalProcessGroupID: 10)
        let background = makeProcessInfo(processGroupID: 11, terminalProcessGroupID: 10)
        let detached = makeProcessInfo(processGroupID: nil, terminalProcessGroupID: nil)

        XCTAssertTrue(foreground.isTerminalForegroundProcessGroup)
        XCTAssertFalse(background.isTerminalForegroundProcessGroup)
        XCTAssertFalse(detached.isTerminalForegroundProcessGroup)
    }

    @MainActor
    func testWindowRollupMatchesPSForApplicationProcessTree() throws {
        let fixture = try SpawnedProcessTree.start()
        defer { fixture.terminate() }

        let snapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        var windows: [[String: Any]] = [[
            "kind": "window",
            "id": UUID().uuidString,
            "index": 0,
            "key": true,
            "visible": true,
            "app_process_pids": [fixture.parentPID],
            "workspaces": [[
                "kind": "workspace",
                "id": UUID().uuidString,
                "index": 0,
                "title": "process tree fixture",
                "selected": true,
                "pinned": false,
                "panes": [],
                "tags": fixture.childPIDs.enumerated().map { index, pid in
                    [
                        "kind": "tag",
                        "id": "fixture:\(index)",
                        "index": index,
                        "key": "fixture-\(index)",
                        "value": "",
                        "visible": true,
                        "pid": pid
                    ] as [String: Any]
                }
            ] as [String: Any]]
        ]]

        let totalPIDs = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot,
            browserPIDOccurrences: [:],
            includeProcesses: false
        )
        let resources = try XCTUnwrap(windows[0]["resources"] as? [String: Any])
        let rolledRSS = int64(resources["resident_bytes"])
        let expectedRSS = try psResidentBytesForRecursiveTree(rootPID: fixture.parentPID)
        let processIDs = Set(intArray(resources["pids"]))

        XCTAssertTrue(processIDs.contains(fixture.parentPID))
        XCTAssertTrue(totalPIDs.contains(fixture.parentPID))
        XCTAssertLessThanOrEqual(abs(rolledRSS - expectedRSS), 8 * 1024 * 1024)
    }

    @MainActor
    func testApplicationProcessDoesNotExpandIntoOtherWindowResources() throws {
        let fixture = try SpawnedProcessTree.start()
        defer { fixture.terminate() }

        let snapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        var windows: [[String: Any]] = [
            [
                "kind": "window",
                "id": UUID().uuidString,
                "index": 0,
                "key": true,
                "visible": true,
                "app_process_pids": [fixture.parentPID],
                "workspaces": []
            ],
            [
                "kind": "window",
                "id": UUID().uuidString,
                "index": 1,
                "key": false,
                "visible": true,
                "app_process_pids": [],
                "workspaces": [[
                    "kind": "workspace",
                    "id": UUID().uuidString,
                    "index": 0,
                    "title": "other window",
                    "selected": true,
                    "pinned": false,
                    "panes": [],
                    "tags": fixture.childPIDs.enumerated().map { index, pid in
                        [
                            "kind": "tag",
                            "id": "fixture:\(index)",
                            "index": index,
                            "key": "fixture-\(index)",
                            "value": "",
                            "visible": true,
                            "pid": pid
                        ] as [String: Any]
                    }
                ] as [String: Any]]
            ]
        ]

        let totalPIDs = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot,
            browserPIDOccurrences: [:],
            includeProcesses: false
        )
        let keyResources = try XCTUnwrap(windows[0]["resources"] as? [String: Any])
        let otherResources = try XCTUnwrap(windows[1]["resources"] as? [String: Any])
        let keyProcessIDs = Set(intArray(keyResources["pids"]))
        let otherProcessIDs = Set(intArray(otherResources["pids"]))

        XCTAssertTrue(keyProcessIDs.contains(fixture.parentPID))
        XCTAssertTrue(keyProcessIDs.isDisjoint(with: fixture.childPIDs))
        XCTAssertFalse(otherProcessIDs.contains(fixture.parentPID))
        XCTAssertTrue(fixture.childPIDs.allSatisfy { otherProcessIDs.contains($0) })
        XCTAssertTrue(([fixture.parentPID] + fixture.childPIDs).allSatisfy { totalPIDs.contains($0) })
    }

    @MainActor
    func testSharedWebViewResourceRowsAreAttributedAcrossOccurrences() throws {
        let fixture = try SpawnedProcessTree.start()
        defer { fixture.terminate() }

        let snapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        var windows: [[String: Any]] = [[
            "kind": "window",
            "id": UUID().uuidString,
            "index": 0,
            "key": true,
            "visible": true,
            "app_process_pids": [],
            "workspaces": [[
                "kind": "workspace",
                "id": UUID().uuidString,
                "index": 0,
                "title": "shared webview fixture",
                "selected": true,
                "pinned": false,
                "tags": [],
                "panes": [[
                    "kind": "pane",
                    "id": UUID().uuidString,
                    "index": 0,
                    "surfaces": [
                        sharedWebViewSurface(pid: fixture.parentPID),
                        sharedWebViewSurface(pid: fixture.parentPID)
                    ]
                ] as [String: Any]]
            ] as [String: Any]]
        ]]

        let browserPIDOccurrences = TerminalController.shared.v2TopBrowserPIDOccurrences(in: windows)
        XCTAssertEqual(browserPIDOccurrences[fixture.parentPID], 2)

        _ = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: false
        )

        let windowResources = try XCTUnwrap(windows[0]["resources"] as? [String: Any])
        let windowMemoryBytes = int64(windowResources["memory_bytes"])
        let windowResidentBytes = int64(windowResources["resident_bytes"])
        let webViewMemoryBytes = try annotatedWebViewResources(in: windows)
            .map { int64($0["memory_bytes"]) }
        let webViewResidentBytes = try annotatedWebViewResources(in: windows)
            .map { int64($0["resident_bytes"]) }

        XCTAssertGreaterThan(windowMemoryBytes, 0)
        XCTAssertGreaterThan(windowResidentBytes, 0)
        XCTAssertEqual(webViewMemoryBytes.count, 2)
        XCTAssertEqual(webViewResidentBytes.count, 2)
        for memoryBytes in webViewMemoryBytes {
            XCTAssertLessThanOrEqual(abs(memoryBytes * 2 - windowMemoryBytes), 1)
        }
        for residentBytes in webViewResidentBytes {
            XCTAssertLessThanOrEqual(abs(residentBytes * 2 - windowResidentBytes), 1)
        }
    }

    func testApplicationProcessAttachesToKeyWindow() {
        var windows: [[String: Any]] = [
            ["kind": "window", "id": "first", "key": false],
            ["kind": "window", "id": "second", "key": true],
            ["kind": "window", "id": "third", "key": false]
        ]

        TerminalController.shared.v2AttachTopApplicationProcess(to: &windows)

        XCTAssertEqual(intArray(windows[0]["app_process_pids"]), [])
        XCTAssertEqual(intArray(windows[1]["app_process_pids"]), [Int(Darwin.getpid())])
        XCTAssertEqual(intArray(windows[2]["app_process_pids"]), [])
    }

    func testApplicationProcessFallsBackToFirstWindowWithoutKeyWindow() {
        var windows: [[String: Any]] = [
            ["kind": "window", "id": "first", "key": false],
            ["kind": "window", "id": "second", "key": false]
        ]

        TerminalController.shared.v2AttachTopApplicationProcess(to: &windows)

        XCTAssertEqual(intArray(windows[0]["app_process_pids"]), [Int(Darwin.getpid())])
        XCTAssertEqual(intArray(windows[1]["app_process_pids"]), [])
    }

    func testApplicationProcessIsNotAttachedForWorkspaceScope() {
        var windows: [[String: Any]] = [
            ["kind": "window", "id": "workspace-window", "key": true]
        ]

        TerminalController.shared.v2AttachTopApplicationProcess(
            to: &windows,
            workspaceFilter: UUID()
        )

        XCTAssertEqual(intArray(windows[0]["app_process_pids"]), [])
    }

    @MainActor
    func testApplicationProcessTreeIsExposedAtWindowLevel() throws {
        let fixture = try SpawnedProcessTree.start()
        defer { fixture.terminate() }

        let snapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        var windows: [[String: Any]] = [[
            "kind": "window",
            "id": UUID().uuidString,
            "index": 0,
            "key": true,
            "visible": true,
            "app_process_pids": [fixture.parentPID],
            "workspaces": []
        ]]

        _ = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot,
            browserPIDOccurrences: [:],
            includeProcesses: true
        )

        let processes = try XCTUnwrap(windows[0]["processes"] as? [[String: Any]])
        let rootProcess = try XCTUnwrap(processes.first)
        let rootResources = try XCTUnwrap(rootProcess["resources"] as? [String: Any])

        let rootPID = try XCTUnwrap(int(rootProcess["pid"]))
        XCTAssertEqual(rootPID, fixture.parentPID)
        XCTAssertEqual(intArray(rootResources["pids"]), [fixture.parentPID])
    }

    func testSummaryPayloadIncludesPhysicalFootprintMemoryBytes() throws {
        let pid = Int(Darwin.getpid())
        let expectedFootprintBytes = try XCTUnwrap(
            physicalFootprintBytes(for: pid),
            "proc_pid_rusage did not return physical footprint for current process"
        )

        let snapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        let payload = snapshot.summaryPayload(for: [pid])
        let memoryBytes = int64(payload["memory_bytes"])

        XCTAssertGreaterThan(memoryBytes, 0)
        XCTAssertLessThanOrEqual(
            abs(memoryBytes - expectedFootprintBytes),
            max(16 * 1024 * 1024, expectedFootprintBytes / 5)
        )
    }

    func testSamplePayloadDescribesPhysicalFootprintFallbackSource() {
        let sample = CmuxTopProcessSnapshot.capture(includeProcessDetails: false).samplePayload()

        XCTAssertEqual(
            sample["memory_source"] as? String,
            CmuxTopProcessMemorySource.physicalFootprint.rawValue
        )
        XCTAssertEqual(
            sample["memory_fallback_source"] as? String,
            CmuxTopProcessMemorySource.residentSize.rawValue
        )
        XCTAssertEqual(
            sample["resident_memory_fallback_source"] as? String,
            CmuxTopProcessMemorySource.rusageResidentSize.rawValue
        )
        XCTAssertEqual(sample["cmux_scope"] as? Bool, true)

        let unscopedSnapshot = CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false,
            includesCMUXScope: false
        )
        XCTAssertEqual(unscopedSnapshot.samplePayload()["cmux_scope"] as? Bool, false)

        let fallbackSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: 1,
                    parentPID: 0,
                    name: "resident-fallback",
                    path: nil,
                    ttyDevice: nil,
                    cmuxWorkspaceID: nil,
                    cmuxSurfaceID: nil,
                    cmuxAttributionReason: nil,
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 1024,
                    residentMemorySource: .rusageResidentSize,
                    virtualBytes: 0,
                    threadCount: 1
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )
        let fallbackSample = fallbackSnapshot.samplePayload()
        XCTAssertEqual(
            fallbackSample["resident_memory_source"] as? String,
            CmuxTopProcessMemorySource.rusageResidentSize.rawValue
        )
        XCTAssertEqual(
            fallbackSample["resident_memory_sources"] as? [String],
            [CmuxTopProcessMemorySource.rusageResidentSize.rawValue]
        )
    }

    func testUnavailableMemorySourcesAreExposedInAggregatePayloads() throws {
        func makeProcess(pid: Int, name: String, unavailable: Bool) -> CmuxTopProcessInfo {
            CmuxTopProcessInfo(
                pid: pid,
                parentPID: 0,
                name: name,
                path: nil,
                ttyDevice: nil,
                cmuxWorkspaceID: nil,
                cmuxSurfaceID: nil,
                cmuxAttributionReason: nil,
                processGroupID: nil,
                terminalProcessGroupID: nil,
                cpuPercent: unavailable ? 1 : 2,
                memoryBytes: unavailable ? 0 : 2048,
                memorySource: unavailable ? .unavailable : .residentSize,
                residentBytes: unavailable ? 0 : 1024,
                residentMemorySource: unavailable ? .unavailable : .rusageResidentSize,
                virtualBytes: unavailable ? 0 : 4096,
                threadCount: 1
            )
        }

        // Coding agents are folded out of program rows, so use a non-agent pair for
        // the summary/program assertions and an agent pair for the coding-agent one.
        let unavailablePID = 1111
        let fallbackPID = 2222
        let agentUnavailablePID = 3333
        let agentFallbackPID = 4444
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                makeProcess(pid: unavailablePID, name: "worker", unavailable: true),
                makeProcess(pid: fallbackPID, name: "worker", unavailable: false),
                makeProcess(pid: agentUnavailablePID, name: "codex", unavailable: true),
                makeProcess(pid: agentFallbackPID, name: "codex", unavailable: false)
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )

        let summary = snapshot.summaryPayload(for: [unavailablePID, fallbackPID])
        assertUnavailableMemoryPayload(summary, unavailablePID: unavailablePID, fallbackPID: fallbackPID)

        let programs = snapshot.programSummaryPayload(
            for: [unavailablePID, fallbackPID, agentUnavailablePID, agentFallbackPID]
        )
        XCTAssertEqual(programs.compactMap { $0["name"] as? String }, ["worker"])
        let program = try XCTUnwrap(programs.first)
        let programResources = try XCTUnwrap(program["resources"] as? [String: Any])
        assertUnavailableMemoryPayload(programResources, unavailablePID: unavailablePID, fallbackPID: fallbackPID)

        let codingAgent = try XCTUnwrap(
            snapshot.codingAgentSummaryPayload(for: [agentUnavailablePID, agentFallbackPID])
                .first { $0["id"] as? String == "codex" }
        )
        let codingAgentResources = try XCTUnwrap(codingAgent["resources"] as? [String: Any])
        assertUnavailableMemoryPayload(
            codingAgentResources,
            unavailablePID: agentUnavailablePID,
            fallbackPID: agentFallbackPID
        )
    }

    func testKernProcArgsWorkspaceID() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let bytes = kernProcArgs(environment: [
            "CMUX_WORKSPACE_ID=\(workspaceID.uuidString)"
        ])

        let scope = CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes)

        XCTAssertEqual(scope?.workspaceID, workspaceID)
        XCTAssertNil(scope?.surfaceID)
    }

    func testKernProcArgsTabIDFallback() {
        let tabID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let bytes = kernProcArgs(environment: [
            "CMUX_TAB_ID=\(tabID.uuidString)"
        ])

        let scope = CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes)

        XCTAssertEqual(scope?.workspaceID, tabID)
        XCTAssertNil(scope?.surfaceID)
    }

    func testKernProcArgsSurfaceID() {
        let surfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let bytes = kernProcArgs(environment: [
            "CMUX_SURFACE_ID=\(surfaceID.uuidString)"
        ])

        let scope = CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes)

        XCTAssertNil(scope?.workspaceID)
        XCTAssertEqual(scope?.surfaceID, surfaceID)
    }

    func testKernProcArgsPanelIDFallback() {
        let panelID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let bytes = kernProcArgs(environment: [
            "CMUX_PANEL_ID=\(panelID.uuidString)"
        ])

        let scope = CmuxTopProcessSnapshot.cmuxScope(fromKernProcArgs: bytes)

        XCTAssertNil(scope?.workspaceID)
        XCTAssertEqual(scope?.surfaceID, panelID)
    }

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

    private func makeProcessInfo(
        processGroupID: Int?,
        terminalProcessGroupID: Int?
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: 123,
            parentPID: 1,
            name: "tmux",
            path: "/opt/homebrew/bin/tmux",
            ttyDevice: nil,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
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

    private func kernProcArgs(
        arguments: [String] = ["zsh"],
        environment: [String]
    ) -> [UInt8] {
        var argc = Int32(arguments.count).littleEndian
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        appendCString("/bin/zsh", to: &bytes)
        bytes.append(0)
        for argument in arguments {
            appendCString(argument, to: &bytes)
        }
        bytes.append(0)
        for entry in environment {
            appendCString(entry, to: &bytes)
        }
        bytes.append(0)
        return bytes
    }

    private func appendCString(_ string: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: string.utf8)
        bytes.append(0)
    }

    private struct SpawnedProcessTree {
        let process: Process
        let childPIDs: [Int]
        let directory: URL

        var parentPID: Int {
            Int(process.processIdentifier)
        }

        static func start() throws -> SpawnedProcessTree {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-top-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let scriptURL = directory.appendingPathComponent("process_tree.py")
            let pidURL = directory.appendingPathComponent("children.txt")
            let readyURL = directory.appendingPathComponent("ready.txt")
            let process = Process()

            do {
                try processTreeScript.write(to: scriptURL, atomically: true, encoding: .utf8)
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [scriptURL.path, pidURL.path, readyURL.path]
                try process.run()

                let childPIDs = try waitForReadyChildPIDs(pidURL: pidURL, readyURL: readyURL)
                return SpawnedProcessTree(process: process, childPIDs: childPIDs, directory: directory)
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func terminate() {
            for pid in childPIDs {
                Darwin.kill(pid_t(pid), SIGTERM)
            }
            if process.isRunning {
                process.terminate()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        private static let processTreeScript = #"""
import os
import signal
import sys
import time

pid_file = sys.argv[1]
ready_file = sys.argv[2]
allocations = []

def touch(size):
    data = bytearray(size)
    for index in range(0, len(data), 4096):
        data[index] = 1
    return data

def signal_ready(pid):
    with open(ready_file, "a", encoding="utf-8") as handle:
        handle.write(f"{pid}\n")
        handle.flush()

allocations.append(touch(16 * 1024 * 1024))
children = []
for offset in range(2):
    pid = os.fork()
    if pid == 0:
        child_data = touch((8 + offset) * 1024 * 1024)
        signal_ready(os.getpid())
        while child_data:
            time.sleep(1)
    children.append(pid)

with open(pid_file, "w", encoding="utf-8") as handle:
    handle.write(" ".join(str(pid) for pid in children))
    handle.flush()

def terminate(signum, frame):
    for child in children:
        try:
            os.kill(child, signal.SIGTERM)
        except ProcessLookupError:
            pass
    sys.exit(0)

signal.signal(signal.SIGTERM, terminate)
while allocations:
    time.sleep(1)
"""#

        private static func waitForReadyChildPIDs(pidURL: URL, readyURL: URL) throws -> [Int] {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let raw = try? String(contentsOf: pidURL, encoding: .utf8) {
                    let pids = intValues(in: raw)
                    if pids.count == 2,
                       let readyRaw = try? String(contentsOf: readyURL, encoding: .utf8) {
                        let readyPIDs = Set(intValues(in: readyRaw))
                        if pids.allSatisfy(readyPIDs.contains) {
                            return pids
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw XCTSkip("Timed out waiting for process tree fixture")
        }

        private static func intValues(in raw: String) -> [Int] {
            raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private func psResidentBytesForRecursiveTree(rootPID: Int) throws -> Int64 {
        let output = try runPS(arguments: ["-A", "-o", "pid=,ppid=,rss="])
        var rssByPID: [Int: Int64] = [:]
        var childrenByParent: [Int: [Int]] = [:]

        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3,
                  let pid = Int(columns[0]),
                  let parentPID = Int(columns[1]),
                  let rssKB = Int64(columns[2]) else {
                continue
            }
            rssByPID[pid] = rssKB * 1024
            childrenByParent[parentPID, default: []].append(pid)
        }

        var treePIDs: Set<Int> = []
        var stack = [rootPID]
        while let pid = stack.popLast() {
            guard treePIDs.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }

        return treePIDs.reduce(Int64(0)) { partial, pid in
            partial + (rssByPID[pid] ?? 0)
        }
    }

    private func runPS(arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ps failed with status \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func physicalFootprintBytes(for pid: Int) -> Int64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutableBytes(of: &info) { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            // proc_pid_rusage imports as rusage_info_t *; callers pass the concrete
            // rusage struct address cast to that opaque buffer type.
            let buffer = baseAddress.assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                pid_t(pid),
                RUSAGE_INFO_V2,
                buffer
            )
        }
        guard result == 0 else { return nil }
        return int64Clamped(info.ri_phys_footprint)
    }

    private func sharedWebViewSurface(pid: Int) -> [String: Any] {
        let surfaceID = UUID().uuidString
        return [
            "kind": "surface",
            "id": surfaceID,
            "index": 0,
            "type": "browser",
            "title": "Browser",
            "webviews": [[
                "kind": "webview",
                "id": "\(surfaceID):webview",
                "index": 0,
                "title": "Shared WebView",
                "pid": pid
            ] as [String: Any]]
        ]
    }

    private func annotatedWebViewResources(in windows: [[String: Any]]) throws -> [[String: Any]] {
        let workspaces = try XCTUnwrap(windows[0]["workspaces"] as? [[String: Any]])
        let panes = try XCTUnwrap(workspaces[0]["panes"] as? [[String: Any]])
        let surfaces = try XCTUnwrap(panes[0]["surfaces"] as? [[String: Any]])
        return try surfaces.map { surface in
            let webviews = try XCTUnwrap(surface["webviews"] as? [[String: Any]])
            let webview = try XCTUnwrap(webviews.first)
            return try XCTUnwrap(webview["resources"] as? [String: Any])
        }
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

    private func assertUnavailableMemoryPayload(
        _ payload: [String: Any],
        unavailablePID: Int,
        fallbackPID: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(intArray(payload["memory_source_fallback_pids"]), [fallbackPID], file: file, line: line)
        XCTAssertEqual(int(payload["memory_source_fallback_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["resident_memory_source_fallback_pids"]), [fallbackPID], file: file, line: line)
        XCTAssertEqual(int(payload["resident_memory_source_fallback_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["unavailable_memory_pids"]), [unavailablePID], file: file, line: line)
        XCTAssertEqual(int(payload["unavailable_memory_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["unavailable_resident_memory_pids"]), [unavailablePID], file: file, line: line)
        XCTAssertEqual(int(payload["unavailable_resident_memory_count"]), 1, file: file, line: line)
    }

    private func int64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        return 0
    }

    private func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private func int64Clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private func intArray(_ raw: Any?) -> [Int] {
        if let values = raw as? [Int] { return values }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { raw in
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String { return Int(value) }
            return nil
        }
    }
}
