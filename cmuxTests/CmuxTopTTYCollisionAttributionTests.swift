import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A process that is no longer a descendant of cmux (reparented to PID 1) keeps the
/// controlling TTY of the terminal it was launched from. Surface attribution must not
/// promote that process to a surface root just because it shares the TTY device, or a
/// detached REPL/dev server shows up as cmux memory.
///
/// https://github.com/manaflow-ai/cmux/issues/11004
@Suite(.serialized)
struct CmuxTopTTYCollisionAttributionTests {
    private let workspaceID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let surfaceID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!

    private let appPID = 3000
    private let foreignParentPID = 9000
    private let shellPID = 4001
    private let shellChildPID = 4002
    private let detachedPID = 4003
    private let hookMonitorPID = 4004
    private let backgroundJobPID = 4005
    private let strayPID = 4006

    private let shellBytes: Int64 = 64 * 1024 * 1024
    private let shellChildBytes: Int64 = 32 * 1024 * 1024
    private let detachedBytes: Int64 = 1_900 * 1024 * 1024
    private let hookMonitorBytes: Int64 = 16 * 1024 * 1024
    private let backgroundJobBytes: Int64 = 8 * 1024 * 1024
    private let strayBytes: Int64 = 512 * 1024 * 1024

    @MainActor
    @Test func detachedSameTTYProcessIsNotCountedAsSurfaceMemory() throws {
        let surface = try #require(firstAnnotatedSurface())
        let resources = try #require(surface["resources"] as? [String: Any])

        let attributedPIDs = intArray(resources["pids"])
        #expect(!attributedPIDs.contains(detachedPID))
        #expect(attributedPIDs == [shellPID, shellChildPID, hookMonitorPID, backgroundJobPID].sorted())

        let expectedBytes = shellBytes + shellChildBytes + hookMonitorBytes + backgroundJobBytes
        #expect(int64(resources["resident_bytes"]) == expectedBytes)
    }

    @MainActor
    @Test func collisionsAreReportedAsUnattributed() throws {
        let surface = try #require(firstAnnotatedSurface())

        #expect(intArray(surface["unattributed_tty_process_pids"]) == [detachedPID, strayPID].sorted())

        let unattributed = try #require(surface["unattributed_resources"] as? [String: Any])
        #expect(int64(unattributed["resident_bytes"]) == detachedBytes + strayBytes)
    }

    /// An off-TTY parent is only launch evidence when that parent is cmux's. Attribution
    /// fails closed for a same-TTY process parented by an unrelated live process.
    @MainActor
    @Test func sameTTYProcessWithForeignOffTTYParentIsACollision() throws {
        let surface = try #require(firstAnnotatedSurface())

        #expect(!intArray(surface["tty_process_pids"]).contains(strayPID))
        #expect(intArray(surface["unattributed_tty_process_pids"]).contains(strayPID))
    }

    @MainActor
    @Test func provenTTYOwnersCarryTheirAttributionReason() throws {
        let surface = try #require(firstAnnotatedSurface())
        let reasons = try #require(surface["tty_ownership_reasons"] as? [String: String])

        #expect(reasons[String(shellPID)] == "tty-session-root")
        #expect(reasons[String(shellChildPID)] == "tty-descendant")
        #expect(reasons[String(hookMonitorPID)] == "cmux-process-scope")
        #expect(reasons[String(backgroundJobPID)] == "tty-process-group")
        #expect(reasons[String(detachedPID)] == "tty-collision")
        #expect(reasons[String(strayPID)] == "tty-collision")
    }

    /// A reparented helper that still names this surface through `CMUX_*` scope stays
    /// attributed; explicit scope outranks the PPID-1 exclusion.
    @MainActor
    @Test func reparentedScopedHelperStaysAttributed() throws {
        let surface = try #require(firstAnnotatedSurface())

        #expect(intArray(surface["tty_process_pids"]).contains(hookMonitorPID))
        #expect(!intArray(surface["unattributed_tty_process_pids"]).contains(hookMonitorPID))
    }

    // MARK: - Fixture

    /// A real device so `deviceIdentifier(forTTYName:)` can `stat` it.
    private var ttyName: String { "/dev/null" }

