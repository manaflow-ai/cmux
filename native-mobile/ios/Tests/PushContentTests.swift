import Foundation
import Testing
import UserNotifications
@testable import CmuxNative

struct PushContentTests {
    let userInfo: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Claude needs your permission", "body": "Edit signal.ts?"]],
        "cmux": [
            "host_id": "h1", "host_name": "Mac", "event_id": "n-1", "kind": "permission", "surface": 7,
            "workspace": "cmux", "agent": "claude", "quote": "forward actions",
            "options": [["key": "1", "label": "Yes"], ["key": "2", "label": "Yes, always"], ["key": "3", "label": "No"]],
        ] as [String: Any],
    ]

    @Test func parsesTheCmuxBlock() throws {
        let p = try #require(PushPayload(userInfo: userInfo))
        #expect(p.hostID == "h1")
        #expect(p.eventID == "n-1")
        #expect(p.surface == 7)
        #expect(p.options.map(\.key) == ["1", "2", "3"])
        #expect(p.agentDisplayName == "Claude")
        #expect(PushPayload(userInfo: ["aps": [:]]) == nil)
    }

    @Test func enrichAddsSubtitleAndQuote() throws {
        let p = try #require(PushPayload(userInfo: userInfo))
        let content = UNMutableNotificationContent()
        content.body = "Edit signal.ts?"
        PushCategory.enrich(content, payload: p)
        #expect(content.subtitle == "Claude · cmux · Mac")
        #expect(content.body == "“forward actions”\nEdit signal.ts?")
        #expect(content.targetContentIdentifier == "surface:h1:7")
    }

    @Test func choiceCategoryIsStableAndCarriesEachOption() throws {
        let p = try #require(PushPayload(userInfo: userInfo))
        let a = PushCategory.choices(p.options)
        let b = PushCategory.choices(p.options)
        #expect(a.identifier == b.identifier)
        #expect(a.identifier.hasPrefix("FEED_QUESTION."))
        #expect(a.actions.map(\.identifier) == ["option:1", "option:2", "option:3", "reply"])
        #expect(a.actions[2].options.contains(.destructive))
    }

    @Test func liveActivityStateDecodesWorkerJSON() throws {
        let json = #"{"state":"needs_input","startedAt":1760000000,"detail":"Needs your input"}"#
        let state = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: Data(json.utf8))
        #expect(state.state == .needsInput)
        #expect(state.startDate == Date(timeIntervalSince1970: 1_760_000_000))
    }
}
