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

/// Lifecycle coverage for the Observation-to-Combine bridge in
/// `Sources/ObservedValueTracking.swift`. The Observation runtime retains a
/// registered onChange callback until a tracked property next mutates, so the
/// bridge keeps all caller captures on a coordinator that cancellation releases
/// immediately; these tests pin that contract.
@MainActor
final class ObservedValueTrackingTests: XCTestCase {
    func testCancelReleasesCapturesWhileObservedValueIsIdle() {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var token: ObservationToken?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            token = observeTrackedValue({ model.value }) { _ in _ = probe }
        }
        XCTAssertNotNil(weakProbe, "An active observation must retain its onChange captures")

        token?.cancel()
        XCTAssertNil(
            weakProbe,
            "cancel() must release onChange captures immediately, without waiting for a model write"
        )
        token = nil
    }

    func testDroppingTokenReleasesCapturesWhileObservedValueIsIdle() {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var token: ObservationToken?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            token = observeTrackedValue({ model.value }) { _ in _ = probe }
        }
        XCTAssertNotNil(weakProbe)

        token = nil
        XCTAssertNil(
            weakProbe,
            "Dropping the token must release onChange captures even while the observed value is idle"
        )
    }

    func testPublisherCancellationReleasesCaptures() {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var cancellable: AnyCancellable?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            cancellable = observedValuesPublisher({ _ = probe; return model.value }).sink { _ in }
        }
        XCTAssertNotNil(weakProbe, "An active publisher subscription must retain its read captures")

        cancellable?.cancel()
        cancellable = nil
        XCTAssertNil(
            weakProbe,
            "Cancelling the bridged publisher must release read captures without waiting for a model write"
        )
    }

    func testBackgroundThreadCancelReleasesCaptures() async {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var token: ObservationToken?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            token = observeTrackedValue({ model.value }) { _ in _ = probe }
        }
        XCTAssertNotNil(weakProbe)

        // Combine's receiveCancel runs on the cancelling thread; cancel() must
        // be safe off-main and still release the captures (via a main hop).
        let offMainToken = token
        await Task.detached { offMainToken?.cancel() }.value
        token = nil

        let deadline = Date().addingTimeInterval(5)
        while weakProbe != nil, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakProbe, "Off-main cancel() must release onChange captures")
    }

    func testDeliversChangesAndStopsAfterCancel() {
        let model = ObservedValueTrackingTestModel()
        var received: [Int] = []
        let token = observeTrackedValue({ model.value }) { received.append($0) }
        XCTAssertEqual(received, [0], "Initial delivery must fire synchronously at arm time")

        model.value = 1
        // The bridge re-arms through a MainActor task; pump until it lands.
        let deadline = Date().addingTimeInterval(5)
        while received.count < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(received, [0, 1])

        token.cancel()
        model.value = 2
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(received, [0, 1], "No deliveries may arrive after cancel()")
    }
}
