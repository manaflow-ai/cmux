import CNCore
import CNMockHost
import CNTransport
import Foundation
import Testing

@Suite struct LayoutTests {
    @Test func demoLayoutHasSplitWorkspacesAndFocusUpdates() async throws {
        let host = MockHost(options: MockHost.Options(speed: 40))
        let client = try await connectedClient(host)
        let info = try await client.hello(testClient)
        #expect(info.capabilities.contains(HostCapability.layout.rawValue))
        let layout = try await client.layout()
        #expect(layout.workspaces.count == 2)
        let a = try #require(layout.workspaces.first)
        #expect(a.panes.count == 3)
        #expect(a.panes[0].tabs.count == 3 && a.panes[0].rect == LayoutRect(x: 0, y: 0, w: 0.5, h: 1))
        #expect(layout.workspaces[1].panes[0].tabs.contains { !$0.streamable })

        let pane = a.panes[0]
        let target = pane.tabs[1]
        let changed = client.events(topic: HostTopic.layoutChanged.rawValue)
        try await client.focusLayoutTab(paneId: pane.id, tabId: target.id)
        let event = try await first(changed) { _ in true }
        let updated = try event.decode(LayoutResult.self).layout
        #expect(updated.workspaces[0].panes[0].focusedTabId == target.id)
        #expect(updated.workspaces[0].activePaneId == pane.id)
    }

    @Test func layoutNodeRoundTrips() throws {
        let tab = LayoutTab(id: "t", kind: .browser, title: "x", refId: "r", streamable: false, url: "https://a", focused: true)
        let l = MacLayout(workspaces: [LayoutWorkspace(id: "w", title: "W", active: true, activePaneId: "p",
                                                       panes: [LayoutPane(id: "p", rect: LayoutRect(x: 0, y: 0, w: 1, h: 1), tabs: [tab], focusedTabId: "t", active: true)])])
        let data = try JSONEncoder().encode(LayoutResult(layout: l))
        #expect(try JSONDecoder().decode(LayoutResult.self, from: data).layout == l)
        let unknown = try JSONDecoder().decode(LayoutTab.self, from: Data(#"{"id":"t","kind":"canvas","title":"c","streamable":true,"focused":false}"#.utf8))
        #expect(unknown.kind == .other)
    }
}
