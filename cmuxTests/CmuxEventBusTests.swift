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

    func testSlowSubscriptionClosesWhenPendingQueueIsFull() {
        let bus = CmuxEventBus(retainedEventLimit: 8, maxPendingEventsPerSubscription: 2)
        let snapshot = bus.subscribe(afterSequence: nil, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(name: "one", category: "test", source: "test")
        bus.publish(name: "two", category: "test", source: "test")
        bus.publish(name: "three", category: "test", source: "test")

        XCTAssertTrue(snapshot.subscription.isClosed)
        XCTAssertEqual(snapshot.subscription.closeReason, "pending event buffer exceeded 2 events")
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

    func testOversizedEventPayloadIsTruncatedBeforeRetention() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4, maxEventLineBytes: 1_024)

        bus.publish(
            name: "agent.log",
            category: "agent",
            source: "test",
            payload: ["message": String(repeating: "x", count: 20_000)]
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().first)
        XCTAssertEqual(event["payload_truncated"] as? Bool, true)

        let line = try XCTUnwrap(CmuxEventBus.encodeLine(event))
        XCTAssertLessThanOrEqual(line.utf8.count, 1_024)
    }

    func testWindowLifecyclePayloadIncludesFocusState() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        let windowId = UUID()
        let workspaceId = UUID()

        bus.publishWindowLifecycle(
            name: "window.keyed",
            windowId: windowId,
            workspaceId: workspaceId,
            workspaceCount: 2,
            selectedWorkspaceIndex: 1,
            isKeyWindow: true,
            isMainWindow: true,
            origin: "unit"
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().first)
        XCTAssertEqual(event["name"] as? String, "window.keyed")
        XCTAssertEqual(event["source"] as? String, "window.lifecycle")
        XCTAssertEqual(event["window_id"] as? String, windowId.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["workspace_id"] as? String, workspaceId.uuidString)
        XCTAssertEqual((payload["workspace_count"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(payload["is_key_window"] as? Bool, true)
        XCTAssertEqual(payload["is_main_window"] as? Bool, true)
    }

    func testNotificationReplacementPublishesRemovedThenCreatedWithReplacedIds() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let workspaceId = UUID()
        let surfaceId = UUID()
        let oldNotification = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "Old",
            subtitle: "",
            body: "Done",
            createdAt: Date(),
            isRead: false
        )
        let newNotification = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "New",
            subtitle: "",
            body: "Done",
            createdAt: Date(),
            isRead: false
        )

        bus.publishNotificationChanges(oldValue: [oldNotification], newValue: [newNotification])

        let events = bus.retainedSnapshot()
        XCTAssertEqual(events.compactMap { $0["name"] as? String }, ["notification.removed", "notification.created"])
        let removedPayload = try XCTUnwrap(events.first?["payload"] as? [String: Any])
        XCTAssertTrue(removedPayload["title"] is NSNull)
        XCTAssertTrue(removedPayload["subtitle"] is NSNull)
        XCTAssertTrue(removedPayload["body"] is NSNull)
        XCTAssertEqual(removedPayload["title_length"] as? Int, 3)
        XCTAssertEqual(removedPayload["body_length"] as? Int, 4)
        XCTAssertEqual(removedPayload["redacted_fields"] as? [String], ["title", "subtitle", "body"])
        let createdPayload = try XCTUnwrap(events.last?["payload"] as? [String: Any])
        XCTAssertTrue(createdPayload["title"] is NSNull)
        XCTAssertTrue(createdPayload["subtitle"] is NSNull)
        XCTAssertTrue(createdPayload["body"] is NSNull)
        XCTAssertEqual(createdPayload["title_length"] as? Int, 3)
        XCTAssertEqual(createdPayload["body_length"] as? Int, 4)
        XCTAssertEqual(createdPayload["redacted_fields"] as? [String], ["title", "subtitle", "body"])
        let replacedIds = try XCTUnwrap(createdPayload["replaced_notification_ids"] as? [String])
        XCTAssertEqual(replacedIds, [oldNotification.id.uuidString])
    }

    func testNotificationSocketParamsRedactTextFields() throws {
        let redacted = CmuxSocketEventMapper.redactedNotificationParams([
            "title": "Secret title",
            "subtitle": "Private subtitle",
            "body": "Sensitive body",
            "redacted_fields": ["existing"],
            "workspace_id": "workspace"
        ])

        XCTAssertTrue(redacted["title"] is NSNull)
        XCTAssertTrue(redacted["subtitle"] is NSNull)
        XCTAssertTrue(redacted["body"] is NSNull)
        XCTAssertEqual(redacted["title_length"] as? Int, 12)
        XCTAssertEqual(redacted["subtitle_length"] as? Int, 16)
        XCTAssertEqual(redacted["body_length"] as? Int, 14)
        XCTAssertEqual(redacted["redacted_fields"] as? [String], ["existing", "title", "subtitle", "body"])
        XCTAssertEqual(redacted["workspace_id"] as? String, "workspace")
    }

    func testPublishAppendsDurableEventLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(retainedEventLimit: 4, eventLogURL: logURL)

        bus.publish(name: "workspace.created", category: "workspace", source: "test")
        bus.publish(name: "surface.created", category: "surface", source: "test")
        bus.flushEventLogForTesting()

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.count, 2)

        let secondData = try XCTUnwrap(lines.last?.data(using: .utf8))
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        XCTAssertEqual(second["name"] as? String, "surface.created")
    }

    func testDurableEventLogRotatesAtByteLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-rotation-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(
            retainedEventLimit: 32,
            eventLogURL: logURL,
            maxEventLogBytes: 1_500,
            maxEventLineBytes: 1_024
        )

        for index in 0..<20 {
            bus.publish(
                name: "agent.log",
                category: "agent",
                source: "test",
                payload: ["index": index, "message": String(repeating: "x", count: 120)]
            )
        }
        bus.flushEventLogForTesting()

        let rotatedURL = logURL.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
        XCTAssertLessThanOrEqual(try fileSize(logURL), 1_500)
        XCTAssertLessThanOrEqual(try fileSize(rotatedURL), 1_500)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return try XCTUnwrap(size).uint64Value
    }
}
