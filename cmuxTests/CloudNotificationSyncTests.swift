#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
import Foundation
import Testing

/// The Cloud notification sync must converge on one invariant under any
/// sequence of feed replays, evictions, reads on other clients, local reads,
/// failed and successful acknowledgements, and app restarts: a retained row
/// is delivered here at most once, every local read of a retained unread row
/// is acknowledged exactly once, and the unread set the tree shows equals the
/// rows this client has neither read nor acknowledged.
@Suite("CloudNotificationSync")
struct CloudNotificationSyncTests {
    private static let me = "mac-a"

    private static func row(
        _ id: String,
        terminal: String? = "term_00000000000000000000000000000001",
        readBy: [String] = [],
        createdAt: UInt64 = 1
    ) -> CloudVMNotificationRow {
        // Left-pad so "n1" and "n10" stay distinct ids.
        CloudVMNotificationRow(
            id: "notification_\(String(repeating: "0", count: max(0, 32 - id.count)))\(id)",
            title: "title \(id)",
            subtitle: nil,
            body: "",
            level: "info",
            createdAtMs: createdAt,
            terminalID: terminal,
            readBy: readBy
        )
    }

    @Test func rowDecodesTheDaemonShapeAndToleratesOlderDaemons() throws {
        let object: [String: Any] = [
            "id": "notification_0000000000000000000000000000abcd",
            "session_id": "session_00000000000000000000000000000001",
            "title": "Claude needs approval",
            "body": "Bash",
            "level": "warning",
            "created_at_ms": "1725000000000",
            "unread": true,
            "read_by": ["mac-b", "phone-c"],
            "terminal_id": "term_00000000000000000000000000000009",
        ]
        let row = try #require(CloudVMNotificationRow.row(fromObject: object))
        #expect(row.id == "notification_0000000000000000000000000000abcd")
        #expect(row.title == "Claude needs approval")
        #expect(row.body == "Bash")
        #expect(row.level == "warning")
        #expect(row.createdAtMs == 1_725_000_000_000)
        #expect(row.terminalID == "term_00000000000000000000000000000009")
        #expect(row.readBy == ["mac-b", "phone-c"])
        #expect(row.isRead(by: "mac-b"))
        #expect(!row.isRead(by: Self.me))

        // A daemon from before per-client reads publishes no read_by.
        var legacy = object
        legacy.removeValue(forKey: "read_by")
        legacy["created_at_ms"] = 42
        let old = try #require(CloudVMNotificationRow.row(fromObject: legacy))
        #expect(old.readBy.isEmpty)
        #expect(old.createdAtMs == 42)
        #expect(CloudVMNotificationRow.row(fromObject: ["title": "no id"]) == nil)
    }

