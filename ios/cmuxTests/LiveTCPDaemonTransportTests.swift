import Foundation
import Network
import XCTest
@testable import cmux_DEV

final class LiveTCPDaemonTransportTests: XCTestCase {
    func testTransportDeallocatesWhenConnectionRetainsCallbacks() async {
        let connection = FakeLiveTCPDaemonConnection()
        weak var weakTransport: LiveTCPDaemonTransport?

        do {
            let transport = LiveTCPDaemonTransport(
                connection: connection,
                queue: DispatchQueue(label: "LiveTCPDaemonTransportTests.queue")
            )
            weakTransport = transport
        }

        XCTAssertEqual(connection.startCallCount, 1)
        await waitForRelease(of: weakTransport)

        XCTAssertNil(weakTransport)
        XCTAssertNil(connection.stateUpdateHandler)
        XCTAssertEqual(connection.cancelCallCount, 1)
    }

    private func waitForRelease(
        of object: @autoclosure () -> AnyObject?,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while object() != nil && ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class FakeLiveTCPDaemonConnection: LiveTCPDaemonConnection {
    var stateUpdateHandler: ((NWConnection.State) -> Void)?

    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0

    func start(queue: DispatchQueue) {
        startCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }

    func send(content: Data?, completion: @escaping (NWError?) -> Void) {
        completion(nil)
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, NWError?) -> Void
    ) {
    }
}
