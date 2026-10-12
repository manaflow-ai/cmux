@testable import CNBrowserUI
import CNCore
import CNMockHost
import CNTransport
import Foundation
import Testing

private func tab(back: Bool, forward: Bool) -> BrowserTab {
    var t = BrowserTab(id: "t", url: "https://cmux.dev/a", title: "A")
    t.canGoBack = back
    t.canGoForward = forward
    return t
}

struct BrowserHistoryTests {
    /// The capsule's state follows the tab's history flags.
    @Test func capsuleFollowsHistory() {
        let none = BackForwardState(tab: tab(back: false, forward: false), local: false, sidesVisible: true, editing: false)
        #expect(none.visible && !none.backEnabled && !none.forwardShown)
        let back = BackForwardState(tab: tab(back: true, forward: false), local: false, sidesVisible: true, editing: false)
        #expect(back.backEnabled && !back.forwardShown)
        let both = BackForwardState(tab: tab(back: true, forward: true), local: false, sidesVisible: true, editing: false)
        #expect(both.backEnabled && both.forwardShown)
        let fwdOnly = BackForwardState(tab: tab(back: false, forward: true), local: false, sidesVisible: true, editing: false)
        #expect(!fwdOnly.backEnabled && fwdOnly.forwardShown)
    }

    /// Terminals, the collapsed pill and address editing hide the controls.
    @Test func hiddenWhereThereIsNoHistory() {
        #expect(!BackForwardState(tab: tab(back: true, forward: true), local: true, sidesVisible: true, editing: false).visible)
        #expect(!BackForwardState(tab: tab(back: true, forward: true), local: true, sidesVisible: true, editing: false).forwardShown)
        #expect(!BackForwardState(tab: tab(back: true, forward: false), local: false, sidesVisible: false, editing: false).backEnabled)
        #expect(!BackForwardState(tab: tab(back: true, forward: false), local: false, sidesVisible: true, editing: true).backEnabled)
        #expect(!BackForwardState(tab: nil, local: false, sidesVisible: true, editing: false).backEnabled)
    }

    /// A step sends browser.back / browser.forward for the tab, and the
    /// host's browser.tab event brings the new history flags back.
    @Test func stepSendsTheRPCAndHistoryFlows() async throws {
        let host = MockHost(options: MockHost.Options(speed: 40))
        let client = HostClient(transport: host.connectLoopback(), defaultTimeout: .seconds(10))
        _ = try await client.hello(ClientInfo(name: "tests", version: "1", platform: "macOS"))
        let first = try #require(try await client.listTabs().first)
        #expect(BrowserHistoryStep.back.method.rawValue == "browser.back")
        #expect(BrowserHistoryStep.forward.method.rawValue == "browser.forward")

        try await client.navigate(first.id, to: "https://example.com/next")
        var t = try #require(try await client.listTabs().first { $0.id == first.id })
        #expect(t.canGoBack)

        try await BrowserHistoryStep.back.send(first.id, on: client)
        t = try #require(try await client.listTabs().first { $0.id == first.id })
        #expect(t.url == first.url && t.canGoForward)

        try await BrowserHistoryStep.forward.send(first.id, on: client)
        t = try #require(try await client.listTabs().first { $0.id == first.id })
        #expect(t.canGoBack && !t.canGoForward)
    }
}
