import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MobileInteractionSessionEpochXCTests: XCTestCase {
    func testRestartedClientSessionAcceptsEpochOneWhileRejectingStaleOldSessionWork() {
        let controller = TerminalController.shared
        let surfaceID = UUID()
        defer { controller.mobileInteractionEpochsBySurfaceID[surfaceID] = nil }

        func params(epoch: Int, sessionID: String) -> [String: Any] {
            [
                "client_id": "persisted-client",
                "interaction_session_id": sessionID,
                "interaction_epoch": epoch,
            ]
        }

        XCTAssertTrue(controller.recordMobileInteractionEpoch(
            params: params(epoch: 9, sessionID: "old-session"),
            surfaceID: surfaceID,
            rejectOlder: true
        ))
        XCTAssertTrue(controller.recordMobileInteractionEpoch(
            params: params(epoch: 1, sessionID: "new-session"),
            surfaceID: surfaceID,
            rejectOlder: true
        ))
        XCTAssertFalse(controller.recordMobileInteractionEpoch(
            params: params(epoch: 8, sessionID: "old-session"),
            surfaceID: surfaceID,
            rejectOlder: true
        ))
    }

    func testOverlappingConnectionsRetireOnlyTheirOwnedSession() {
        let service = MobileHostService.shared
        let controller = TerminalController.shared
        let oldConnection = UUID()
        let newConnection = UUID()
        let surfaceID = UUID()
        defer {
            service.debugResetMobileLifecycleStateForTesting()
            controller.debugResetMobileViewportReportsForTesting()
        }

        service.debugResetMobileLifecycleStateForTesting()
        controller.debugResetMobileViewportReportsForTesting()
        controller.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "persisted-client",
            columns: 72,
            rows: 28
        )
        controller.mobileInteractionEpochsBySurfaceID[surfaceID] = [
            "persisted-client": ["old-session": 9, "new-session": 1]
        ]
        service.debugRecordInteractionIdentityForTesting(
            clientID: "persisted-client",
            sessionID: "old-session",
            connectionID: oldConnection
        )
        service.debugRecordInteractionIdentityForTesting(
            clientID: "persisted-client",
            sessionID: "new-session",
            connectionID: newConnection
        )

        service.debugRemoveConnectionForTesting(id: oldConnection)

        XCTAssertEqual(controller.mobileInteractionEpochsBySurfaceID[surfaceID], [
            "persisted-client": ["new-session": 1]
        ])
        XCTAssertEqual(
            controller.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID),
            ["persisted-client"]
        )

        service.debugRemoveConnectionForTesting(id: newConnection)

        XCTAssertNil(controller.mobileInteractionEpochsBySurfaceID[surfaceID])
        XCTAssertNil(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID))
    }
}
