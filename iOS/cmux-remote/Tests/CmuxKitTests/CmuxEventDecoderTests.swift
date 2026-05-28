import XCTest
@testable import CmuxKit

/// Tests for the cmux events-stream NDJSON decoder.
///
/// The decoder is verified against frames lifted verbatim from
/// `docs/events.md` so any drift in the documented shape will show up as a
/// test failure here before it breaks the iOS client in production.
final class CmuxEventDecoderTests: XCTestCase {
    private let decoder = CmuxEventDecoder()

    func testDecodeAckBaseline() throws {
        let line = """
        {"type":"ack","protocol":"cmux-events","version":1,"boot_id":"0F221057-0320-41B7-8CB3-083C8D927D95","subscription_id":"8F6F1E66-0D6E-4B4D-A0F8-0F7B0B7B92CA","heartbeat_interval_seconds":15,"replay_count":2,"resume":{"after_seq":123,"requested_after_seq":123,"oldest_seq":120,"latest_seq":125,"next_seq":126,"gap":false},"filters":{"names":[],"categories":["notification"]}}
        """
        let frame = try decoder.decode(line: line)
        guard case .ack(let ack) = frame else { return XCTFail("expected ack") }
        XCTAssertEqual(ack.bootID, "0F221057-0320-41B7-8CB3-083C8D927D95")
        XCTAssertEqual(ack.subscriptionID, "8F6F1E66-0D6E-4B4D-A0F8-0F7B0B7B92CA")
        XCTAssertEqual(ack.heartbeatIntervalSeconds, 15)
        XCTAssertEqual(ack.replayCount, 2)
        XCTAssertEqual(ack.resume.afterSeq, 123)
        XCTAssertEqual(ack.resume.latestSeq, 125)
        XCTAssertFalse(ack.resume.gap)
        XCTAssertEqual(ack.filterCategories, ["notification"])
    }

    func testDecodeAckGapTrue() throws {
        let line = """
        {"type":"ack","boot_id":"X","subscription_id":"S","heartbeat_interval_seconds":15,"replay_count":0,"resume":{"after_seq":1,"oldest_seq":100,"latest_seq":105,"next_seq":106,"gap":true},"filters":{"names":[],"categories":[]}}
        """
        let frame = try decoder.decode(line: line)
        guard case .ack(let ack) = frame else { return XCTFail("expected ack") }
        XCTAssertTrue(ack.resume.gap)
        XCTAssertEqual(ack.resume.oldestSeq, 100)
    }

