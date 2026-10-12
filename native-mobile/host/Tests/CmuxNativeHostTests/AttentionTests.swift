import Foundation
import Testing
import CmuxNativeLink
import CmuxNativeWire
@testable import CmuxNativeHost

private func event(_ id: String, _ kind: AttentionEvent.Kind, surface: Int? = 3, title: String = "t", body: String = "b") -> AttentionEvent {
    AttentionEvent(id: id, kind: kind, title: title, body: body, surface: surface, createdAt: 0)
}

@Suite struct AttentionDeduperTests {
    @Test func sameIDPostsOnce() {
        var d = AttentionDeduper()
        do { let r = d.admit(event("n-1", .question), now: 0); #expect(r) }
        do { let r = d.admit(event("n-1", .question), now: 500); #expect(!r) }
    }

    @Test func agentBlockedAndItsNotificationPostOnce() {
        var d = AttentionDeduper()
        do { let r = d.admit(event("n-9", .permission, title: "Claude needs permission"), now: 100); #expect(r) }
        // The agent's `blocked` alert lands 1.5 s later for the same surface.
        do { let r = d.admit(event("a-3-1", .question, title: "Claude needs your input", body: ""), now: 101.5); #expect(!r) }
        // Another surface is independent.
        do { let r = d.admit(event("a-4-1", .question, surface: 4), now: 101.5); #expect(r) }
    }

    @Test func differentClassesOnOneSurfaceBothPost() {
        var d = AttentionDeduper()
        do { let r = d.admit(event("n-1", .question), now: 0); #expect(r) }
        do { let r = d.admit(event("n-2", .done, title: "done"), now: 2); #expect(r) }
    }

    @Test func classWindowExpires() {
        var d = AttentionDeduper(window: 10, repeatWindow: 0)
        do { let r = d.admit(event("n-1", .question, body: "one"), now: 0); #expect(r) }
        do { let r = d.admit(event("n-2", .question, body: "two"), now: 9); #expect(!r) }
        do { let r = d.admit(event("n-3", .question, body: "three"), now: 25); #expect(r) }
    }

    @Test func identicalTextRepeatsAreDroppedForTwoMinutes() {
        var d = AttentionDeduper(window: 1, repeatWindow: 120)
        do { let r = d.admit(event("n-1", .notice, title: "Build", body: "green"), now: 0); #expect(r) }
        do { let r = d.admit(event("n-2", .notice, title: "Build", body: "green"), now: 60); #expect(!r) }
        do { let r = d.admit(event("n-3", .notice, title: "Build", body: "green"), now: 130); #expect(r) }
    }

    @Test func markSeenSuppressesLaterReplays() {
        var d = AttentionDeduper()
        d.markSeen("n-5")
        do { let r = d.admit(event("n-5", .done), now: 0); #expect(!r) }
    }
}

@Suite struct AttentionTrackerTests {
    let ws: (Int) -> String? = { $0 == 7 ? "cmux" : nil }

    @Test func workingThenBlockedThenDone() {
        var t = AttentionTracker()
        let working = t.agentChanged(["event": "agent-changed", "surface": 7, "state": "working", "agent": "claude"], workspace: ws, nowMs: 1000)
        #expect(working.activity == ActivityUpdate(state: .working, surface: 7, agent: "claude", workspace: "cmux", startedAt: 1000))
        #expect(working.heldAlert == nil)

        let blocked = t.agentChanged(["event": "agent-changed", "surface": 7, "state": "blocked"], workspace: ws, nowMs: 5000)
        #expect(blocked.activity?.state == .needsInput)
        #expect(blocked.activity?.startedAt == 1000)
        #expect(blocked.heldAlert?.kind == .question)
        #expect(blocked.heldAlert?.title == "Claude needs your input")
        #expect(blocked.heldAlert?.workspace == "cmux")

        let resumed = t.agentChanged(["event": "agent-changed", "surface": 7, "state": "working"], workspace: ws, nowMs: 8000)
        #expect(resumed.activity?.startedAt == 1000, "resuming after input keeps the start time")

        let done = t.agentChanged(["event": "agent-changed", "surface": 7, "state": "done"], workspace: ws, nowMs: 9000)
        #expect(done.activity?.state == .done)
        #expect(done.heldAlert?.kind == .done)
        #expect(done.heldAlert?.title == "Claude finished")
    }

    @Test func repeatedStateIsSilent() {
        var t = AttentionTracker()
        _ = t.agentChanged(["surface": 7, "state": "working"], workspace: ws, nowMs: 0)
        let again = t.agentChanged(["surface": 7, "state": "working"], workspace: ws, nowMs: 10)
        #expect(again == AttentionTracker.AgentOutcome())
    }

    @Test func idleWithoutWorkIsSilent() {
        var t = AttentionTracker()
        let idle = t.agentChanged(["surface": 7, "state": "idle"], workspace: ws, nowMs: 0)
        #expect(idle.activity == nil && idle.heldAlert == nil)
    }

    @Test func notificationClassification() throws {
        let t = AttentionTracker()
        let e = try #require(t.alert(forNotification: ["event": "notification", "id": 12, "title": "Claude Code", "body": "Claude needs your permission to use Bash", "surface": 7], workspace: ws, nowMs: 0))
        #expect(e.id == "n-12")
        #expect(e.kind == .permission)
        #expect(e.agent == "claude")
        #expect(e.workspace == "cmux")
        let err = try #require(t.alert(forNotification: ["id": "x", "title": "Build", "body": "failed", "level": "error"], workspace: ws, nowMs: 0))
        #expect(err.kind == .error)
    }
}

@Suite struct TerminalTextParserTests {
    @Test func claudePermissionMenu() {
        let text = """
        > refactor the signal router
        ⏺ I'll update the router.
        ╭──────────────────────────────╮
        │ Do you want to make this edit?│
        │ ❯ 1. Yes                      │
        │   2. Yes, and don't ask again │
        │   3. No, and tell Claude what to do differently (esc) │
        ╰──────────────────────────────╯
        """
        let r = TerminalTextParser.parse(text)
        #expect(r.lastPrompt == "refactor the signal router")
        #expect(r.options.map(\.key) == ["1", "2", "3"])
        #expect(r.options.first?.label == "Yes")
        #expect(r.lastReply == "I'll update the router.")
    }

    @Test func noMenu() {
        #expect(TerminalTextParser.parse("$ ls\nfoo bar\n").options.isEmpty)
    }
}

@Suite struct AttentionActionTests {
    func publisher() -> AttentionPublisher {
        AttentionPublisher(
            configuration: .init(apiBase: URL(string: "https://example.invalid")!, hostID: "h", hostSecret: "s"),
            locator: DaemonSocketLocator(explicitPath: "/nonexistent"), presence: PresenceBoard(), poster: { _ in })
    }

    @Test func actionsOnlyForPostedEventsAndTheirSurface() async {
        let p = publisher()
        var e = event("n-1", .permission, surface: 7)
        e.options = [AttentionOption(key: "1", label: "Yes"), AttentionOption(key: "2", label: "Yes, always"), AttentionOption(key: "3", label: "No")]
        await p.offer(e)
        #expect(await p.resolve(["event_id": "n-1", "surface": 7, "type": "allow"]) == .sent(surface: 7, keys: ["1"], text: nil))
        #expect(await p.resolve(["event_id": "n-1", "surface": 7, "type": "deny"]) == .sent(surface: 7, keys: ["3"], text: nil))
        #expect(await p.resolve(["event_id": "n-1", "surface": 7, "type": "option", "key": "2"]) == .sent(surface: 7, keys: ["2"], text: nil))
        #expect(await p.resolve(["event_id": "n-1", "surface": 7, "type": "reply", "text": "use pnpm"]) == .sent(surface: 7, keys: ["enter"], text: "use pnpm"))
        // Wrong surface, unknown event, a key that was not offered.
        if case .sent = await p.resolve(["event_id": "n-1", "surface": 8, "type": "allow"]) { Issue.record("wrong surface accepted") }
        if case .sent = await p.resolve(["event_id": "n-404", "surface": 7, "type": "allow"]) { Issue.record("unknown event accepted") }
        if case .sent = await p.resolve(["event_id": "n-1", "surface": 7, "type": "option", "key": "9"]) { Issue.record("unoffered key accepted") }
    }

    @Test func visiblePhoneHoldsAlerts() async {
        let posted = PostLog()
        let presence = PresenceBoard()
        let p = AttentionPublisher(
            configuration: .init(apiBase: URL(string: "https://example.invalid")!, hostID: "h", hostSecret: "s"),
            locator: DaemonSocketLocator(explicitPath: "/nonexistent"), presence: presence, poster: { await posted.add($0) })
        presence.set(peer: "sid1", visible: true)
        await p.offer(event("n-1", .question))
        #expect(await posted.count == 0)
        presence.clear(peer: "sid1")
        await p.offer(event("n-2", .done, surface: 9))
        #expect(await posted.count == 1)
    }
}

actor PostLog {
    var bodies: [Data] = []
    var count: Int { bodies.count }
    func add(_ d: Data) { bodies.append(d) }
}

@Suite struct PresenceServiceTests {
    @Test func presenceSetOverSvc() async throws {
        let services = HostServices()
        let uploads = UploadService(guardrail: services.guardrail, uploadsRoot: nil)
        let r = await services.respond(to: Data(#"{"id":1,"method":"presence.set","params":{"visible":true}}"#.utf8), uploads: uploads, peer: "p1")
        #expect(r.ok)
        #expect(services.presence.anyVisible)
        _ = await services.respond(to: Data(#"{"id":2,"method":"presence.set","params":{"visible":false}}"#.utf8), uploads: uploads, peer: "p1")
        #expect(!services.presence.anyVisible)
        let bad = await services.respond(to: Data(#"{"id":3,"method":"presence.set","params":{}}"#.utf8), uploads: uploads, peer: "p1")
        #expect(!bad.ok)
    }

    @Test func actionSignalMessageDecodes() throws {
        let m = try SignalMessage(jsonString: #"{"t":"action","from":"phone","user_id":"u1","action":{"event_id":"n-1","surface":7,"type":"allow"}}"#)
        #expect(m.t == .action)
        #expect(m.userID == "u1")
        #expect(m.action?["surface"]?.intValue == 7)
    }
}