    /// The device identifier the snapshot indexes TTY membership by.
    private var ttyDevice: Int64? {
        CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: ttyName)
    }

    /// Six processes on one surface TTY, covering every ownership reason.
    private func snapshot() -> CmuxTopProcessSnapshot {
        let device = ttyDevice
        return CmuxTopProcessSnapshot(
            processes: [
                // The cmux app process that forked the surface's shell. Off the TTY.
                process(
                    pid: appPID,
                    parentPID: 1,
                    name: "cmux",
                    ttyDevice: nil,
                    processGroupID: appPID,
                    terminalProcessGroupID: nil,
                    residentBytes: 128 * 1024 * 1024
                ),
                // An unrelated live process that also has a child on this TTY.
                process(
                    pid: foreignParentPID,
                    parentPID: 1,
                    name: "orbstack",
                    ttyDevice: nil,
                    processGroupID: foreignParentPID,
                    terminalProcessGroupID: nil,
                    residentBytes: 64 * 1024 * 1024
                ),
                // The shell cmux forked for this surface.
                process(
                    pid: shellPID,
                    parentPID: appPID,
                    name: "zsh",
                    ttyDevice: device,
                    processGroupID: shellPID,
                    terminalProcessGroupID: shellPID,
                    residentBytes: shellBytes
                ),
                process(
                    pid: shellChildPID,
                    parentPID: shellPID,
                    name: "node",
                    ttyDevice: device,
                    processGroupID: shellChildPID,
                    terminalProcessGroupID: shellPID,
                    residentBytes: shellChildBytes
                ),
                // Detached REPL/dev server: reparented to launchd, no cmux scope, its own
                // process group. Only the TTY device links it to the surface.
                process(
                    pid: detachedPID,
                    parentPID: 1,
                    name: "python3",
                    ttyDevice: device,
                    processGroupID: detachedPID,
                    terminalProcessGroupID: shellPID,
                    residentBytes: detachedBytes
                ),
                // Intentionally reparented cmux hook monitor, positively scoped.
                process(
                    pid: hookMonitorPID,
                    parentPID: 1,
                    name: "cmux",
                    ttyDevice: device,
                    cmuxWorkspaceID: workspaceID,
                    cmuxSurfaceID: surfaceID,
                    cmuxAttributionReason: "cmux-hook-arguments",
                    processGroupID: hookMonitorPID,
                    terminalProcessGroupID: shellPID,
                    residentBytes: hookMonitorBytes
                ),
                // Background job whose process-group leader is the proven shell.
                process(
                    pid: backgroundJobPID,
                    parentPID: 1,
                    name: "rg",
                    ttyDevice: device,
                    processGroupID: shellPID,
                    terminalProcessGroupID: shellPID,
                    residentBytes: backgroundJobBytes
                ),
                // Live off-TTY parent, but the parent is not cmux's: no launch evidence.
                process(
                    pid: strayPID,
                    parentPID: foreignParentPID,
                    name: "dockerd",
                    ttyDevice: device,
                    processGroupID: strayPID,
                    terminalProcessGroupID: shellPID,
                    residentBytes: strayBytes
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
    }

    /// Runs the real annotation path and returns the fixture's only surface.
    @MainActor
    private func firstAnnotatedSurface() -> [String: Any]? {
        var windows: [[String: Any]] = [[
            "kind": "window",
            "id": UUID().uuidString,
            "index": 0,
            "key": true,
            "visible": true,
            "app_process_pids": [appPID],
            "workspaces": [[
                "kind": "workspace",
                "id": workspaceID.uuidString,
                "index": 0,
                "title": "tty collision fixture",
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
                        "title": "detached repl owner",
                        "tty": ttyName,
                        "webviews": []
                    ] as [String: Any]]
                ] as [String: Any]]
            ] as [String: Any]]
        ]]

        _ = TerminalController.shared.v2AnnotateTopWindows(
            &windows,
            processSnapshot: snapshot(),
            browserPIDOccurrences: [:],
            includeProcesses: true
        )

        guard let workspaces = windows.first?["workspaces"] as? [[String: Any]],
              let panes = workspaces.first?["panes"] as? [[String: Any]],
              let surfaces = panes.first?["surfaces"] as? [[String: Any]] else {
            return nil
        }
        return surfaces.first
    }

    /// Builds one snapshot process with only the fields this suite varies.
    private func process(
        pid: Int,
        parentPID: Int,
        name: String,
        ttyDevice: Int64?,
        cmuxWorkspaceID: UUID? = nil,
        cmuxSurfaceID: UUID? = nil,
        cmuxAttributionReason: String? = nil,
        processGroupID: Int?,
        terminalProcessGroupID: Int?,
        residentBytes: Int64
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: "/usr/bin/\(name)",
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: cmuxWorkspaceID,
            cmuxSurfaceID: cmuxSurfaceID,
            cmuxAttributionReason: cmuxAttributionReason,
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            residentBytes: residentBytes,
            virtualBytes: residentBytes,
            threadCount: 1
        )
    }

    /// Reads a sorted PID array out of a JSON payload field.
    private func intArray(_ raw: Any?) -> [Int] {
        (raw as? [Int])?.sorted() ?? []
    }

    /// Reads a byte count out of a JSON payload field, whatever numeric box it arrives in.
    private func int64(_ raw: Any?) -> Int64? {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        return nil
    }
}
