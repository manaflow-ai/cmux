import XCTest
@testable import CMUXEventsCore
import CMUXWorkstream

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxEventPublishingIntegrationTests: XCTestCase {
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
            ),
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
}
