import Foundation
import Testing
#if RAW_OSC_CLASSIFIER_ONLY
@testable import RawOSCClassifier
#elseif canImport(cmux_DEV)
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
        ("Task", " { } trailing"),
        ("Task", " [ ] trailing"),
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
        ("Task", " [ false] trailing"),
        ("Task", " [ null, unfinished"),
        ("Task", "\t[null] trailing"),
        ("Task", "[1 , unfinished"),
        ("Task", "[true \n , unfinished")
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
        (" scheme://target", "Completed")
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

#if !RAW_OSC_CLASSIFIER_ONLY
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
#endif
