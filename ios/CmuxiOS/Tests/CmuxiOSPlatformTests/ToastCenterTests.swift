@testable import CmuxiOSPlatform
import Foundation
import Testing

@MainActor
@Suite("Toast queue")
struct ToastCenterTests {
    /// A sleep that never elapses on its own (dismissal is explicit).
    private static let forever: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3_600))
    }

    @Test func showsOneAtATimeInOrder() {
        let center = ToastCenter(sleep: Self.forever)
        center.show(Toast(.info, "one"))
        center.show(Toast(.success, "two"))
        center.show(Toast(.warning, "three"))
        #expect(center.current?.message == "one")
        #expect(center.queue.map(\.message) == ["two", "three"])
        center.dismissCurrent()
        #expect(center.current?.message == "two")
        center.dismissCurrent()
        center.dismissCurrent()
        #expect(center.current == nil)
        #expect(center.queue.isEmpty)
    }

    @Test func equalKeysCoalesceInPlace() {
        let center = ToastCenter(sleep: Self.forever)
        center.show(Toast(.info, "Copied"))
        let visible = center.current?.id
        center.show(Toast(.info, "Copied"))
        #expect(center.current?.id == visible)
        #expect(center.queue.isEmpty)
        center.show(Toast(.info, "Reconnecting 1", coalescingKey: "conn"))
        center.show(Toast(.info, "Reconnecting 2", coalescingKey: "conn"))
        #expect(center.queue.map(\.message) == ["Reconnecting 2"])
    }

    @Test func capDropsOldestNonFailure() {
        let center = ToastCenter(maxQueued: 2, sleep: Self.forever)
        center.show(Toast(.info, "visible"))
        center.show(Toast(.failure, "f1"))
        center.show(Toast(.info, "i1"))
        center.show(Toast(.info, "i2"))
        #expect(center.queue.map(\.message) == ["f1", "i2"])
        center.show(Toast(.failure, "f2"))
        center.show(Toast(.failure, "f3"))
        #expect(center.queue.map(\.message) == ["f2", "f3"])
    }

    @Test func dismissByIDRemovesQueuedToast() {
        let center = ToastCenter(sleep: Self.forever)
        center.show(Toast(.info, "a"))
        center.show(Toast(.info, "b"))
        let queued = try! #require(center.queue.first)
        center.dismiss(queued.id)
        #expect(center.queue.isEmpty)
        #expect(center.current?.message == "a")
    }

    @Test func actionRunsThenDismisses() {
        let center = ToastCenter(sleep: Self.forever)
        var ran = 0
        center.show(Toast(.failure, "Send failed", action: ToastAction(label: "Retry") { ran += 1 }))
        center.performAction()
        #expect(ran == 1)
        #expect(center.current == nil)
    }

    @Test func dwellElapsesAndAdvances() async {
        let gate = TickGate()
        let center = ToastCenter(sleep: { _ in await gate.next() })
        center.show(Toast(.info, "a"))
        center.show(Toast(.info, "b"))
        await gate.release()
        await center.dwellTask?.value
        #expect(center.current?.message == "b")
        await gate.release()
        await center.dwellTask?.value
        #expect(center.current == nil)
    }

    @Test func neverDwellStaysAndScaleApplies() async {
        let recorded = DurationBox()
        let center = ToastCenter(sleep: { recorded.append($0) })
        center.dwellScale = { 2 }
        center.show(Toast(.info, "sticky", dwell: .never))
        #expect(center.dwellTask == nil)
        center.dismissCurrent()
        center.show(Toast(.warning, "w"))
        await center.dwellTask?.value
        #expect(recorded.values == [.seconds(12)])
    }

    @Test func defaultDwellsFollowStyle() {
        #expect(Toast(.info, "x").dwell == .after(.milliseconds(3_500)))
        #expect(Toast(.failure, "x").dwell == .after(.seconds(6)))
        #expect(Toast(.success, "x", action: ToastAction(label: "Undo") {}).dwell == .after(.seconds(6)))
        #expect(Toast(.info, "x", title: "T").accessibilityText == "T, x")
    }
}

/// Releases one pending sleep per `release()`.
actor TickGate {
    private var tokens = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func next() async {
        if tokens > 0 {
            tokens -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            tokens += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class DurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Duration] = []
    func append(_ value: Duration) { lock.withLock { stored.append(value) } }
    var values: [Duration] { lock.withLock { stored } }
}
