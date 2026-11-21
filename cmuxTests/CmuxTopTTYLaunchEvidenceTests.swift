import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A surface's TTY processes are the same whichever read asks for them. The launch
/// evidence for TTY ownership is the app process, not the window a read happens to
/// charge the app process to.
///
/// https://github.com/manaflow-ai/cmux/issues/29417
@Suite(.serialized)
struct CmuxTopTTYLaunchEvidenceTests {
    private let workspaceID = UUID()
    private let surfaceID = UUID()

    /// `cmux top --workspace <ref> --processes`
    @MainActor
    @Test func workspaceReadAttributesProcessesWithoutSurfaceScope() async throws {
        let tree = try await PTYProcessTree.start()
        defer { tree.stop() }
        var windows = [window(key: true, ttyName: tree.ttyName)]

        TerminalController.shared.v2AttachTopApplicationProcess(to: &windows, workspaceFilter: workspaceID)
        let surface = try annotatedSurface(of: &windows, windowIndex: 0, snapshot: tree.snapshot)

        #expect(intArray(surface["tty_process_pids"]) == [tree.processOnTTY])
        #expect(intArray(surface["unattributed_tty_process_pids"]) == [])
        let resources = try #require(surface["resources"] as? [String: Any])
        #expect(intArray(resources["pids"]) == [tree.processOnTTY])
        #expect(processRowPIDs(surface["processes"]) == [tree.processOnTTY])

        // The app process stays out of a one-workspace total.
        #expect(intArray(windows[0]["app_process_pids"]) == [])
        let windowResources = try #require(windows[0]["resources"] as? [String: Any])
        #expect(!intArray(windowResources["pids"]).contains(Int(Darwin.getpid())))
    }

    /// `cmux top --all --processes` with the surface in a window that isn't key.
    @MainActor
    @Test func allWindowsReadAttributesProcessesInNonKeyWindow() async throws {
        let tree = try await PTYProcessTree.start()
        defer { tree.stop() }
        var windows = [window(key: true, ttyName: nil), window(key: false, ttyName: tree.ttyName)]

        TerminalController.shared.v2AttachTopApplicationProcess(to: &windows)
        let surface = try annotatedSurface(of: &windows, windowIndex: 1, snapshot: tree.snapshot)

        #expect(intArray(surface["tty_process_pids"]) == [tree.processOnTTY])
        #expect(intArray(surface["unattributed_tty_process_pids"]) == [])
        let resources = try #require(surface["resources"] as? [String: Any])
        #expect(intArray(resources["pids"]) == [tree.processOnTTY])
        #expect(processRowPIDs(surface["processes"]) == [tree.processOnTTY])
        #expect(intArray(windows[1]["app_process_pids"]) == [])
        let windowResources = try #require(windows[1]["resources"] as? [String: Any])
        #expect(intArray(windowResources["pids"]) == [tree.processOnTTY])
    }

    /// The wider evidence must not pull in what #11004 keeps out: only the TTY links
    /// a process reparented to launchd to the surface.
    @MainActor
    @Test func workspaceReadStillLeavesDetachedProcessUnattributed() throws {
        let device = try #require(CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: "/dev/null"))
        let appPID = Int(Darwin.getpid())
        let shellPID = appPID + 100_000
        let detachedPID = appPID + 100_001
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: appPID, parentPID: 1, ttyDevice: nil),
                process(pid: shellPID, parentPID: appPID, ttyDevice: device),
                process(pid: detachedPID, parentPID: 1, ttyDevice: device)
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        var windows = [window(key: true, ttyName: "/dev/null")]

        TerminalController.shared.v2AttachTopApplicationProcess(to: &windows, workspaceFilter: workspaceID)
        let surface = try annotatedSurface(of: &windows, windowIndex: 0, snapshot: snapshot)

        #expect(intArray(surface["tty_process_pids"]) == [shellPID])
        #expect(intArray(surface["unattributed_tty_process_pids"]) == [detachedPID])
    }

    // MARK: - Fixture

    private func window(key: Bool, ttyName: String?) -> [String: Any] {
        var surface: [String: Any] = [
            "kind": "surface",
            "id": ttyName == nil ? UUID().uuidString : surfaceID.uuidString,
            "index": 0,
            "type": "terminal",
            "webviews": []
        ]
        if let ttyName { surface["tty"] = ttyName }
        return [
            "kind": "window",
            "id": UUID().uuidString,
            "key": key,
            "workspaces": [[
                "kind": "workspace",
                "id": workspaceID.uuidString,
                "tags": [],
                "panes": [["kind": "pane", "id": UUID().uuidString, "surfaces": [surface]] as [String: Any]]
            ] as [String: Any]]
        ]
    }

    @MainActor
    private func annotatedSurface(
        of windows: inout [[String: Any]],
        windowIndex: Int,
        snapshot: CmuxTopProcessSnapshot
    ) throws -> [String: Any] {
        _ = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot,
            browserPIDOccurrences: [:],
            includeProcesses: true
        )
        let workspaces = try #require(windows[windowIndex]["workspaces"] as? [[String: Any]])
        let panes = try #require(workspaces.first?["panes"] as? [[String: Any]])
        let surfaces = try #require(panes.first?["surfaces"] as? [[String: Any]])
        return try #require(surfaces.first)
    }

    private func process(pid: Int, parentPID: Int, ttyDevice: Int64?) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: "fixture",
            path: nil,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: pid,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 1024,
            virtualBytes: 1024,
            threadCount: 1
        )
    }

    private func intArray(_ raw: Any?) -> [Int] {
        (raw as? [Int])?.sorted() ?? []
    }

    /// Every `pid` in a process tree payload, nested rows included.
    private func processRowPIDs(_ raw: Any?) -> [Int] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.flatMap { row in
            [row["pid"] as? Int].compactMap { $0 } + processRowPIDs(row["children"])
        }.sorted()
    }
}

/// `script` launched by the app host, running `sleep` on a pty of its own. It is the
/// real shape of a surface: an app child off the TTY, and a process on it that no
/// `CMUX_*` scope names for the surface under test.
private struct PTYProcessTree {
    let launcher: Process
    let stdinKeepAlive: Pipe
    let processOnTTY: Int
    let ttyName: String
    let snapshot: CmuxTopProcessSnapshot

    static func start() async throws -> PTYProcessTree {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        launcher.arguments = ["-q", "/dev/null", "/bin/sleep", "120"]
        let stdinKeepAlive = Pipe()
        launcher.standardInput = stdinKeepAlive
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()

        for _ in 0..<200 {
            let snapshot = await CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
            let onTTY = snapshot.processesByPID.values.first { process in
                process.parentPID == Int(launcher.processIdentifier) && process.ttyDevice != nil
            }
            if let onTTY, let device = onTTY.ttyDevice, let name = devname(dev_t(device), S_IFCHR) {
                return PTYProcessTree(
                    launcher: launcher,
                    stdinKeepAlive: stdinKeepAlive,
                    processOnTTY: onTTY.pid,
                    ttyName: "/dev/" + String(cString: name),
                    snapshot: snapshot
                )
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        launcher.terminate()
        throw PTYProcessTreeError.neverReachedTTY
    }

    func stop() {
        kill(pid_t(processOnTTY), SIGKILL)
        launcher.terminate()
    }
}

private enum PTYProcessTreeError: Error {
    case neverReachedTTY
}
