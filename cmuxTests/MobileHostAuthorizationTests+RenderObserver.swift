import CMUXMobileCore
import Foundation
@preconcurrency import Network
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Terminal render observer demand
extension MobileHostAuthorizationTests {
    func testTerminalRenderObserverRetainsGhosttyDemandOnlyWithTerminalSubscriber() async throws {
        let service = MobileHostService.shared
        service.debugResetMobileLifecycleStateForTesting()
        let observer = MobileTerminalRenderObserver.shared
        observer.stop()
        observer.start()
        defer {
            observer.stop()
            service.debugResetMobileLifecycleStateForTesting()
        }

        drainMobileHostMainQueue()
        XCTAssertFalse(MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        XCTAssertFalse(observer.debugIsRetainingNotificationDemandForTesting)

        let session = MobileHostConnection(
            id: UUID(),
            connection: NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 9)!,
                using: .tcp
            ),
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )

        await session.subscribe(streamID: "events", topics: ["terminal.updated"])
        drainMobileHostMainQueue()

        XCTAssertTrue(MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        XCTAssertTrue(observer.debugIsRetainingNotificationDemandForTesting)

        _ = await session.unsubscribe(streamID: "events")
        drainMobileHostMainQueue()

        XCTAssertFalse(MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        XCTAssertFalse(observer.debugIsRetainingNotificationDemandForTesting)
    }

    private func drainMobileHostMainQueue() {
        let expectation = XCTestExpectation(description: "drain mobile host main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        XCTWaiter().wait(for: [expectation], timeout: 1)
    }
}
