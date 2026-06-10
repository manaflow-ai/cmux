import XCTest
import Foundation
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Window process rollup and attachment
extension CmuxTopSnapshotScopeTests {
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

}
