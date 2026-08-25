import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SurfaceSelectionEventContractTests: XCTestCase {
    private let topic = "surface.selection_changed"

    func testUnfilteredSubscriptionDoesNotReceiveOrRetainSelectionText() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [], categories: [])
        defer { bus.unsubscribe(subscription.subscription) }

        bus.publish(
            name: topic,
            category: "surface",
            source: "test",
            payload: ["text": "private selection"]
        )

        XCTAssertNil(subscription.subscription.next(timeout: 0.05))
        XCTAssertTrue(bus.retainedSnapshot().isEmpty)
        XCTAssertEqual(bus.latestSequence, 0)
    }

    func testCategoryOnlySubscriptionDoesNotOptIntoSelectionText() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [], categories: ["surface"])
        defer { bus.unsubscribe(subscription.subscription) }

        bus.publish(
            name: topic,
            category: "surface",
            source: "test",
            payload: ["text": "private selection"]
        )

        XCTAssertNil(subscription.subscription.next(timeout: 0.05))
        XCTAssertTrue(bus.retainedSnapshot().isEmpty)
    }

    func testExactNameSubscriptionOptsIntoSelectionText() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [topic], categories: [])
        defer { bus.unsubscribe(subscription.subscription) }

        bus.publish(
            name: topic,
            category: "surface",
            source: "test",
            workspaceId: "workspace",
            surfaceId: "surface",
            payload: ["text": "private selection"]
        )

        let event = try XCTUnwrap(subscription.subscription.next(timeout: 0.2))
        XCTAssertEqual(event["name"] as? String, topic)
        XCTAssertEqual((event["payload"] as? [String: Any])?["text"] as? String, "private selection")
        XCTAssertEqual(bus.retainedSnapshot().count, 1)
    }
}
