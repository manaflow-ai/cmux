import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The pure half of cloud-machine notifications: what the Mac accepts off a machine's
/// `session current events --jsonl` stream, how it bounds and cleans it, how it rate-limits
/// it, and how it attributes it. Everything on that stream is machine-controlled, so these
/// tests are the boundary: a hostile daemon must get at most a sanitized, rate-limited,
/// host-attributed notification per legitimate `notify`, and nothing else.
@Suite struct CloudMachineNotificationEventTests {
    static let notificationID = "notification_0123456789abcdef0123456789abcdef"
    static let otherNotificationID = "notification_fedcba9876543210fedcba9876543210"
    static let terminalID = "term_0123456789abcdef0123456789abcdef"
    static let machine = SurfaceMachineID.cloud("vivid-newt")

    // MARK: Fixtures

    static func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func envelope(item: [String: Any], type: String = "stream_item") -> String {
        jsonLine([
            "protocol": "cmux.protocol/2",
            "type": type,
            "stream_id": "stream_00000000000000000000000000000001",
            "sequence": "7",
            "cursor": ["generation": "g1", "revision": "41"],
            "item": item,
        ])
    }

    static func delta(_ changes: [[String: Any]]) -> String {
        envelope(item: [
            "kind": "delta",
            "cursor": ["generation": "g1", "revision": "41"],
            "previous_revision": "40",
            "revision": "41",
            "changes": changes,
        ])
    }

    static func upsert(id: String = notificationID, resource: String = "notification", value: [String: Any]) -> [String: Any] {
        ["kind": "upsert", "sequence": 0, "resource": resource, "id": id, "value": value]
    }

    static func value(
        id: String? = notificationID,
        title: Any? = "Build failed",
        body: Any? = "api tests failed",
        terminal: Any? = terminalID,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var value: [String: Any] = [
            "session_id": "session_00000000000000000000000000000002",
            "level": "error",
            "created_at_ms": "1710000000000",
            "unread": true,
        ]
        if let id { value["id"] = id }
        if let title { value["title"] = title }
        if let body { value["body"] = body }
        if let terminal { value["terminal_id"] = terminal }
        for (key, entry) in extra { value[key] = entry }
        return value
    }

    static func events(_ line: String) -> [CloudMachineNotificationEvent] {
        if case .delta(let events) = CloudMachineNotificationEvent.parse(line: line) { return events }
        return []
    }

    // MARK: Parser

