import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Raw OSC machine payload classifier")
struct RawOSCMachinePayloadClassifierTests {
    static let machinePayloads: [(String, String)] = [
        ("scheme://target", "Completed"),
        ("custom+notify.v1://target", "Completed"),
        ("SCHEME://target", "Completed"),
        ("a-b://target", "Completed"),
        ("Task", #"{"v":1,"agent":"claude","event":"stop","query":"<task-notification>"}"#),
        ("Task", " \n [1, {\"event\": \"stop\"}]"),
        ("Task", "{}"),
        ("Task", "[]"),
        ("Task", String((" \n { \"query\": \"" + String(repeating: "x", count: 300)).prefix(255))),
        ("Task", String((" [ { \"query\": \"" + String(repeating: "x", count: 300)).prefix(255))),
        ("Task", " [ [1, 2,"),
        ("Task", " [ \"unfinished"),
        ("Task", " [ 1, unfinished"),
        ("Task", " [-12.5e+2, unfinished"),
        ("Task", " [0.25, unfinished"),
        ("Task", " [1e-3, unfinished"),
        ("Task", "[1]"),
        ("Task", "[-12.5e+2]"),
        ("Task", "[true]"),
        ("Task", "[false]"),
        ("Task", "[null]"),
        ("Task", " [ true, unfinished"),
        ("Task", " [ null, unfinished"),
        ("Task", "[1 , unfinished"),
        ("Task", "[true \n , unfinished"),
        // A nested container may close while the outer one is cut off.
        ("Task", #"{"v":1,"meta":{"a":1},"query":"unfinished"#),
        ("Task", #"[{"event":"stop"},{"event":"#),
        ("Task", #"{"query":"a } inside a string","more":"#),
        // Invisible leading characters do not hide the payload's shape.
        ("Task", "\u{200B}{\"v\":1,\"event\":\"stop\"}"),
        ("Task", "\u{FEFF}[{\"event\":"),
        ("Task", "\u{200E}{\"v\":1,\"event\":\"stop\"}"),
        // A complete object followed by more output is still machine output.
        ("Task", "{\"a\":1}\n{\"b\":2}"),
        ("Task", #"{"v":1,"event":"stop"};extra"#)
    ] + ((0..<0x20).filter { ![9, 10, 13].contains($0) } + Array(0x7f...0x9f)).flatMap { value in
        let control = String(UnicodeScalar(value)!)
        return [("Task" + control, "Completed"), ("Task", "Completed" + control)]
    }

    static let humanPayloads: [(String, String)] = [
        ("Build", "Completed"),
        ("", "Completed"),
        ("Build", ""),
        ("Build\tstatus\nDone", "First line\nSecond line\tDetails\r\nDone"),
        ("Build", "[build] completed"),
        ("Build", "{not JSON}"),
        ("Build", "[1] done"),
        ("Build", "[0.25] done"),
        ("Build", "[-12] done"),
        ("Build", "See https://example.com/results"),
        ("Build", String(repeating: "x", count: 4096)),
        ("Build", "["),
        ("Build", "{"),
        ("Build", "[1"),
        ("Build", "[true story]"),
        ("Build", "[nullish, value]"),
        ("Build", "[1st, done]"),
        ("Build", "[1.2.3, done]"),
        ("Build", "[01, done]"),
        ("Build", "[+1, done]"),
        ("Build", "[1e, done]"),
        ("1scheme://target", "Completed"),
        ("See https://example.com/results", "Completed"),
        (" scheme://target", "Completed"),
        // Closed brackets followed by more text are labels, not truncated JSON.
        ("Task", " { } trailing"),
        ("Task", " [ ] trailing"),
        ("Task", " [ false] trailing"),
        ("Task", "\t[null] trailing"),
        ("Todo", "[ ] review PR #42"),
        ("Todo", "[ ] buy milk"),
        ("Todo", "[] no items"),
        ("Todo", "{} placeholder"),
        ("Build", "[1, 2] round"),
        ("Build", "[1,2,3] stages done"),
        ("Note", #"["x"] means quoted"#),
        ("Form", #"{"name"} is required"#),
        ("Note", "\u{200F}\u{05E9}\u{05DC}\u{05D5}\u{05DD} done")
    ]

    @Test(arguments: machinePayloads)
    func rejectsMachinePayload(title: String, body: String) {
        #expect(GhosttyDesktopNotificationRequest.isMachinePayload(title: title, body: body))
    }

    @Test(arguments: humanPayloads)
    func preservesHumanText(title: String, body: String) {
        #expect(!GhosttyDesktopNotificationRequest.isMachinePayload(title: title, body: body))
    }
}

@Suite("Raw OSC machine payload admission", .serialized, .exclusiveAppContext)
@MainActor
struct RawOSCMachinePayloadTests {
    @Test(arguments: RawOSCMachinePayloadClassifierTests.machinePayloads)
    func dropsMachinePayloadBeforeAdmission(title: String, body: String) async throws {
        let fixture = try AgentNotificationRegressionTests().makeFixture()
        defer { fixture.restore() }

        await fixture.store.addDesktopNotificationResolvingHooks(
            tabId: fixture.source.id, surfaceId: fixture.panelId, hookDirectory: nil,
            title: title, body: body
        )

        #expect(fixture.store.notifications.isEmpty)
        #expect(!fixture.store.hasUnreadNotification(forTabId: fixture.source.id, surfaceId: fixture.panelId))
        #expect(!fixture.store.hasPendingNotification(forTabId: fixture.source.id, surfaceId: fixture.panelId))
    }

    @Test(arguments: RawOSCMachinePayloadClassifierTests.humanPayloads)
    func admitsHumanText(title: String, body: String) async throws {
        let fixture = try AgentNotificationRegressionTests().makeFixture()
        defer { fixture.restore() }

        await fixture.store.addDesktopNotificationResolvingHooks(
            tabId: fixture.source.id, surfaceId: fixture.panelId, hookDirectory: nil,
            title: title, body: body
        )

        #expect(fixture.store.notifications.count == 1)
        #expect(fixture.store.notifications.first?.body == body)
    }
}
