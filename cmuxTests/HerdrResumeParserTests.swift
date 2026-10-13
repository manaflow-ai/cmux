import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class HerdrResumeParserTests: XCTestCase {
    private func binding(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) -> SurfaceResumeBindingSnapshot? {
        HerdrResumeParser.binding(
            arguments: arguments,
            environment: environment,
            capturedAt: 1_777_777_777
        )
    }

    func testNamedSessionAttachProducesAutomaticProcessDetectedBinding() throws {
        let binding = try XCTUnwrap(
            binding(["herdr", "--session", "manu"], environment: ["PWD": "/tmp/project"])
        )

        XCTAssertEqual(binding.kind, "herdr")
        XCTAssertEqual(binding.name, "herdr manu")
        XCTAssertEqual(binding.source, "process-detected")
        XCTAssertEqual(binding.allowsAutomaticResume, true)
        XCTAssertEqual(binding.checkpointId, "manu")
        XCTAssertEqual(binding.cwd, "/tmp/project")
        XCTAssertEqual(binding.command, "'herdr' '--session' 'manu'")
    }

    func testDefaultSessionAttachKeepsTheObservedExecutable() throws {
        let binding = try XCTUnwrap(binding(["/Users/test/.local/bin/herdr"]))

        XCTAssertEqual(binding.name, "herdr")
        XCTAssertNil(binding.checkpointId)
        XCTAssertEqual(binding.command, "'/Users/test/.local/bin/herdr'")
    }

    func testSessionAttachSubcommandAndInlineOptionResumeAsSessionAttach() throws {
        let subcommand = try XCTUnwrap(binding(["herdr", "session", "attach", "lsd"]))
        XCTAssertEqual(subcommand.checkpointId, "lsd")
        XCTAssertEqual(subcommand.command, "'herdr' '--session' 'lsd'")

        let inline = try XCTUnwrap(binding(["herdr", "--session=kunden"]))
        XCTAssertEqual(inline.checkpointId, "kunden")
        XCTAssertEqual(inline.command, "'herdr' '--session' 'kunden'")
    }

    func testSessionNameIsShellQuoted() throws {
        let binding = try XCTUnwrap(binding(["herdr", "--session", "it's"]))

        XCTAssertEqual(binding.command, "'herdr' '--session' 'it'\\''s'")
    }

    func testServerSubcommandsRemoteAttachAndUnknownOptionsAreRejected() {
        let rejected: [[String]] = [
            ["/Users/test/.local/bin/herdr", "server"],
            ["herdr", "server", "stop"],
            ["herdr", "pane", "list"],
            ["herdr", "agent", "list"],
            ["herdr", "workspace", "list"],
            ["herdr", "api", "snapshot"],
            ["herdr", "plugin", "action", "invoke", "state-start"],
            ["herdr", "session", "list"],
            ["herdr", "update"],
            ["herdr", "--help"],
            ["herdr", "--remote", "workbox"],
            ["herdr", "--remote", "workbox", "--session", "manu"],
            ["herdr", "--machine", "workbox", "pane", "list"],
            ["herdr", "--session", "manu", "pane", "list"],
            ["herdr", "--session"],
            ["herdr", "--session", "--remote"],
            ["herdr", "--session="],
        ]
        for arguments in rejected {
            XCTAssertNil(binding(arguments), "Expected herdr invocation to be rejected: \(arguments)")
        }
    }

    func testClientNestedInsideAHerdrPaneIsRejected() {
        XCTAssertNil(binding(["herdr", "--session", "manu"], environment: ["HERDR_ENV": "1"]))
    }

    func testMissingOrForeignArgumentsAreRejected() {
        XCTAssertNil(binding([]))
        XCTAssertNil(binding(["/usr/bin/vim", "--session", "manu"]))
        XCTAssertNil(binding(["herdr-radar", "--session", "manu"]))
    }

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
