import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records every Combine `Subscriber` contract violation instead of trapping.
///
/// `AsyncPublisher` (`.values`) requests one value at a time and hard-crashes
/// ("received an unexpected value") when an upstream forwards a value while
/// its outstanding demand is zero. The sidebar consumes `coalesceLatest`
/// through `.values`, so the operator must never emit past zero demand
/// (https://github.com/manaflow-ai/cmux/pull/8211 startup crash).
private final class DemandTrackingSubscriber<Input>: Subscriber {
    typealias Failure = Never

    private(set) var receivedValues: [Input] = []
    private(set) var valuesReceivedWithZeroDemand = 0
    private var outstandingDemand: Subscribers.Demand = .none
    private var subscription: Subscription?
    private let initialDemand: Subscribers.Demand

    init(initialDemand: Subscribers.Demand) {
        self.initialDemand = initialDemand
    }

    func receive(subscription: Subscription) {
        self.subscription = subscription
        if initialDemand > .none {
            outstandingDemand += initialDemand
            subscription.request(initialDemand)
        }
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        if outstandingDemand == .none {
            valuesReceivedWithZeroDemand += 1
        } else {
            outstandingDemand -= 1
        }
        receivedValues.append(input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {}

    func requestMore(_ demand: Subscribers.Demand) {
        outstandingDemand += demand
        subscription?.request(demand)
    }

    func cancel() {
        subscription?.cancel()
    }
}

@MainActor
@Suite
struct CoalesceLatestPublisherDemandTests {
    @Test
    func replayIsHeldUntilDownstreamRequestsDemand() {
        let upstream = CurrentValueSubject<Int, Never>(7)
        let subscriber = DemandTrackingSubscriber<Int>(initialDemand: .none)
        upstream
            .coalesceLatest(for: .zero, scheduler: RunLoop.main)
            .subscribe(subscriber)

        #expect(subscriber.valuesReceivedWithZeroDemand == 0)
        #expect(subscriber.receivedValues.isEmpty)

        subscriber.requestMore(.max(1))
        #expect(subscriber.valuesReceivedWithZeroDemand == 0)
        #expect(subscriber.receivedValues == [7])
        subscriber.cancel()
    }

    @Test
    func zeroDemandBurstConflatesToLatestValue() {
        let upstream = CurrentValueSubject<Int, Never>(0)
        let subscriber = DemandTrackingSubscriber<Int>(initialDemand: .none)
        upstream
            .coalesceLatest(for: .zero, scheduler: RunLoop.main)
            .subscribe(subscriber)

        upstream.send(1)
        upstream.send(2)
        upstream.send(3)
        #expect(subscriber.valuesReceivedWithZeroDemand == 0)
        #expect(subscriber.receivedValues.isEmpty)

        subscriber.requestMore(.max(1))
        #expect(subscriber.valuesReceivedWithZeroDemand == 0)
        #expect(subscriber.receivedValues == [3])
        subscriber.cancel()
    }

    @Test
    func demandOneAtATimeNeverReceivesUnrequestedValues() {
        // AsyncPublisher's exact pattern: one value of demand outstanding at
        // a time, with upstream emissions arriving between requests.
        let upstream = CurrentValueSubject<Int, Never>(0)
        let subscriber = DemandTrackingSubscriber<Int>(initialDemand: .max(1))
        upstream
            .coalesceLatest(for: .zero, scheduler: RunLoop.main)
            .subscribe(subscriber)

        #expect(subscriber.receivedValues == [0])

        upstream.send(1)
        upstream.send(2)
        #expect(subscriber.valuesReceivedWithZeroDemand == 0)
        #expect(subscriber.receivedValues == [0])

        subscriber.requestMore(.max(1))
        #expect(subscriber.valuesReceivedWithZeroDemand == 0)
        #expect(subscriber.receivedValues == [0, 2])

        upstream.send(3)
        subscriber.requestMore(.max(1))
        #expect(subscriber.valuesReceivedWithZeroDemand == 0)
        #expect(subscriber.receivedValues == [0, 2, 3])
        subscriber.cancel()
    }

    @Test
    func unlimitedDemandKeepsLeadingEdgeSynchronous() {
        // Sink-style subscribers (unlimited demand) must keep the original
        // synchronous leading-edge behavior.
        let upstream = CurrentValueSubject<Int, Never>(0)
        let subscriber = DemandTrackingSubscriber<Int>(initialDemand: .unlimited)
        upstream
            .coalesceLatest(for: .zero, scheduler: RunLoop.main)
            .subscribe(subscriber)

        #expect(subscriber.receivedValues == [0])
        upstream.send(1)
        #expect(subscriber.receivedValues == [0, 1])
        upstream.send(2)
        #expect(subscriber.receivedValues == [0, 1, 2])
        #expect(subscriber.valuesReceivedWithZeroDemand == 0)
        subscriber.cancel()
    }

    /// The sidebar consumes `coalesceLatest` from `@MainActor` tasks. The
    /// operator is main-thread only, so every demand request and the final
    /// cancel must reach it on the main thread. `AsyncPublisher` requests
    /// from its nonisolated `next()` on the generic executor, which raced the
    /// main thread's `receive` and over-released the coalesced value
    /// (CMUXTERM-MACOS-3ZZH, 3XS7).
    @Test
    func sidebarConsumptionDrivesOperatorOnlyFromMainThread() async {
        let recorder = SubscriptionThreadRecorder()
        let upstream = CurrentValueSubject<Int, Never>(0)
        let changes = upstream
            .coalesceLatest(for: .zero, scheduler: DispatchQueue.main)
            .handleEvents(
                receiveCancel: { recorder.record(.cancel) },
                receiveRequest: { _ in recorder.record(.request) }
            )
            .sidebarMainThreadValues()

        let consumer = Task { @MainActor in
            var received = 0
            for await _ in changes {
                received += 1
            }
            return received
        }
        for value in 1...40 {
            upstream.send(value)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        consumer.cancel()
        let received = await consumer.value
        let deadline = Date().addingTimeInterval(2)
        while !recorder.sawCancel, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(received > 0)
        #expect(recorder.requestCount > 0)
        #expect(recorder.sawCancel)
        #expect(recorder.offMainEvents == [])
    }
}

private final class SubscriptionThreadRecorder: @unchecked Sendable {
    enum Event: Equatable { case request, cancel }

    private let lock = NSLock()
    private var events: [(event: Event, onMain: Bool)] = []

    func record(_ event: Event) {
        let onMain = Thread.isMainThread
        lock.lock()
        events.append((event, onMain))
        lock.unlock()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.event == .request }.count
    }

    var sawCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains { $0.event == .cancel }
    }

    var offMainEvents: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { !$0.onMain }.map(\.event)
    }
}
