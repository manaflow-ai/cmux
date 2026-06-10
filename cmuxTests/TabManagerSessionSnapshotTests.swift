import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabManagerSessionSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClosedItemHistoryStore.shared.removeAll()
    }

    override func tearDown() {
        ClosedItemHistoryStore.shared.removeAll()
        super.tearDown()
    }

    func reserveRemoteRestoreSocket() -> String {
        TerminalController.shared.stop()
        let requestedPath = "/tmp/cmux-restore-\(UUID().uuidString).sock"
        let reservedPath = TerminalController.shared.reserveStartupSocketPath(requestedPath)
        XCTAssertEqual(TerminalController.shared.currentSocketPathForRemoteRestore(), reservedPath)
        return reservedPath
    }

    func cleanupRemoteRestoreSocket(_ path: String) {
        TerminalController.shared.stop()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".lock")
    }

}
