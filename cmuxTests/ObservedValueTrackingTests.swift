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

private final class RetainProbe {}

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

    func testCancelReleasesReadCaptureWhileSourceIsIdle() {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var tracking: ObservedValueTracking<Int>?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            tracking = ObservedValueTracking {
                _ = probe
                return model.value
            }
        }
        XCTAssertNotNil(weakProbe)

        tracking?.cancel()
        tracking = nil
        XCTAssertNil(
            weakProbe,
            "Cancelling an idle source must release its read capture without a model mutation"
        )
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

        let changed = expectation(description: "both subscribers receive the changed value")
        changed.expectedFulfillmentCount = 1
        let observing = tracking.publisher.sink { value in
            if value == 1 { changed.fulfill() }
        }
        defer { observing.cancel() }
        model.value = 1
        await fulfillment(of: [changed], timeout: 1)

        XCTAssertEqual(received, [[0, 1], [0, 1]])
    }

    func testObserverDoesNotRearmTheSameSource() async {
        let model = ObservedValueTrackingTestModel()
        let observer = ObservedValueObserver<Int>()
        var readCount = 0
        var changes = 0
        let read = {
            readCount += 1
            return model.value
        }
        observer.observe(source: model, initial: false, read: read) { _ in changes += 1 }
        let countAfterFirstArm = readCount
        observer.observe(source: model, initial: false, read: read) { _ in changes += 1 }
        XCTAssertEqual(readCount, countAfterFirstArm)

        let changed = expectation(description: "the source change is delivered once")
        model.value = 1
        Task { @MainActor in
            while changes == 0 { await Task.yield() }
            changed.fulfill()
        }
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(changes, 1)
        observer.cancel()
    }
}
