import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Restore must keep the permission mode a Claude session actually ended in:
/// explicit launch flags are preserved through the sanitizer, and a mode selected
/// in-session (shift+tab auto-accept, plan mode) is persisted from hook
/// observation and re-applied as `--permission-mode` on user-owned resume/fork.
/// https://github.com/manaflow-ai/cmux/issues/8066
final class SessionRestorableAgentSnapshotPermissionModeTests: XCTestCase {
    private func claudeSnapshot(
        arguments: [String] = ["claude"],
        permissionMode: String?
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "24ec0052-450c-4914-b1dd-2ee80d4bc84b",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: arguments,
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "environment"
            ),
            permissionMode: permissionMode
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testResumeCommandAppendsObservedPermissionMode() throws {
        let command = try XCTUnwrap(
            claudeSnapshot(permissionMode: "acceptEdits").resumeCommand
        )
        XCTAssertTrue(command.contains("--permission-mode"), command)
        XCTAssertTrue(command.contains("acceptEdits"), command)
    }

    func testForkCommandAppendsObservedPermissionMode() throws {
        let command = try XCTUnwrap(
            claudeSnapshot(permissionMode: "plan").forkCommand
        )
        XCTAssertTrue(command.contains("--fork-session"), command)
        XCTAssertTrue(command.contains("--permission-mode"), command)
        XCTAssertTrue(command.contains("plan"), command)
    }

    func testExplicitPermissionModeLaunchFlagWinsOverObservedMode() throws {
        let command = try XCTUnwrap(
            claudeSnapshot(
                arguments: ["claude", "--permission-mode", "plan"],
                permissionMode: "acceptEdits"
            ).resumeCommand
        )
        XCTAssertEqual(occurrences(of: "--permission-mode", in: command), 1, command)
        XCTAssertTrue(command.contains("plan"), command)
        XCTAssertFalse(command.contains("acceptEdits"), command)
    }

    func testExplicitBypassLaunchFlagSuppressesObservedMode() throws {
        let command = try XCTUnwrap(
            claudeSnapshot(
                arguments: ["claude", "--dangerously-skip-permissions"],
                permissionMode: "plan"
            ).resumeCommand
        )
        XCTAssertTrue(command.contains("--dangerously-skip-permissions"), command)
        XCTAssertFalse(command.contains("--permission-mode"), command)
    }

    func testDefaultObservedModeIsNotEmitted() throws {
        let command = try XCTUnwrap(
            claudeSnapshot(permissionMode: "default").resumeCommand
        )
        XCTAssertFalse(command.contains("--permission-mode"), command)
    }

    func testDecodingToleratesSnapshotsWithoutPermissionMode() throws {
        let legacyJSON = """
        {
            "kind": "claude",
            "sessionId": "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        }
        """
        let snapshot = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(snapshot.permissionMode)
        let command = try XCTUnwrap(snapshot.resumeCommand)
        XCTAssertFalse(command.contains("--permission-mode"), command)
    }

    func testSnapshotRoundTripsPermissionMode() throws {
        let encoded = try JSONEncoder().encode(claudeSnapshot(permissionMode: "acceptEdits"))
        let decoded = try JSONDecoder().decode(SessionRestorableAgentSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.permissionMode, "acceptEdits")
    }
}