    @Test func parsesATerminalScopedNotificationUpsert() {
        let item = CloudMachineNotificationEvent.parse(line: Self.delta([Self.upsert(value: Self.value())]))
        #expect(item == .delta([
            CloudMachineNotificationEvent(
                id: Self.notificationID,
                terminalID: Self.terminalID,
                title: "Build failed",
                body: "api tests failed"
            ),
        ]))

        // No --terminal: a session-wide notification.
        let sessionWide = Self.events(Self.delta([Self.upsert(value: Self.value(terminal: nil))]))
        #expect(sessionWide.map(\.terminalID) == [nil])

        // Absent body reads as empty; the id may come from the change when the value lacks it.
        let sparse = Self.events(Self.delta([Self.upsert(value: Self.value(id: nil, body: nil))]))
        #expect(sparse.map(\.id) == [Self.notificationID])
        #expect(sparse.map(\.body) == [""])
    }

    /// Captured verbatim from a live machine's daemon (`cmux-tui --session cloud --jsonl
    /// session current events`, then `notification create --title probe --body hello
    /// --terminal <id>`), so the parser is pinned to the real wire format: envelope
    /// `sequence` and `created_at_ms` are strings, the change `sequence` is a number, and
    /// the same id appears on the change and inside `value`.
    @Test func parsesTheLineTheDaemonActuallyEmits() {
        let live = #"""
        {"cursor":{"generation":"8db1c3f1-4a98-47ae-be3c-6582ab310233","revision":"2"},"item":{"changes":[{"id":"notification_244f9a883ecb6e71fc053ff07c5d2ed5","kind":"upsert","resource":"notification","sequence":0,"value":{"body":"hello","created_at_ms":"1788346015398","id":"notification_244f9a883ecb6e71fc053ff07c5d2ed5","level":"info","session_id":"session_9ca043617db8f8ba010d0da3b107d7f3","terminal_id":"term_2f87cec324a797aa7e4c8d2eb6ebed0b","title":"probe","unread":true}}],"cursor":{"generation":"8db1c3f1-4a98-47ae-be3c-6582ab310233","revision":"2"},"kind":"delta","previous_revision":"1","revision":"2"},"protocol":"cmux.protocol/2","sequence":"2","stream_id":"stream_cc4ae70a52c7b36694c2a5e87ccf0e39","type":"stream_item"}
        """#
        #expect(CloudMachineNotificationEvent.parse(line: live) == .delta([
            CloudMachineNotificationEvent(
                id: "notification_244f9a883ecb6e71fc053ff07c5d2ed5",
                terminalID: "term_2f87cec324a797aa7e4c8d2eb6ebed0b",
                title: "probe",
                body: "hello"
            ),
        ]))
    }

    @Test func snapshotItemsNeverRaiseNotifications() {
        // Every (re)connect replays the daemon's durable ledger inside the snapshot.
        let snapshot = Self.envelope(item: [
            "kind": "snapshot",
            "cursor": ["generation": "g1", "revision": "40"],
            "reset_reason": "initial",
            "snapshot": [
                "notifications": [Self.value(), Self.value(id: Self.otherNotificationID), Self.value(id: "notification_00000000000000000000000000000003")],
                "terminals": [],
            ],
        ])
        #expect(CloudMachineNotificationEvent.parse(line: snapshot) == .snapshot)
    }

    @Test func onlyNotificationUpsertsCount() {
        let mixed = Self.delta([
            Self.upsert(id: Self.terminalID, resource: "terminal", value: ["id": Self.terminalID, "title": "Build failed", "body": "x"]),
            ["kind": "delete", "sequence": 1, "resource": "notification", "id": Self.notificationID],
            Self.upsert(id: "ws_0123456789abcdef0123456789abcdef", resource: "workspace", value: ["id": "ws_0123456789abcdef0123456789abcdef", "name": "main"]),
            ["kind": "future-change-kind", "resource": "notification", "id": Self.notificationID, "value": Self.value()],
        ])
        #expect(CloudMachineNotificationEvent.parse(line: mixed) == .delta([]))
    }

    @Test func ignoresOtherEnvelopesMalformedLinesAndUnknownKinds() {
        #expect(CloudMachineNotificationEvent.parse(line: "") == .ignored)
        #expect(CloudMachineNotificationEvent.parse(line: "not json notification") == .ignored)
        #expect(CloudMachineNotificationEvent.parse(line: "[\"notification\"]") == .ignored)
        #expect(CloudMachineNotificationEvent.parse(line: Self.envelope(item: ["kind": "delta", "changes": []], type: "stream_open")) == .ignored)
        #expect(CloudMachineNotificationEvent.parse(line: Self.envelope(item: ["kind": "end", "reason": "gap"], type: "stream_end")) == .ignored)
        #expect(CloudMachineNotificationEvent.parse(line: Self.envelope(item: ["kind": "weird", "notification": 1])) == .ignored)
        #expect(CloudMachineNotificationEvent.parse(line: Self.envelope(item: ["kind": "delta", "changes": "notification"])) == .ignored)
        #expect(CloudMachineNotificationEvent.parse(line: Self.jsonLine(["type": "stream_item", "item": "notification"])) == .ignored)
    }

    @Test func dropsMalformedChangesButKeepsTheRest() {
        let line = Self.delta([
            Self.upsert(value: Self.value(title: nil)),                                      // no title
            Self.upsert(value: Self.value(id: Self.otherNotificationID, title: 42)),         // wrong type
            Self.upsert(id: "notification_short", value: Self.value(id: "notification_short")), // bad id grammar
            Self.upsert(id: "NOTIFICATION_0123456789ABCDEF0123456789ABCDEF", value: Self.value(id: "NOTIFICATION_0123456789ABCDEF0123456789ABCDEF")),
            Self.upsert(id: "notification_00000000000000000000000000000009", value: Self.value(id: "notification_00000000000000000000000000000009", title: "kept", body: 7)),
        ])
        let events = Self.events(line)
        #expect(events.map(\.title) == ["kept"])
        #expect(events.map(\.body) == [""], "a non-string body reads as empty rather than dropping the notification")
    }

    @Test func terminalIDMustMatchTheDaemonGrammarOrIsTreatedAsSessionWide() {
        func terminal(_ candidate: Any?) -> String?? {
            Self.events(Self.delta([Self.upsert(value: Self.value(terminal: candidate))])).first.map(\.terminalID)
        }
        #expect(terminal(Self.terminalID) == .some(Self.terminalID))
        #expect(terminal("11111111-2222-3333-4444-555555555555") == .some(nil), "a UUID is never a terminal id")
        #expect(terminal("term_0123456789abcdef0123456789abcde") == .some(nil), "31 hex digits")
        #expect(terminal("term_0123456789ABCDEF0123456789ABCDEF") == .some(nil), "uppercase hex")
        #expect(terminal("ws_0123456789abcdef0123456789abcdef") == .some(nil), "wrong prefix")
        #expect(terminal(12) == .some(nil))
        #expect(terminal("../../etc/passwd") == .some(nil))
    }

    @Test func publicIDGrammar() {
        #expect(CloudMachineNotificationEvent.isPublicID(Self.terminalID, prefix: "term"))
        #expect(CloudMachineNotificationEvent.isPublicID(Self.notificationID, prefix: "notification"))
        #expect(!CloudMachineNotificationEvent.isPublicID(Self.terminalID, prefix: "notification"))
        #expect(!CloudMachineNotificationEvent.isPublicID("term_", prefix: "term"))
        #expect(!CloudMachineNotificationEvent.isPublicID("term_0123456789abcdef0123456789abcdefg", prefix: "term"))
        #expect(!CloudMachineNotificationEvent.isPublicID("term_0123456789abcdef0123456789abcdé", prefix: "term"))
    }

    @Test func neverReadsSelectorsOrActionsFromTheValue() {
        // A hostile daemon can put anything here; the event has nowhere to keep it.
        let value = Self.value(extra: [
            "workspace_id": "11111111-1111-1111-1111-111111111111",
            "surface_id": "22222222-2222-2222-2222-222222222222",
            "panel_id": "33333333-3333-3333-3333-333333333333",
            "reply_shape": "text",
            "click_action": ["reveal": "/etc/passwd"],
            "url": "https://example.invalid",
            "extra": ["command": "rm -rf /"],
        ])
        let events = Self.events(Self.delta([Self.upsert(value: value)]))
        #expect(events == [
            CloudMachineNotificationEvent(id: Self.notificationID, terminalID: Self.terminalID, title: "Build failed", body: "api tests failed"),
        ])
    }

    @Test func capsNotificationsPerDeltaAndLineSize() {
        let flood = (0..<20).map { index -> [String: Any] in
            let id = "notification_" + String(format: "%032x", index)
            return Self.upsert(id: id, value: Self.value(id: id, title: "n\(index)"))
        }
        #expect(Self.events(Self.delta(flood)).count == CloudMachineNotificationEvent.maxNotificationsPerDelta)

        let huge = Self.delta([Self.upsert(value: Self.value(body: String(repeating: "x", count: 65 * 1024)))])
        #expect(huge.utf8.count > CloudMachineNotificationEvent.maxLineBytes)
        #expect(CloudMachineNotificationEvent.parse(line: huge) == .ignored, "rejected before JSON parsing")
    }

    // MARK: Sanitizer

    @Test func stripsTerminalEscapesControlsAndInvisibleCharacters() {
        let hostile = "\u{1B}[31mALERT\u{1B}[0m\u{7}\r\nrun\u{0}: \u{1B}]8;;https://evil.invalid\u{1B}\\click\u{1B}]8;;\u{1B}\\ \u{202E}txt.exe\u{200B} \u{9B}31mok\u{85}done\t\u{FEFF}"
        let cleaned = NotificationTextSanitizer.sanitize(hostile, maxBytes: 1024)
        #expect(cleaned == "ALERT run : click txt.exe ok done")

        let events = Self.events(Self.delta([Self.upsert(value: Self.value(title: hostile, body: "line one\nline two\u{2028}three"))]))
        #expect(events.map(\.title) == ["ALERT run : click txt.exe ok done"])
        #expect(events.map(\.body) == ["line one line two three"])
    }

    @Test func truncatesOnCharacterBoundariesWithinTheByteCap() {
        let longTitle = String(repeating: "abcdefghij", count: 1024)
        let cappedTitle = Self.events(Self.delta([Self.upsert(value: Self.value(title: longTitle))])).first?.title
        #expect(cappedTitle?.utf8.count ?? .max <= CloudMachineNotificationEvent.maxTitleBytes)
        #expect(cappedTitle?.hasSuffix("\u{2026}") == true)

        // Multi-byte graphemes at the cut are never split (each flag is 8 bytes).
        let flags = String(repeating: "🇯🇵", count: 100)
        let cappedFlags = NotificationTextSanitizer.sanitize(flags, maxBytes: 128)
        #expect(cappedFlags.utf8.count <= 128)
        #expect(!cappedFlags.contains("\u{FFFD}"))
        #expect(cappedFlags.dropLast().allSatisfy { $0 == "🇯🇵" })
        #expect(cappedFlags.hasSuffix("\u{2026}"))

        #expect(NotificationTextSanitizer.sanitize("short", maxBytes: 128) == "short")
        #expect(NotificationTextSanitizer.sanitize("   ", maxBytes: 128) == "")
        #expect(NotificationTextSanitizer.sanitize("a   b\n\n c", maxBytes: 128) == "a b c")
    }

    // MARK: Gate

    private struct Clock {
        var now: UInt64 = 1_000_000_000
        func ticker() -> () -> UInt64 { let box = Box(self); return { box.value.now } }
        final class Box { var value: Clock; init(_ value: Clock) { self.value = value } }
    }

    private static func event(_ index: Int, terminal: String? = terminalID, title: String = "t", body: String = "b") -> CloudMachineNotificationEvent {
        CloudMachineNotificationEvent(
            id: "notification_" + String(format: "%032x", index),
            terminalID: terminal,
            title: title,
            body: body
        )
    }

    @Test func machineBucketAdmitsABurstThenRefillsOneTokenPerSecond() {
        let clock = Clock.Box(Clock())
        var gate = CloudMachineNotificationGate(now: { clock.value.now })
        for index in 0..<5 {
            #expect(gate.admit(machineID: "m", event: Self.event(index, body: "b\(index)")) == .allowed)
        }
        #expect(gate.admit(machineID: "m", event: Self.event(5, body: "b5")) == .machineRate)
        #expect(gate.admit(machineID: "m", event: Self.event(6, body: "b6")) == .machineRate)
        clock.value.now += 999_000_000
        #expect(gate.admit(machineID: "m", event: Self.event(7, body: "b7")) == .machineRate, "0.999 s is not a full refill interval")
        clock.value.now += 1_000_000
        #expect(gate.admit(machineID: "m", event: Self.event(8, body: "b8")) == .allowed, "1.000 s refills exactly one token")
        #expect(gate.admit(machineID: "m", event: Self.event(9, body: "b9")) == .machineRate)
    }

    @Test func oneMachinesFloodDoesNotStarveAnotherButTheFleetIsCapped() {
        let clock = Clock.Box(Clock())
        var gate = CloudMachineNotificationGate(now: { clock.value.now })
        for index in 0..<40 {
            _ = gate.admit(machineID: "loud", event: Self.event(index, body: "b\(index)"))
        }
        #expect(gate.admit(machineID: "quiet", event: Self.event(100, body: "q")) == .allowed)

        var fleetDecisions: [CloudMachineNotificationGate.Decision] = []
        for machineIndex in 0..<8 {
            for index in 0..<5 {
                fleetDecisions.append(gate.admit(machineID: "m\(machineIndex)", event: Self.event(1_000 + machineIndex * 10 + index, body: "b\(index)")))
            }
        }
        let allowed = fleetDecisions.filter { $0 == .allowed }.count
        #expect(allowed == 30 - 5 - 1, "30 fleet tokens minus the loud burst and the quiet one")
        #expect(fleetDecisions.contains(.fleetRate))
        #expect(!fleetDecisions.contains(.machineRate))
    }

    @Test func duplicateIDsAndIdenticalContentAreDropped() {
        let clock = Clock.Box(Clock())
        var gate = CloudMachineNotificationGate(now: { clock.value.now })
        #expect(gate.admit(machineID: "m", event: Self.event(1)) == .allowed)
        #expect(gate.admit(machineID: "m", event: Self.event(1)) == .duplicateID, "a replayed delta")
        #expect(gate.admit(machineID: "m", event: Self.event(2)) == .identicalContent, "same terminal/title/body inside 5 s")
        clock.value.now += 4_900_000_000
        #expect(gate.admit(machineID: "m", event: Self.event(3)) == .identicalContent)
        clock.value.now += 200_000_000
        #expect(gate.admit(machineID: "m", event: Self.event(4)) == .allowed)
        #expect(gate.admit(machineID: "m", event: Self.event(5, body: "different")) == .allowed)
        #expect(gate.admit(machineID: "other", event: Self.event(6)) == .allowed, "content windows are per machine")
    }

    // MARK: Attribution

    private static func projection(_ key: String, machine: SurfaceMachineID = machine, kind: SurfaceResourceKind = .terminal, workspace: UUID, panel: UUID) -> SurfaceProjection {
        SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: kind, key: key), workspaceID: workspace, panelID: panel)
    }

    @Test func attributesToTheProjectedPaneOnlyThroughTheHostCatalog() {
        let workspaceA = UUID(), workspaceB = UUID()
        let paneA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let paneB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let projections: Set<SurfaceProjection> = [
            Self.projection(Self.terminalID, workspace: workspaceA, panel: paneA),
            Self.projection("term_ffffffffffffffffffffffffffffffff", workspace: workspaceB, panel: paneB),
        ]
        let target = CmuxTuiSurfaceProvider.notificationTarget(
            terminalID: Self.terminalID, machine: Self.machine, projections: projections, isLive: { _ in true }
        )
        #expect(target?.workspaceID == workspaceA)
        #expect(target?.panelID == paneA)

        // The same term_ id under another machine is a different resource entirely.
        let foreign = CmuxTuiSurfaceProvider.notificationTarget(
            terminalID: Self.terminalID, machine: .cloud("other-machine"), projections: projections, isLive: { _ in true }
        )
        #expect(foreign == nil)

        // A pane that is gone (workspace closed) is not a target, even if the catalog lags.
        let dead = CmuxTuiSurfaceProvider.notificationTarget(
            terminalID: Self.terminalID, machine: Self.machine, projections: projections, isLive: { $0.panelID != paneA }
        )
        #expect(dead?.workspaceID == workspaceB, "falls back to the workspace showing the machine")
        #expect(dead?.panelID == nil)
    }

    @Test func fallsBackToTheWorkspaceShowingTheMachineOrDrops() {
        let workspace = UUID()
        let displayPane = UUID()
        let projections: Set<SurfaceProjection> = [
            Self.projection("vnc", kind: .display, workspace: workspace, panel: displayPane),
        ]
        let unprojected = CmuxTuiSurfaceProvider.notificationTarget(
            terminalID: Self.terminalID, machine: Self.machine, projections: projections, isLive: { _ in true }
        )
        #expect(unprojected?.workspaceID == workspace)
        #expect(unprojected?.panelID == nil)

        let sessionWide = CmuxTuiSurfaceProvider.notificationTarget(
            terminalID: nil, machine: Self.machine, projections: projections, isLive: { _ in true }
        )
        #expect(sessionWide?.workspaceID == workspace)

        #expect(CmuxTuiSurfaceProvider.notificationTarget(terminalID: Self.terminalID, machine: Self.machine, projections: [], isLive: { _ in true }) == nil)
        #expect(CmuxTuiSurfaceProvider.notificationTarget(terminalID: nil, machine: .cloud("elsewhere"), projections: projections, isLive: { _ in true }) == nil)
    }

    @Test func aTerminalShownTwicePrefersTheFocusedSelectedPaneDeterministically() {
        let selected = UUID(), background = UUID()
        let paneHigh = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!
        let paneLow = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let projections: Set<SurfaceProjection> = [
            Self.projection(Self.terminalID, workspace: selected, panel: paneHigh),
            Self.projection(Self.terminalID, workspace: background, panel: paneLow),
        ]
        let noFocus = CmuxTuiSurfaceProvider.notificationTarget(
            terminalID: Self.terminalID, machine: Self.machine, projections: projections, isLive: { _ in true }
        )
        #expect(noFocus?.panelID == paneLow, "catalog order when nothing is selected")

        let focused = CmuxTuiSurfaceProvider.notificationTarget(
            terminalID: Self.terminalID, machine: Self.machine, projections: projections,
            isLive: { _ in true },
            isSelectedWorkspace: { $0 == selected },
            isFocusedPanel: { $0.panelID == paneHigh }
        )
        #expect(focused?.workspaceID == selected)
        #expect(focused?.panelID == paneHigh)
    }

    // MARK: Link pipe

    @Test func oversizedLinesAreDiscardedInsteadOfBuffered() {
        let buffer = CloudLinkPipe.LineBuffer()
        let chunk = Data(repeating: 0x41, count: 1024 * 1024)
        var delivered: [String] = []
        for _ in 0..<5 {
            delivered += buffer.append(chunk)
        }
        #expect(delivered.isEmpty)
        delivered += buffer.append(Data("still the same line\nok\n".utf8))
        #expect(delivered == ["ok"], "the oversized line is dropped up to its newline; the next line survives")
        delivered += buffer.append(Data("tail".utf8))
        #expect(buffer.flush() == "tail")

        // Under the cap, long lines still arrive whole.
        let underCap = CloudLinkPipe.LineBuffer()
        let big = Data(repeating: 0x42, count: 3 * 1024 * 1024)
        #expect(underCap.append(big).isEmpty)
        #expect(underCap.append(Data("\n".utf8)).map(\.utf8.count) == [3 * 1024 * 1024])
    }
}
