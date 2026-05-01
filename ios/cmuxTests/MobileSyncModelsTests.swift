import XCTest
@testable import cmux_DEV

final class MobileSyncModelsTests: XCTestCase {
    func testMobileMachineRowsEnableSSHFallback() {
        let row = MobileMachineRow(
            teamId: "team-1",
            userId: "user-1",
            machineId: "machine-macmini",
            displayName: "Mac mini",
            tailscaleHostname: "cmux-macmini.tail.ts.net",
            tailscaleIPs: ["100.64.0.10"],
            status: .online,
            lastSeenAt: 1_773_740_000,
            lastWorkspaceSyncAt: 1_773_740_000,
            wsPort: nil,
            wsSecret: nil
        )

        let host = row.asTerminalHost()

        XCTAssertEqual(host.transportPreference, .remoteDaemon)
        XCTAssertEqual(host.serverID, "cmux-macmini.tail.ts.net")
        XCTAssertTrue(host.allowsSSHFallback)
    }
}
