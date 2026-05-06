import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxEventBusTests: XCTestCase {
    func testSubscribeReplaysEventsAfterSequenceAndReportsAck() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        bus.publish(
            name: "workspace.created",
            category: "workspace",
            source: "test",
            workspaceId: "w1",
            payload: ["value": "one"]
        )
        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "w1",
            payload: ["title": "Done"]
        )

        let snapshot = bus.subscribe(afterSequence: 1, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        XCTAssertEqual(snapshot.replay.count, 1)
        XCTAssertEqual(snapshot.replay.first?["name"] as? String, "notification.created")
        XCTAssertEqual(snapshot.ack["type"] as? String, "ack")

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual((resume["latest_seq"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(resume["gap"] as? Bool, false)
    }

    func testSubscribeReportsGapWhenCursorFallsOutOfRetention() throws {
        let bus = CmuxEventBus(retainedEventLimit: 2)
        bus.publish(name: "a", category: "test", source: "test")
        bus.publish(name: "b", category: "test", source: "test")
        bus.publish(name: "c", category: "test", source: "test")

        let snapshot = bus.subscribe(afterSequence: 0, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual(resume["gap"] as? Bool, true)
        XCTAssertEqual(snapshot.replay.compactMap { $0["name"] as? String }, ["b", "c"])
    }

    func testSubscribeReportsGapWhenCursorIsNewerThanProcess() throws {
        let bus = CmuxEventBus(retainedEventLimit: 2)
        let snapshot = bus.subscribe(afterSequence: 42, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual(resume["gap"] as? Bool, true)
        XCTAssertEqual((resume["latest_seq"] as? NSNumber)?.int64Value, 0)
        XCTAssertNotNil(snapshot.ack["boot_id"] as? String)
    }

    func testSubscriptionFiltersLiveEventsByCategory() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let snapshot = bus.subscribe(afterSequence: nil, names: [], categories: ["notification"])
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(name: "workspace.created", category: "workspace", source: "test")
        bus.publish(name: "notification.created", category: "notification", source: "test")

        let event = snapshot.subscription.next(timeout: 0.2)
        XCTAssertEqual(event?["name"] as? String, "notification.created")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testEventEncodingIsSingleLineJSON() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        bus.publish(
            name: "surface.input_sent",
            category: "surface",
            source: "test",
            payload: ["text": "hello\nworld"]
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().first)
        let line = try XCTUnwrap(CmuxEventBus.encodeLine(event))
        XCTAssertFalse(line.contains("\n"))

        let data = try XCTUnwrap(line.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(parsed["type"] as? String, "event")
        XCTAssertNotNil(parsed["boot_id"] as? String)
    }

    func testEncodingPreservesZeroAndOneNumbers() throws {
        let line = try XCTUnwrap(CmuxEventBus.encodeLine([
            "zero": NSNumber(value: Int64(0)),
            "one": NSNumber(value: Int64(1)),
            "truth": true
        ]))

        XCTAssertTrue(line.contains("\"zero\":0"))
        XCTAssertTrue(line.contains("\"one\":1"))
        XCTAssertTrue(line.contains("\"truth\":true"))
    }

    func testPublishAppendsDurableEventLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(retainedEventLimit: 4, eventLogURL: logURL)

        bus.publish(name: "workspace.created", category: "workspace", source: "test")
        bus.publish(name: "surface.created", category: "surface", source: "test")

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.count, 2)

        let secondData = try XCTUnwrap(lines.last?.data(using: .utf8))
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        XCTAssertEqual(second["name"] as? String, "surface.created")
    }
}
