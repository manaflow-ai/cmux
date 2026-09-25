import Combine
import Observation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Observable private final class ObservedValueTrackingTestModel {
    var value = 0
}

@MainActor
final class ObservedValueTrackingTests: XCTestCase {
    func testSubscriberChurnDoesNotRearmAnIdleSource() {
        let model = ObservedValueTrackingTestModel()
        var readCount = 0
        let tracking = ObservedValueTracking {
            readCount += 1
            return model.value
        }

        let first = tracking.publisher.sink { _ in }
        let countAfterFirstSubscription = readCount
        first.cancel()

        let second = tracking.publisher.sink { _ in }
        XCTAssertEqual(
            readCount,
            countAfterFirstSubscription,
            "Re-subscribing while the model is idle must reuse its one tracking loop"
        )
        second.cancel()
    }

    func testTrackingPublishesChangesToEverySubscriber() async {
        let model = ObservedValueTrackingTestModel()
        let tracking = ObservedValueTracking { model.value }
        var received: [[Int]] = [[], []]
        let first = tracking.publisher.sink { received[0].append($0) }
        let second = tracking.publisher.sink { received[1].append($0) }
        defer {
            first.cancel()
            second.cancel()
            tracking.cancel()
        }

        model.value = 1
        while received.contains(where: { $0.last != 1 }) {
            await Task.yield()
        }

        XCTAssertEqual(received, [[0, 1], [0, 1]])
    }
}