    func testDecodeEvent() throws {
        let line = """
        {"type":"event","protocol":"cmux-events","version":1,"boot_id":"0F221057-0320-41B7-8CB3-083C8D927D95","seq":126,"id":"0F221057-0320-41B7-8CB3-083C8D927D95-126","name":"notification.created","category":"notification","source":"notification.store","occurred_at":"2026-05-06T19:18:03.421Z","workspace_id":"9B6920C1-6C29-4C27-A069-78CF285F932A","surface_id":"83F4E6A4-5246-4DB8-A412-9CE7B059FA6C","payload":{"notification_id":"7ED5F805-CC6F-4B06-9701-AC798F63E209","title_length":14,"redacted_fields":["title"]}}
        """
        let frame = try decoder.decode(line: line)
        guard case .event(let event) = frame else { return XCTFail("expected event") }
        XCTAssertEqual(event.seq, 126)
        XCTAssertEqual(event.name, "notification.created")
        XCTAssertEqual(event.category, "notification")
        XCTAssertEqual(event.workspaceID, WorkspaceID("9B6920C1-6C29-4C27-A069-78CF285F932A"))
        XCTAssertEqual(event.surfaceID, SurfaceID("83F4E6A4-5246-4DB8-A412-9CE7B059FA6C"))
        // Payload roundtrips JSON-stable.
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: event.payload) as? [String: Any])
        XCTAssertEqual(payload["notification_id"] as? String, "7ED5F805-CC6F-4B06-9701-AC798F63E209")
    }

    func testDecodeHeartbeat() throws {
        let line = """
        {"type":"heartbeat","protocol":"cmux-events","version":1,"boot_id":"B","subscription_id":"S","latest_seq":126,"occurred_at":"2026-05-06T19:18:18.421Z"}
        """
        let frame = try decoder.decode(line: line)
        guard case .heartbeat(let hb) = frame else { return XCTFail("expected heartbeat") }
        XCTAssertEqual(hb.bootID, "B")
        XCTAssertEqual(hb.subscriptionID, "S")
        XCTAssertEqual(hb.latestSeq, 126)
    }

    func testFeedDecisionIdentifierPrefersOpenCodeRequestID() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": "workstream-item-id",
            "session_id": "agent-session-id",
            "_opencode_request_id": "decision-request-id"
        ])
        XCTAssertEqual(
            FeedDecisionIdentifier.extract(from: payload),
            "decision-request-id"
        )
    }

    func testFeedDecisionIdentifierIgnoresGenericItemIDs() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "item": [
                "id": "workstream-item-id",
                "session_id": "agent-session-id"
            ]
        ])
        XCTAssertNil(FeedDecisionIdentifier.extract(from: payload))
    }

    func testFeedDecisionIdentifierFindsNestedRequestID() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "result": [
                "request_id": "nested-request-id"
            ]
        ])
        XCTAssertEqual(
            FeedDecisionIdentifier.extract(from: payload),
            "nested-request-id"
        )
    }

    func testDecodeUnknownTypeThrows() {
        let line = "{\"type\":\"future-shape\"}"
        XCTAssertThrowsError(try decoder.decode(line: line))
    }

    func testDecodeMissingRequiredKeyThrows() {
        let line = "{\"type\":\"event\",\"boot_id\":\"X\"}"
        XCTAssertThrowsError(try decoder.decode(line: line))
    }

    func testSeedCursorPreservesSeqOnReconnect() async {
        // Regression: ConnectionManager.applyCursor previously synthesised
        // a fake `ack` with an empty boot_id and ran it through
        // resetCursor, which wiped the seq on the *next* real ack
        // because boot_id mismatch fires the reset. With seedCursor we
        // must preserve the persisted seq.
        let state = ServerState()
        await state.seedCursor(CmuxEventCursor(bootID: "boot-A", seq: 42))
        let snapshot = await state.current
        XCTAssertEqual(snapshot.cursor.seq, 42)
        XCTAssertEqual(snapshot.cursor.bootID, "boot-A")
    }

    func testNotificationReadEventAppliesNotificationIDsArray() async throws {
        let state = ServerState()
        let createdAt = Date()
        await state.ingestSnapshot(
            windows: [],
            workspaces: [],
            panes: [],
            surfaces: [],
            notifications: [
                CmuxNotification(
                    id: NotificationID("n1"),
                    workspaceID: nil,
                    surfaceID: nil,
                    title: nil,
                    subtitle: nil,
                    body: nil,
                    tabTitle: nil,
                    createdAt: createdAt,
                    isRead: false
                ),
                CmuxNotification(
                    id: NotificationID("n2"),
                    workspaceID: nil,
                    surfaceID: nil,
                    title: nil,
                    subtitle: nil,
                    body: nil,
                    tabTitle: nil,
                    createdAt: createdAt,
                    isRead: false
                )
            ]
        )
        let payload = try JSONSerialization.data(withJSONObject: ["notification_ids": ["n1", "n2"]])
        await state.apply(event: CmuxEventFrame.Event(
            bootID: "B", seq: 10, id: "B-10",
            name: "notification.read",
            category: "notification",
            source: "notification.store",
            occurredAt: Date(),
            workspaceID: nil,
            surfaceID: nil,
            paneID: nil,
            windowID: nil,
            payload: payload
        ))
        let snapshot = await state.current
        XCTAssertEqual(snapshot.unreadNotifications, 0)
        XCTAssertTrue(snapshot.notifications[NotificationID("n1")]?.isRead == true)
        XCTAssertTrue(snapshot.notifications[NotificationID("n2")]?.isRead == true)
    }

    func testNotificationClearedEventRemovesOnlyListedIDsWhenPresent() async throws {
        let state = ServerState()
        let createdAt = Date()
        await state.ingestSnapshot(
            windows: [],
            workspaces: [],
            panes: [],
            surfaces: [],
            notifications: [
                CmuxNotification(
                    id: NotificationID("n1"),
                    workspaceID: nil,
                    surfaceID: nil,
                    title: nil,
                    subtitle: nil,
                    body: nil,
                    tabTitle: nil,
                    createdAt: createdAt,
                    isRead: false
                ),
                CmuxNotification(
                    id: NotificationID("n2"),
                    workspaceID: nil,
                    surfaceID: nil,
                    title: nil,
                    subtitle: nil,
                    body: nil,
                    tabTitle: nil,
                    createdAt: createdAt,
                    isRead: false
                )
            ]
        )
        let payload = try JSONSerialization.data(withJSONObject: ["notification_ids": ["n1"]])
        await state.apply(event: CmuxEventFrame.Event(
            bootID: "B", seq: 11, id: "B-11",
            name: "notification.cleared",
            category: "notification",
            source: "notification.store",
            occurredAt: Date(),
            workspaceID: nil,
            surfaceID: nil,
            paneID: nil,
            windowID: nil,
            payload: payload
        ))
        let snapshot = await state.current
        XCTAssertNil(snapshot.notifications[NotificationID("n1")])
        XCTAssertNotNil(snapshot.notifications[NotificationID("n2")])
    }

    func testCursorAdvancesAndResetsAcrossBootIDChange() {
        var cursor = CmuxEventCursor()
        let event = CmuxEventFrame.Event(
            bootID: "boot-A", seq: 5, id: "boot-A-5",
            name: "x", category: "y", source: "z", occurredAt: Date(),
            workspaceID: nil, surfaceID: nil, paneID: nil, windowID: nil,
            payload: Data()
        )
        cursor.advance(to: event)
        XCTAssertEqual(cursor.seq, 5)
        XCTAssertEqual(cursor.bootID, "boot-A")

        let ackSameBoot = CmuxEventFrame.Ack(
            bootID: "boot-A", subscriptionID: "S",
            heartbeatIntervalSeconds: 15, replayCount: 0,
            resume: .init(afterSeq: 5, requestedAfterSeq: 5,
                          oldestSeq: 1, latestSeq: 5, nextSeq: 6, gap: false),
            filterNames: [], filterCategories: []
        )
        cursor.reset(for: ackSameBoot)
        XCTAssertEqual(cursor.seq, 5, "Same boot-id should keep the seq")

        let ackDifferentBoot = CmuxEventFrame.Ack(
            bootID: "boot-B", subscriptionID: "S",
            heartbeatIntervalSeconds: 15, replayCount: 0,
            resume: .init(afterSeq: nil, requestedAfterSeq: nil,
                          oldestSeq: nil, latestSeq: nil, nextSeq: nil, gap: false),
            filterNames: [], filterCategories: []
        )
        cursor.reset(for: ackDifferentBoot)
        XCTAssertNil(cursor.seq, "Different boot-id should clear the seq")
        XCTAssertEqual(cursor.bootID, "boot-B")
    }
}
