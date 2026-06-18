import XCTest
import CMUXWorkstream
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxEventBusTests: XCTestCase {
    private static func currentResidentBytes() throws -> UInt64 {
        var info = proc_taskinfo()
        let size = proc_pidinfo(
            getpid(),
            PROC_PIDTASKINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_taskinfo>.stride)
        )
        guard size == Int32(MemoryLayout<proc_taskinfo>.stride) else {
            throw XCTSkip("Unable to sample current resident memory")
        }
        return UInt64(info.pti_resident_size)
    }

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
        XCTAssertEqual(snapshot.ack["replay_count"] as? Int, 1)

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

    func testStrictSequenceParsingRejectsBooleanAndFloatFrames() throws {
        XCTAssertEqual(CmuxEventBus.int64(NSNumber(value: Int64(42))), 42)
        XCTAssertEqual(CmuxEventBus.int64("42"), 42)
        XCTAssertNil(CmuxEventBus.int64(true))
        XCTAssertNil(CmuxEventBus.int64(NSNumber(value: 1.5)))
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

    func testWorkspaceReorderSocketMapperDoesNotDuplicateLifecycleEvent() throws {
        CmuxEventBus.shared.resetForTesting()
        let snapshot = CmuxEventBus.shared.subscribe(
            afterSequence: nil,
            names: ["workspace.reordered"],
            categories: []
        )
        defer {
            CmuxEventBus.shared.unsubscribe(snapshot.subscription)
            CmuxEventBus.shared.resetForTesting()
        }

        let windowId = UUID()
        let workspaceId = UUID()
        let commandObject: [String: Any] = [
            "id": "reorder-test",
            "method": "workspace.reorder",
            "params": ["workspace_id": workspaceId.uuidString]
        ]
        let responseObject: [String: Any] = [
            "id": "reorder-test",
            "ok": true,
            "result": [
                "dry_run": false,
                "events": [[
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": "workspace:11",
                    "window_id": windowId.uuidString,
                    "window_ref": "window:1",
                    "from_index": 12,
                    "to_index": 1
                ]]
            ]
        ]
        let commandData = try JSONSerialization.data(withJSONObject: commandObject)
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        let command = try XCTUnwrap(String(data: commandData, encoding: .utf8))
        let response = try XCTUnwrap(String(data: responseData, encoding: .utf8))

        CmuxSocketEventMapper.publish(command: command, response: response)

        XCTAssertNil(snapshot.subscription.next(timeout: 0.2))
    }

    func testPublishV2ReadTextResponseDoesNotAccumulateOnLongLivedThread() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let commandObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "read-text-retention",
            "method": "surface.read_text",
            "params": [
                "workspace_id": UUID().uuidString,
                "surface_id": UUID().uuidString,
                "scrollback": true,
                "lines": 700
            ]
        ]
        let largeText = String(repeating: "x", count: 512 * 1_024)
        let responseObject: [String: Any] = [
            "id": "read-text-retention",
            "ok": true,
            "result": [
                "text": largeText,
                "base64": "",
                "workspace_id": UUID().uuidString,
                "surface_id": UUID().uuidString
            ]
        ]
        let commandData = try JSONSerialization.data(withJSONObject: commandObject)
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        let command = try XCTUnwrap(String(data: commandData, encoding: .utf8))
        let response = try XCTUnwrap(String(data: responseData, encoding: .utf8))

        let before = try Self.currentResidentBytes()
        let didFinishLoop = DispatchSemaphore(value: 0)
        let releaseThread = DispatchSemaphore(value: 0)
        let iterations = 180

        Thread.detachNewThread {
            for _ in 0..<iterations {
                CmuxSocketEventMapper.publish(command: command, response: response)
            }
            didFinishLoop.signal()
            _ = releaseThread.wait(timeout: .now() + 10)
        }

        XCTAssertEqual(didFinishLoop.wait(timeout: .now() + 15), .success)
        let after = try Self.currentResidentBytes()
        releaseThread.signal()

        let growth = after > before ? after - before : 0
        XCTAssertLessThan(
            growth,
            UInt64(32 * 1_024 * 1_024),
            "publishV2 retained \(growth) bytes after \(iterations) large surface.read_text responses on one socket worker thread"
        )
        XCTAssertTrue(CmuxEventBus.shared.retainedSnapshot().isEmpty)
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

    func testNotificationRemovalDeduplicatesDuplicateOldIds() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let workspaceId = UUID()
        let surfaceId = UUID()
        let notificationId = UUID()
        let firstNotification = TerminalNotification(
            id: notificationId,
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "First",
            subtitle: "",
            body: "Done",
            createdAt: Date(),
            isRead: false
        )
        let duplicateNotification = TerminalNotification(
            id: notificationId,
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "Duplicate",
            subtitle: "",
            body: "Done",
            createdAt: Date(),
            isRead: false
        )

        bus.publishNotificationChanges(
            oldValue: [firstNotification, duplicateNotification],
            newValue: []
        )

        XCTAssertEqual(
            bus.retainedSnapshot().compactMap { $0["name"] as? String },
            ["notification.removed"]
        )
    }

    @MainActor
    func testBulkNotificationClearPublishesClearedWithoutRemovedDuplicates() throws {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()
        let notifications = [
            TerminalNotification(
                id: UUID(),
                tabId: workspaceId,
                surfaceId: nil,
                title: "First",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
            TerminalNotification(
                id: UUID(),
                tabId: workspaceId,
                surfaceId: nil,
                title: "Second",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            )
        ]
        defer {
            store.replaceNotificationsForTesting([])
            CmuxEventBus.shared.resetForTesting()
        }

        store.replaceNotificationsForTesting(notifications)
        CmuxEventBus.shared.resetForTesting()

        store.clearNotifications(forTabId: workspaceId, discardQueuedNotifications: false)

        let events = CmuxEventBus.shared.retainedSnapshot()
        XCTAssertEqual(events.compactMap { $0["name"] as? String }, ["notification.cleared"])
        let payload = try XCTUnwrap(events.first?["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload["notification_ids"] as? [String] ?? []), Set(notifications.map { $0.id.uuidString }))
        XCTAssertEqual(payload["count"] as? Int, 2)
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

    func testV1NotifySurfacePublishesSurfaceIdWithoutWorkspaceId() throws {
        let surfaceId = UUID()
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(command: "notify_surface \(surfaceId.uuidString) done", response: "OK")

        let event = try XCTUnwrap(CmuxEventBus.shared.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "notification.requested")
        XCTAssertTrue(event["workspace_id"] is NSNull)
        XCTAssertEqual(event["surface_id"] as? String, surfaceId.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["surface_id"] as? String, surfaceId.uuidString)
    }

    func testV1MapperIgnoresNonSuccessResponses() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(command: "notify title", response: "OKAY")
        CmuxSocketEventMapper.publish(command: "notify title", response: "queued")
        CmuxSocketEventMapper.publish(command: "notify title", response: "ERROR: failed")

        XCTAssertTrue(CmuxEventBus.shared.retainedSnapshot().isEmpty)
    }

    func testWorkstreamPayloadRedactsSensitiveFields() throws {
        let event = WorkstreamEvent(
            sessionId: "session",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace",
            cwd: "/tmp/workspace",
            toolName: "Bash",
            toolInputJSON: #"{"command":"echo secret"}"#,
            context: WorkstreamContext(
                lastUserMessage: "secret prompt",
                assistantPreamble: "secret answer"
            ),
            requestId: "request",
            ppid: 42,
            receivedAt: Date(timeIntervalSince1970: 0),
            extraFieldsJSON: #"{"message":"secret extra","result":"secret output"}"#
        )

        let payload = CmuxEventBus.workstreamPayload(event)

        XCTAssertEqual(payload["session_id"] as? String, "session")
        XCTAssertEqual(payload["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(payload["tool_name"] as? String, "Bash")
        XCTAssertTrue(payload["tool_input"] is NSNull)
        XCTAssertTrue(payload["context"] is NSNull)
        XCTAssertTrue(payload["extra_fields"] is NSNull)
        XCTAssertEqual(payload["tool_input_length"] as? Int, 25)
        XCTAssertNotNil(payload["context_length"] as? Int)
        XCTAssertEqual(payload["extra_fields_length"] as? Int, 51)
        XCTAssertEqual(payload["redacted_fields"] as? [String], ["tool_input", "context", "extra_fields"])

        let line = try XCTUnwrap(CmuxEventBus.encodeLine(["payload": payload]))
        XCTAssertFalse(line.contains("secret"))
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

    func testDurableEventLogDropsOldestPendingLinesUnderBackpressure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-backpressure-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(
            retainedEventLimit: 8,
            eventLogURL: logURL,
            maxPendingEventLogLines: 2
        )

        bus.setEventLogFlushSuspendedForTesting(true)
        defer {
            bus.setEventLogFlushSuspendedForTesting(false)
            bus.flushEventLogForTesting()
        }

        for index in 0..<5 {
            bus.publish(
                name: "agent.log",
                category: "agent",
                source: "test",
                payload: ["index": index]
            )
        }

        let backlog = bus.eventLogBacklogSnapshotForTesting()
        XCTAssertEqual(backlog.pending, 2)
        XCTAssertEqual(backlog.dropped, 3)

        bus.setEventLogFlushSuspendedForTesting(false)
        bus.flushEventLogForTesting()

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let indexes = try lines.map { line in
            let data = try XCTUnwrap(line.data(using: .utf8))
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try XCTUnwrap(event["payload"] as? [String: Any])
            return try XCTUnwrap(payload["index"] as? Int)
        }
        XCTAssertEqual(indexes, [3, 4])
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