    @Test func rowsComeFromTheAcceptedStateDocument() throws {
        let snapshot: [String: Any] = [
            "machine": ["id": "machine_00000000000000000000000000000001", "name": "m", "origin": "local", "status": "running", "connectable": true, "deleted": false, "recoverable": false],
            "session": ["id": "session_00000000000000000000000000000001", "machine_id": "machine_00000000000000000000000000000001", "name": "main", "revision": "7"],
            "workspaces": [], "screens": [], "panes": [], "tabs": [], "terminals": [], "browsers": [], "agents": [],
            "notifications": [
                ["id": "notification_00000000000000000000000000000002", "session_id": "session_00000000000000000000000000000001", "title": "second", "body": "", "level": "info", "created_at_ms": "20", "unread": true, "read_by": []],
                ["id": "notification_00000000000000000000000000000001", "session_id": "session_00000000000000000000000000000001", "title": "first", "body": "", "level": "info", "created_at_ms": "10", "unread": false, "read_by": ["mac-a"]],
            ],
            "cursor": ["generation": "gen-1", "revision": "7"],
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: .cloud("vm-1")))
        let rows = CloudVMNotificationRow.rows(from: state)
        #expect(rows.map(\.title) == ["first", "second"], "rows sort oldest first by created_at_ms")
        #expect(rows[0].readBy == ["mac-a"])
    }

    @Test func planDeliversEachUnreadRowOnceAndNeverRowsOtherClientsReadForUs() {
        let a = Self.row("a")
        let b = Self.row("b", readBy: [Self.me])
        let c = Self.row("c", readBy: ["mac-b"])
        var state = CloudNotificationSyncState()

        let first = CloudNotificationSyncReducer.plan(rows: [a, b, c], clientID: Self.me, state: state)
        #expect(first.deliver.map(\.id) == [a.id, c.id], "b was read by this client on the machine; c only by another client")
        state = first.state

        // A snapshot repair replays the same rows: nothing is delivered twice.
        let replay = CloudNotificationSyncReducer.plan(rows: [a, b, c], clientID: Self.me, state: state)
        #expect(replay.deliver.isEmpty)
        #expect(replay.state == state)

        // Restart: the durable state alone must prevent re-delivery.
        let data = try! JSONEncoder().encode(state)
        let restored = try! JSONDecoder().decode(CloudNotificationSyncState.self, from: data)
        let afterRestart = CloudNotificationSyncReducer.plan(rows: [a, b, c], clientID: Self.me, state: restored)
        #expect(afterRestart.deliver.isEmpty)

        // Eviction drops bookkeeping; a new row on the same terminal still delivers.
        let d = Self.row("d")
        let evicted = CloudNotificationSyncReducer.plan(rows: [c, d], clientID: Self.me, state: state)
        #expect(evicted.deliver.map(\.id) == [d.id])
        #expect(Set(evicted.state.delivered) == [c.id, d.id])
        #expect(evicted.removed == [a.id], "a delivered row the machine dropped is withdrawn locally")
    }

    @Test func subtitleDecodesWhenTheMachineSentOne() throws {
        let object: [String: Any] = [
            "id": "notification_0000000000000000000000000000abce", "title": "Build done",
            "subtitle": "api tests", "body": "", "level": "info", "created_at_ms": "1", "unread": true, "read_by": [],
        ]
        #expect(try #require(CloudVMNotificationRow.row(fromObject: object)).subtitle == "api tests")
        var bare = object
        bare["subtitle"] = ""
        #expect(try #require(CloudVMNotificationRow.row(fromObject: bare)).subtitle == nil)
    }

    @Test func readsBecomeOneStableBatchThatSurvivesFailedSends() {
        let a = Self.row("a")
        let b = Self.row("b")
        let rows = [a, b]
        var state = CloudNotificationSyncReducer.plan(rows: rows, clientID: Self.me, state: CloudNotificationSyncState()).state
        var keys = ["k1", "k2", "k3"]
        let mint = { keys.removeFirst() }

        state = CloudNotificationSyncReducer.recordRead(ids: [a.id, a.id, "notification_unknown"], rows: rows, clientID: Self.me, state: state, newKey: mint)
        #expect(state.pendingAcks == [.init(key: "k1", ids: [a.id, "notification_unknown"])],
                "duplicates collapse; an id without a known row still acks (the daemon answers `unknown`)")
        #expect(CloudNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: Self.me, state: state) == [b.terminalID!],
                "a is pending, so the tree no longer shows it as unread")

        // Reading a again while pending mints nothing new: the key is stable across retries.
        let again = CloudNotificationSyncReducer.recordRead(ids: [a.id], rows: rows, clientID: Self.me, state: state, newKey: mint)
        #expect(again == state)
        #expect(keys == ["k2", "k3"])

        state = CloudNotificationSyncReducer.recordRead(ids: [b.id], rows: rows, clientID: Self.me, state: state, newKey: mint)
        #expect(state.pendingAcks.map(\.key) == ["k1", "k2"])
        #expect(CloudNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: Self.me, state: state).isEmpty)

        // The daemon confirms k1; the feed then shows read_by for a; k2 stays.
        state = CloudNotificationSyncReducer.ackCompleted(key: "k1", state: state)
        let confirmed = [Self.row("a", readBy: [Self.me]), b]
        let next = CloudNotificationSyncReducer.plan(rows: confirmed, clientID: Self.me, state: state)
        #expect(next.deliver.isEmpty)
        #expect(next.state.pendingAcks.map(\.key) == ["k2"])

        // A row read on the machine by this client from another surface is
        // already acknowledged: no batch is minted for it.
        let none = CloudNotificationSyncReducer.recordRead(ids: [confirmed[0].id], rows: confirmed, clientID: Self.me, state: next.state, newKey: mint)
        #expect(none == next.state)
    }

    @Test func evictionPrunesDeliveredButNeverAPendingAck() {
        let a = Self.row("a")
        let b = Self.row("b")
        var state = CloudNotificationSyncReducer.plan(rows: [a, b], clientID: Self.me, state: CloudNotificationSyncState()).state
        state = CloudNotificationSyncReducer.recordRead(ids: [a.id, b.id], rows: [a, b], clientID: Self.me, state: state, newKey: { "k" })
        let afterEviction = CloudNotificationSyncReducer.plan(rows: [b], clientID: Self.me, state: state).state
        #expect(afterEviction.pendingAcks == [.init(key: "k", ids: [a.id, b.id])], "a read is never dropped locally")
        #expect(afterEviction.delivered == [b.id])
        let allGone = CloudNotificationSyncReducer.plan(rows: [], clientID: Self.me, state: state).state
        #expect(allGone.pendingAcks == state.pendingAcks)
        #expect(allGone.delivered.isEmpty)
    }

    @Test func readsBeforeTheFirstSnapshotStillAckAndAcksOverlayTheRows() {
        // A restored banner is dismissed before any rows arrived.
        let early = CloudNotificationSyncReducer.recordRead(
            ids: ["notification_early"], rows: [], clientID: Self.me, state: CloudNotificationSyncState(), newKey: { "k1" }
        )
        #expect(early.pendingAcks == [.init(key: "k1", ids: ["notification_early"])])

        // A confirmed ack overlays this client onto the rows until the feed says so.
        let a = Self.row("a", readBy: ["mac-b"])
        let overlaid = CloudNotificationSyncReducer.markingRead(ids: [a.id], clientID: Self.me, rows: [a, Self.row("b")])
        #expect(overlaid[0].readBy == ["mac-a", "mac-b"])
        #expect(overlaid[1].readBy.isEmpty)
        let state = CloudNotificationSyncReducer.ackCompleted(key: "k1", state: early)
        #expect(CloudNotificationSyncReducer.unreadTerminalIDs(rows: overlaid, clientID: Self.me, state: state) == [Self.row("b").terminalID!])
    }

    @Test @MainActor func correlationKeysRoundTripThroughTheLocalStore() throws {
        let key = CloudNotificationCorrelation.key(machineID: "vm-1", notificationID: "notification_0000000000000000000000000000000a")
        let parsed = try #require(CloudNotificationCorrelation.parse(key))
        #expect(parsed.machineID == "vm-1")
        #expect(parsed.notificationID == "notification_0000000000000000000000000000000a")
        #expect(CloudNotificationCorrelation.parse("cursor-approval:1") == nil)
        #expect(CloudNotificationCorrelation.parse("cloud-notification:") == nil)

        let workspace = UUID()
        func notification(_ correlation: String?, read: Bool) -> TerminalNotification {
            TerminalNotification(
                id: UUID(),
                tabId: workspace,
                surfaceId: nil,
                panelId: nil,
                retargetsToLiveSurfaceOwner: false,
                correlationKey: correlation,
                title: "t",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: read
            )
        }
        let cloudA = CloudNotificationCorrelation.key(machineID: "vm-1", notificationID: "a")
        let cloudB = CloudNotificationCorrelation.key(machineID: "vm-1", notificationID: "b")
        let before = CloudNotificationSyncHub.newlyReadKeys(
            previous: [],
            current: [notification(cloudA, read: false), notification(cloudB, read: false), notification("local", read: false)]
        )
        #expect(before.unread == [cloudA, cloudB], "local notifications never become acks")
        // A read and a dismissal (gone from the list) both count as read.
        let after = CloudNotificationSyncHub.newlyReadKeys(
            previous: before.unread,
            current: [notification(cloudA, read: true), notification("local", read: false)]
        )
        #expect(after.read == [cloudA, cloudB])
        #expect(after.unread.isEmpty)
    }

    /// A snapshot and the next delta captured verbatim from a live Cloud VM
    /// daemon (cmux-tui 6b0f6b4, 2026-09-08). The notification upsert must
    /// apply as a delta; a rejection forces a snapshot recovery per
    /// notification and, after the bounded budget, degrades delivery to the
    /// periodic poll.
    @Test func liveDaemonNotificationDeltaAppliesOnTopOfItsSnapshot() throws {
        let snapshotJSON = #"""
        {"agents": [{"id": "agent_54775e47dc1fb8df1f9ff905348d9238", "session_id": "session_853c88cfa838be52d8f6703a5f070057", "source": "hook", "source_session": null, "state": "idle", "terminal_id": "term_20ea5478bd56b0e530afe74ac7fb5812", "updated_at_ms": "1788850036483"}], "browsers": [], "clients": [{"attached_terminal_ids": ["term_20ea5478bd56b0e530afe74ac7fb5812"], "client_kind": "native-mirror", "connected_seconds": "98", "id": "client_009163b4739da1b62d3f24e003c1e5c5", "name": "cmux cloud terminal", "self": false, "session_id": "session_853c88cfa838be52d8f6703a5f070057", "sizes": [{"cols": 68, "participating": false, "rows": 45, "terminal_id": "term_20ea5478bd56b0e530afe74ac7fb5812"}], "transport": "unix"}, {"attached_terminal_ids": [], "client_kind": null, "connected_seconds": "0", "id": "client_5942f4c2b68882a29e82afeea3ebb8ac", "name": null, "self": true, "session_id": "session_853c88cfa838be52d8f6703a5f070057", "sizes": [], "transport": "unix"}, {"attached_terminal_ids": [], "client_kind": null, "connected_seconds": "99", "id": "client_b4b117463a30711ceca31f98ce84f5bc", "name": null, "self": false, "session_id": "session_853c88cfa838be52d8f6703a5f070057", "sizes": [], "transport": "unix"}], "cursor": {"generation": "8c9e6270-69d1-4441-8c59-80836fb80dc9", "revision": "26"}, "frontend_projections": [], "machine": {"connectable": true, "deleted": false, "id": "machine_b0ab2a7ed684e2811af1b53aed93df7c", "name": "local", "origin": "local", "recoverable": false, "status": "running"}, "notifications": [{"body": "", "created_at_ms": "1788851276626", "id": "notification_195730a37e5935256b42edb74229d8d7", "level": "info", "read_by": ["mac-080a79a600268cb833452efcd1850e40"], "session_id": "session_853c88cfa838be52d8f6703a5f070057", "terminal_id": "term_20ea5478bd56b0e530afe74ac7fb5812", "title": "Instrumented probe", "unread": true}, {"body": "", "created_at_ms": "1788850393265", "id": "notification_79c6ab819a4ffa6861fbbb0a5c77bb8a", "level": "info", "read_by": [], "session_id": "session_853c88cfa838be52d8f6703a5f070057", "terminal_id": "term_d5ca1696a343f70ac9bef90233ad637b", "title": "Latency probe", "unread": true}, {"body": "", "created_at_ms": "1788850337739", "id": "notification_84f5cd2ce5df63384a66abd8f1451082", "level": "info", "read_by": ["mac-080a79a600268cb833452efcd1850e40"], "session_id": "session_853c88cfa838be52d8f6703a5f070057", "terminal_id": "term_20ea5478bd56b0e530afe74ac7fb5812", "title": "Live add", "unread": true}, {"body": "reconnect proof", "created_at_ms": "1788850118706", "id": "notification_ccdc0c98dacd18658efda585cd225bc0", "level": "info", "read_by": ["mac-080a79a600268cb833452efcd1850e40"], "session_id": "session_853c88cfa838be52d8f6703a5f070057", "terminal_id": "term_20ea5478bd56b0e530afe74ac7fb5812", "title": "Posted while link down", "unread": true}, {"body": "tests passed", "created_at_ms": "1788850036474", "id": "notification_53df1731aef511c4810453a939b62e7d", "level": "warning", "read_by": ["phone-c"], "session_id": "session_853c88cfa838be52d8f6703a5f070057", "terminal_id": "term_d5ca1696a343f70ac9bef90233ad637b", "title": "Build done", "unread": true}, {"body": "", "created_at_ms": "1788850036474", "id": "notification_1664441e4dda2fe1c53964a6c3b0c88e", "level": "info", "read_by": ["mac-080a79a600268cb833452efcd1850e40"], "session_id": "session_853c88cfa838be52d8f6703a5f070057", "terminal_id": "term_20ea5478bd56b0e530afe74ac7fb5812", "title": "Claude finished", "unread": true}], "panes": [{"focused": true, "id": "pane_385f075fb041c4cf46aaf0285a48ac6c", "name": null, "screen_id": "screen_09ab34ab732e0eb6d5a3d38062214e16", "zoomed": false}], "screens": [{"focused": true, "id": "screen_09ab34ab732e0eb6d5a3d38062214e16", "index": 0, "layout": {"active_pane_id": "pane_385f075fb041c4cf46aaf0285a48ac6c", "root": {"active_tab_id": "tab_f5a89134baaec987b2281c4833f18084", "kind": "leaf", "pane_id": "pane_385f075fb041c4cf46aaf0285a48ac6c", "tab_ids": ["tab_baabc20a9e6a8dd708e533316acce63f", "tab_f5a89134baaec987b2281c4833f18084"]}, "screen_id": "screen_09ab34ab732e0eb6d5a3d38062214e16", "version": 1, "zoomed_pane_id": null}, "name": null, "workspace_id": "ws_9a6b01ddcee1f3e79fe507cd61ea14f2"}], "session": {"connected": true, "generation": "8c9e6270-69d1-4441-8c59-80836fb80dc9", "id": "session_853c88cfa838be52d8f6703a5f070057", "machine_id": "machine_b0ab2a7ed684e2811af1b53aed93df7c", "name": "cloud", "revision": "26"}, "sidebar_views": [], "tabs": [{"content_id": "term_d5ca1696a343f70ac9bef90233ad637b", "content_kind": "terminal", "focused": false, "id": "tab_baabc20a9e6a8dd708e533316acce63f", "index": 0, "name": null, "pane_id": "pane_385f075fb041c4cf46aaf0285a48ac6c"}, {"content_id": "term_20ea5478bd56b0e530afe74ac7fb5812", "content_kind": "terminal", "focused": true, "id": "tab_f5a89134baaec987b2281c4833f18084", "index": 1, "name": null, "pane_id": "pane_385f075fb041c4cf46aaf0285a48ac6c"}], "terminals": [{"cols": 80, "cwd": "/root", "id": "term_d5ca1696a343f70ac9bef90233ad637b", "lifecycle": "running", "rows": 24, "running": true, "tab_id": "tab_baabc20a9e6a8dd708e533316acce63f", "tab_ids": ["tab_baabc20a9e6a8dd708e533316acce63f"], "title": ""}, {"cols": 68, "cwd": "/root", "id": "term_20ea5478bd56b0e530afe74ac7fb5812", "lifecycle": "running", "rows": 45, "running": true, "tab_id": "tab_f5a89134baaec987b2281c4833f18084", "tab_ids": ["tab_f5a89134baaec987b2281c4833f18084"], "title": ""}, {"cols": 80, "exit": {"exited_at": "1788849977923", "outcome": {"kind": "unknown", "reason": "terminal host ended without a durable exit sidecar"}, "revision": "5"}, "id": "term_10a74fe05bef5daa7769e483df7a1452", "lifecycle": "exited", "rows": 24, "running": false, "tab_id": null, "tab_ids": [], "title": ""}, {"cols": 80, "exit": {"exited_at": "1788849977908", "outcome": {"kind": "unknown", "reason": "terminal host ended without a durable exit sidecar"}, "revision": "4"}, "id": "term_00f223f071a94a86114c5f72d89ce8ca", "lifecycle": "exited", "rows": 24, "running": false, "tab_id": null, "tab_ids": [], "title": ""}], "workspaces": [{"focused": false, "id": "ws_497a8206b089a21275ff4b7f029c174e", "index": 0, "name": "shell", "session_id": "session_853c88cfa838be52d8f6703a5f070057"}, {"focused": true, "id": "ws_9a6b01ddcee1f3e79fe507cd61ea14f2", "index": 1, "name": "proof", "session_id": "session_853c88cfa838be52d8f6703a5f070057"}]}
        """#
        let deltaJSON = #"""
        {"changes": [{"id": "notification_70e80653f968332fb20cf8ea9eacb8d5", "kind": "upsert", "resource": "notification", "sequence": 0, "value": {"body": "", "created_at_ms": "1788851837053", "id": "notification_70e80653f968332fb20cf8ea9eacb8d5", "level": "info", "read_by": [], "session_id": "session_853c88cfa838be52d8f6703a5f070057", "terminal_id": "term_20ea5478bd56b0e530afe74ac7fb5812", "title": "Breadcrumb probe", "unread": true}}], "cursor": {"generation": "8c9e6270-69d1-4441-8c59-80836fb80dc9", "revision": "27"}, "kind": "delta", "previous_revision": "26", "revision": "27"}
        """#
        let snapshot = try #require(JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8)) as? [String: Any])
        let machine = SurfaceMachineID.cloud("vm-abbf70c854e14df9bd6d3dee8c91a1d3")
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
        #expect(state.cursor == CloudVMCursor(generation: "8c9e6270-69d1-4441-8c59-80836fb80dc9", revision: 26))
        #expect(CloudVMNotificationRow.rows(from: state).count == 6)

        let cursor = CloudVMCursor(generation: "8c9e6270-69d1-4441-8c59-80836fb80dc9", revision: 27)
        let application = CmuxTuiSnapshotParser.applyingWithImpact(
            deltaPayload: Data(deltaJSON.utf8),
            cursor: cursor,
            to: state
        )
        let applied = try #require(application, "the live notification upsert delta must apply without a snapshot")
        #expect(applied.state.cursor == cursor)
        let rows = CloudVMNotificationRow.rows(from: applied.state)
        #expect(rows.count == 7)
        #expect(rows.last?.title == "Breadcrumb probe")
        #expect(rows.last?.terminalID == "term_20ea5478bd56b0e530afe74ac7fb5812")
        #expect(!applied.impact.requiresFullResourceRebuild, "a notification row touches no resource rows")
    }

    /// Wire numbers arrive as JSON, where a number is an NSNumber and
    /// `NSNumber(0) is Bool` holds. The decoder must accept those numbers and
    /// reject only real booleans; before this test every zero-based delta
    /// sequence from a daemon was rejected and the feed fell back to snapshots.
    @Test func wireNumbersFromJSONDecodeZeroAndRejectBooleans() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(#"{"zero":0,"one":1,"big":18446744073709551615,"str":"42","yes":true,"no":false,"neg":-1,"frac":1.5}"#.utf8)) as? [String: Any])
        #expect(CloudWireNumber.unsigned(object["zero"]) == 0)
        #expect(CloudWireNumber.unsigned(object["one"]) == 1)
        #expect(CloudWireNumber.unsigned(object["big"]) == UInt64.max)
        #expect(CloudWireNumber.unsigned(object["str"]) == 42)
        #expect(CloudWireNumber.unsigned(object["yes"]) == nil)
        #expect(CloudWireNumber.unsigned(object["no"]) == nil)
        #expect(CloudWireNumber.unsigned(object["neg"]) == nil)
        #expect(CloudWireNumber.unsigned(object["frac"]) == nil)
        #expect(CloudWireNumber.unsigned(true) == nil)
        #expect(CloudWireNumber.unsigned(0) == 0)
    }

    @Test func ackArgumentsPinTheBatchKeyAndClient() {
        let arguments = CloudTuiCommandLine.notificationAckArguments(
            socketPath: "/tmp/s.sock",
            clientID: "mac-1",
            notificationIDs: ["notification_1", "notification_2"],
            idempotencyKey: "mac-ack-k"
        )
        #expect(arguments == [
            "--socket", "/tmp/s.sock", "--json", "--idempotency-key", "mac-ack-k",
            "notification", "ack", "--client", "mac-1", "notification_1", "notification_2",
        ])
        #expect(CloudTuiClientPaths.isValidNotificationClientID("mac-0123abcd"))
        #expect(!CloudTuiClientPaths.isValidNotificationClientID("has space"))
        #expect(!CloudTuiClientPaths.isValidNotificationClientID(""))
        #expect(!CloudTuiClientPaths.isValidNotificationClientID(String(repeating: "a", count: 129)))
    }

    /// Drives the live sync with injected effects: a flaky sender, a resolver
    /// that sometimes has no local placement, feed replays, evictions, other
    /// clients reading, and restarts through the durable store. Every step
    /// checks the invariant.
    @Test @MainActor func syncConvergesUnderRandomFaults() async throws {
        let defaults = try #require(UserDefaults(suiteName: "cmux.tests.cloud-notification-sync.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "") }
        let store = CloudNotificationSyncStore(defaults: defaults)
        let machineID = "vm-fuzz"
        let clients = ["mac-b", "phone-c"]
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }

        final class Effects {
            var delivered: [String] = []
            var acked: [String: [String]] = [:] // key -> ids
            var sendFails = false
            var hasPlacement = true
            var declineDelivery = false
            var withdrawn: [String] = []
            var unread: Set<String> = []
        }
        let effects = Effects()
        let workspace = UUID()
        let terminals = (1...4).map { "term_\(String(repeating: "0", count: 31))\($0)" }
        var keyCounter = 0

        func makeSync() -> CloudNotificationSync {
            CloudNotificationSync(
                machineID: machineID,
                clientID: Self.me,
                store: store,
                newKey: { keyCounter += 1; return "k\(keyCounter)" },
                resolveTarget: { _ in effects.hasPlacement ? CloudNotificationDeliveryTarget(workspaceID: workspace, panelID: nil) : nil },
                deliver: { row, _ in
                    if effects.declineDelivery { return false }
                    effects.delivered.append(row.id)
                    return true
                },
                send: { batch in
                    if effects.sendFails { throw CancellationError() }
                    effects.acked[batch.key, default: []] += batch.ids
                },
                unreadChanged: { effects.unread = $0 },
                withdraw: { ids in effects.withdrawn.append(contentsOf: ids) }
            )
        }

        var sync = makeSync()
        var rows: [CloudVMNotificationRow] = []
        var counter = 0
        var readByMe: Set<String> = []          // acknowledged on the machine (simulated daemon)
        var expectedWithdrawn: Set<String> = []  // delivered rows the fixture evicted
        var locallyRead: Set<String> = []        // rows this Mac read

        func machineApplyAcks() {
            // The simulated daemon folds confirmed acks into read_by.
            for ids in effects.acked.values {
                for id in ids { readByMe.insert(id) }
            }
            rows = rows.map { row in
                var row = row
                if readByMe.contains(row.id), !row.readBy.contains(Self.me) { row.readBy.append(Self.me) }
                return row
            }
        }

        for step in 0..<300 {
            switch next() % 12 {
            case 0...3:
                counter += 1
                rows.append(Self.row("n\(counter)", terminal: terminals[Int(next() % 4)], createdAt: UInt64(counter)))
                if rows.count > 40 {
                    let evicted = rows.removeFirst()
                    if effects.delivered.contains(evicted.id) { expectedWithdrawn.insert(evicted.id) }
                }
            case 4 where !rows.isEmpty:
                // Another client reads one row on the machine.
                let index = Int(next() % UInt64(rows.count))
                let other = clients[Int(next() % 2)]
                if !rows[index].readBy.contains(other) { rows[index].readBy.append(other) }
            case 5 where !rows.isEmpty:
                // This Mac reads a row it was shown.
                let candidates = rows.filter { effects.delivered.contains($0.id) }
                if let pick = candidates.isEmpty ? nil : candidates[Int(next() % UInt64(candidates.count))] {
                    locallyRead.insert(pick.id)
                    sync.noteRead(notificationIDs: [pick.id])
                    await Task.yield()
                }
            case 6:
                effects.sendFails.toggle()
                sync.linkDidConnect()
                await Task.yield()
            case 7:
                effects.hasPlacement.toggle()
            case 9:
                effects.declineDelivery.toggle()
            case 8:
                // Restart: the provider retires the old sync (its in-flight
                // flush must not write again), then a fresh one loads the
                // durable store.
                sync.retire()
                sync = makeSync()
            default:
                break
            }
            machineApplyAcks()
            #expect(Set(rows.map(\.id)).count == rows.count, "step \(step): fixture produced duplicate ids")
            sync.apply(rows: rows)
            await Task.yield()
            await Task.yield()

            // Invariant 1: at most one delivery per retained id, and only for rows not read by me.
            let deliveredCounts = Dictionary(effects.delivered.map { ($0, 1) }, uniquingKeysWith: +)
            let duplicates = deliveredCounts.filter { $0.value > 1 }.keys.sorted()
            #expect(duplicates.isEmpty, "step \(step): delivered twice: \(duplicates)")
            // Invariant 2: every local read of a retained row is pending or acknowledged.
            let ackedIDs = Set(effects.acked.values.flatMap { $0 })
            let pending = sync.state.pendingIDs
            for id in locallyRead where rows.contains(where: { $0.id == id }) {
                #expect(pending.contains(id) || ackedIDs.contains(id) || readByMe.contains(id), "step \(step): read \(id) was lost")
            }
            // Invariant 4: every delivered row the machine dropped was withdrawn exactly once, and nothing else was.
            let withdrawnCounts = Dictionary(effects.withdrawn.map { ($0, 1) }, uniquingKeysWith: +)
            #expect(withdrawnCounts.values.allSatisfy { $0 == 1 }, "step \(step): a row was withdrawn twice")
            #expect(Set(effects.withdrawn) == expectedWithdrawn, "step \(step): withdrawals \(Set(effects.withdrawn).symmetricDifference(expectedWithdrawn))")
            // Invariant 3: the unread set is exactly what the reducer computes from the durable state.
            let expected = CloudNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: Self.me, state: sync.state)
            #expect(sync.unreadTerminalIDs == expected, "step \(step): unread set diverged")
        }
        // Final drain: the link is healthy, everything pending must flush.
        effects.sendFails = false
        effects.declineDelivery = false
        sync.linkDidConnect()
        for _ in 0..<20 { await Task.yield() }
        #expect(sync.state.pendingAcks.isEmpty, "pending acks after a healthy flush: \(sync.state.pendingAcks)")
        // No key was ever sent with two different id sets.
        #expect(effects.acked.values.allSatisfy { Set($0).count == $0.count })
    }
}
