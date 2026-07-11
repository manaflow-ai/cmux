import Foundation
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class NotificationEnqueueResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
final class TerminalNotificationBackpressureTests: XCTestCase {
    func testSaturationCapsWaitersBeforeAcceptanceAndPreservesAcceptedFIFO() async {
        let bus = TerminalMutationBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.discardPendingNotifications()
            bus.drainForTesting()
            bus.setDrainsSuspendedForTesting(false)
        }

        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Seed \(index)",
                subtitle: "",
                body: ""
            ))
        }

        let started = expectation(description: "waiting producers started")
        started.expectedFulfillmentCount = TerminalMutationBus.maximumWaitingNotificationProducerCount
        let completed = expectation(description: "waiting producers completed")
        completed.expectedFulfillmentCount = TerminalMutationBus.maximumWaitingNotificationProducerCount
        let results = NotificationEnqueueResults()
        let expectedWaiterTitles = Set(
            (0..<TerminalMutationBus.maximumWaitingNotificationProducerCount).map { "Waiter \($0)" }
        )

        for index in 0..<TerminalMutationBus.maximumWaitingNotificationProducerCount {
            DispatchQueue.global(qos: .userInitiated).async {
                started.fulfill()
                results.append(bus.enqueueNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: "Waiter \(index)",
                    subtitle: "",
                    body: ""
                ))
                completed.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<10_000 {
            if bus.notificationQueueStateForTesting().0 == TerminalMutationBus.maximumWaitingNotificationProducerCount {
                break
            }
            await Task.yield()
        }

        let fullState = bus.notificationQueueStateForTesting()
        XCTAssertEqual(fullState.0, TerminalMutationBus.maximumWaitingNotificationProducerCount)
        XCTAssertEqual(fullState.1.count, TerminalMutationBus.maximumPendingMutationCount)
        XCTAssertFalse(bus.enqueueNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Rejected before acceptance",
            subtitle: "",
            body: ""
        ))
        XCTAssertEqual(bus.notificationQueueStateForTesting().1, fullState.1)

        bus.discardPendingNotifications()
        await fulfillment(of: [completed], timeout: 2)

        let acceptedState = bus.notificationQueueStateForTesting()
        XCTAssertEqual(results.snapshot(), Array(repeating: true, count: expectedWaiterTitles.count))
        XCTAssertEqual(Set(acceptedState.1), expectedWaiterTitles)
        XCTAssertEqual(acceptedState.1.count, expectedWaiterTitles.count)
        XCTAssertEqual(acceptedState.2, acceptedState.2.sorted())
        XCTAssertEqual(Set(acceptedState.2).count, acceptedState.2.count)
    }
}
