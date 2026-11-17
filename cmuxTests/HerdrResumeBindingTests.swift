import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class HerdrResumeBindingTests: XCTestCase {
    private func binding(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) -> SurfaceResumeBindingSnapshot? {
        ProcessDetectedTerminalBinding.binding(
            processName: (arguments.first as NSString?)?.lastPathComponent ?? "",
            processPath: nil,
            processArguments: CmuxTopProcessArguments(arguments: arguments, environment: environment),
            capturedAt: 1_777_777_777
        )
    }

    /// A herdr attach becomes an automatic, process-detected binding that
    /// re-runs the normalized attach in the directory it ran in.
    func testNamedSessionAttachProducesAutomaticProcessDetectedBinding() throws {
        let binding = try XCTUnwrap(
            binding(["herdr", "session", "attach", "manu"], environment: ["PWD": "/tmp/project"])
        )

        XCTAssertEqual(binding.kind, "herdr")
        XCTAssertEqual(binding.name, "herdr manu")
        XCTAssertEqual(binding.source, "process-detected")
        XCTAssertEqual(binding.allowsAutomaticResume, true)
        XCTAssertEqual(binding.checkpointId, "manu")
        XCTAssertEqual(binding.cwd, "/tmp/project")
        XCTAssertEqual(binding.command, "'herdr' '--session' 'manu'")
        XCTAssertEqual(binding.launchCommand?.executablePath, "herdr")
        XCTAssertEqual(binding.launchCommand?.arguments, ["herdr", "--session", "manu"])
        XCTAssertEqual(binding.launchCommand?.workingDirectory, "/tmp/project")
    }

    /// The default session keeps the executable path and has no checkpoint.
    func testDefaultSessionAttachBindsWithoutCheckpoint() throws {
        let binding = try XCTUnwrap(binding(["/Users/test/.local/bin/herdr"]))

        XCTAssertEqual(binding.name, "herdr")
        XCTAssertNil(binding.checkpointId)
        XCTAssertEqual(binding.command, "'/Users/test/.local/bin/herdr'")
    }

    /// An ssh or tmux client inside a herdr pane carries a borrowed cmux
    /// scope, so the chain yields no binding for it at all.
    func testClientsInsideAHerdrPaneYieldNoBinding() {
        let insidePane = ["HERDR_ENV": "1"]
        XCTAssertNil(binding(["/usr/bin/ssh", "tinybox"], environment: insidePane))
        XCTAssertNil(binding(["tmux", "attach", "-t", "work"], environment: insidePane))
        XCTAssertNil(binding(["herdr", "--session", "manu"], environment: insidePane))
    }

    /// The surface's own herdr client wins over a newer process inside one
    /// of its panes that shares the same panel key.
    func testProcessScanPrefersTheSurfaceClientOverAProcessInsideAHerdrPane() throws {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        // The herdr client runs on the surface's TTY. The ssh runs later inside
        // a herdr pane and inherited the same CMUX_* scope from the server, so
        // it has the newer PID and the same panel key.
        let client = foregroundProcess(pid: 4100, name: "herdr", ttyDevice: 9876, workspaceID: workspaceID, panelID: panelID)
        let nested = foregroundProcess(pid: 4200, name: "ssh", ttyDevice: 5432, workspaceID: workspaceID, panelID: panelID)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [client, nested],
            sampledAt: Date(timeIntervalSince1970: 1_777_777_777),
            includesProcessDetails: true
        )
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspaceID, panelId: panelID)

        let detected = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: .default,
            processSnapshot: snapshot,
            capturedAt: 1_777_777_777,
            processArgumentsProvider: { pid in
                pid == 4100
                    ? CmuxTopProcessArguments(arguments: ["herdr", "--session", "manu"], environment: [:])
                    : CmuxTopProcessArguments(arguments: ["/usr/bin/ssh", "tinybox"], environment: ["HERDR_ENV": "1"])
            }
        )

        let binding = try XCTUnwrap(detected[key]?.binding)
        XCTAssertEqual(binding.kind, "herdr")
        XCTAssertEqual(binding.command, "'herdr' '--session' 'manu'")
    }

    private func foregroundProcess(
        pid: Int,
        name: String,
        ttyDevice: Int64,
        workspaceID: UUID,
        panelID: UUID
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: name,
            path: nil,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: panelID,
            cmuxAttributionReason: nil,
            processGroupID: pid,
            terminalProcessGroupID: pid,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }
}
