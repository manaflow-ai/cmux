import Combine
import Observation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Observable private final class ObservedValueTrackingTestModel {
    var value = 0
}

private final class RetainProbe {}

/// Suspend the main-actor test job so queued `@MainActor` tasks (the bridge's
/// re-arm hop) can run, until `condition` holds or the iteration bound trips.
@MainActor
private func drainMainActor(until condition: () -> Bool, maxIterations: Int = 500) async {
    var iterations = 0
    while !condition(), iterations < maxIterations {
        iterations += 1
        await Task.yield()
    }
}

/// Lifecycle coverage for the Observation-to-Combine bridge in
/// `Sources/ObservedValueTracking.swift`. The Observation runtime retains a
/// registered onChange callback until a tracked property next mutates, so the
/// bridge keeps all caller captures on a coordinator that cancellation releases
/// immediately; these tests pin that contract.
@MainActor
struct ObservedValueTrackingTests {
    @Test func cancelReleasesCapturesWhileObservedValueIsIdle() {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var token: ObservationToken?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            token = observeTrackedValue({ model.value }) { _ in _ = probe }
        }
        #expect(weakProbe != nil, "An active observation must retain its onChange captures")

        token?.cancel()
        #expect(
            weakProbe == nil,
            "cancel() must release onChange captures immediately, without waiting for a model write"
        )
        token = nil
    }

    @Test func droppingTokenReleasesCapturesWhileObservedValueIsIdle() {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var token: ObservationToken?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            token = observeTrackedValue({ model.value }) { _ in _ = probe }
        }
        #expect(weakProbe != nil)

        token = nil
        #expect(
            weakProbe == nil,
            "Dropping the token must release onChange captures even while the observed value is idle"
        )
    }

    @Test func publisherCancellationReleasesCaptures() {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var cancellable: AnyCancellable?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            cancellable = observedValuesPublisher({ _ = probe; return model.value }).sink { _ in }
        }
        #expect(weakProbe != nil, "An active publisher subscription must retain its read captures")

        cancellable?.cancel()
        cancellable = nil
        #expect(
            weakProbe == nil,
            "Cancelling the bridged publisher must release read captures without waiting for a model write"
        )
    }

    @Test func backgroundThreadCancelReleasesCaptures() async {
        let model = ObservedValueTrackingTestModel()
        weak var weakProbe: RetainProbe?
        var token: ObservationToken?
        autoreleasepool {
            let probe = RetainProbe()
            weakProbe = probe
            token = observeTrackedValue({ model.value }) { _ in _ = probe }
        }
        #expect(weakProbe != nil)

        // Combine's receiveCancel runs on the cancelling thread; cancel() must
        // be safe off-main and still release the captures (via a main hop).
        let offMainToken = token
        await Task.detached { offMainToken?.cancel() }.value
        token = nil

        await drainMainActor(until: { weakProbe == nil })
        #expect(weakProbe == nil, "Off-main cancel() must release onChange captures")
    }

    @Test func deliversChangesAndStopsAfterCancel() async {
        let model = ObservedValueTrackingTestModel()
        var received: [Int] = []
        let token = observeTrackedValue({ model.value }) { received.append($0) }
        #expect(received == [0], "Initial delivery must fire synchronously at arm time")

        model.value = 1
        // The bridge re-arms through a MainActor task; suspend until it lands.
        await drainMainActor(until: { received.count >= 2 })
        #expect(received == [0, 1])

        token.cancel()
        model.value = 2
        // Bounded drain with no exit condition: give a (buggy) post-cancel
        // delivery every chance to land before asserting it did not.
        await drainMainActor(until: { false }, maxIterations: 50)
        #expect(received == [0, 1], "No deliveries may arrive after cancel()")
    }
}
