import CmuxiOSFeatureKit
import Foundation
@testable import CmuxiOSSearchCore
import Testing

@Suite("Search providers")
struct SearchProviderTests {
    static let mac = HostID("h_mac")

    static var hosts: [HostWorkspaces] {
        let surfaces = [
            WorkspaceSurface(id: "tab_1", kind: .terminal, title: "npm run dev", terminalID: "term_1",
                             status: .running, preview: "ready on :3000"),
            WorkspaceSurface(id: "tab_2", kind: .browser, title: "Preview", url: URL(string: "https://localhost.example/app")),
        ]
        let workspace = WorkspaceSummary(
            id: "ws_api", hostID: mac, title: "api", status: .waitingForInput, paneCount: 1, unreadCount: 2,
            panes: [WorkspacePane(id: "pane_1", surfaces: surfaces)], preview: "Allow edit?",
            group: WorkspaceGroup(id: "g", name: "Backend"))
        return [HostWorkspaces(hostID: mac, hostName: "Studio", isReachable: false, workspaces: [workspace])]
    }

    @Test func workspacesAndTabsBecomeItems() throws {
        let items = WorkspaceSearchProvider.items(for: Self.hosts)
        #expect(items.map(\.id) == ["ws:h_mac/ws_api", "tab:h_mac/ws_api/tab_1", "tab:h_mac/ws_api/tab_2"])
        let workspace = items[0]
        #expect(workspace.category == .workspaces)
        #expect(workspace.subtitle == "Studio · Allow edit?")
        #expect(workspace.badge == "Needs input")
        #expect(workspace.boost == 10)
        #expect(workspace.isDimmed)
        #expect(workspace.destination == .workspace(host: Self.mac, workspace: "ws_api", surface: nil))
        let tab = items[1]
        #expect(tab.category == .tabs)
        #expect(tab.symbolName == "terminal")
        #expect(tab.destination == .workspace(host: Self.mac, workspace: "ws_api", surface: "tab_1"))
    }

    @Test func workspaceIsFoundByGroupTabTitleAndPreview() {
        let items = WorkspaceSearchProvider.items(for: Self.hosts)
        let ranker = SearchRanker()
        #expect(ranker.rank(items, query: SearchQuery("backend")).flat.map(\.id) == ["ws:h_mac/ws_api"])
        #expect(ranker.rank(items, query: SearchQuery("3000")).flat.map(\.id) == ["tab:h_mac/ws_api/tab_1"])
        #expect(ranker.rank(items, query: SearchQuery("localhost")).flat.map(\.id) == ["tab:h_mac/ws_api/tab_2"])
    }

    @Test func feedSkipsArchivedAndSnoozedAndBoostsNeedsInput() {
        let now = Date(timeIntervalSince1970: 0)
        let question = FeedItem(id: "q", kind: .question(FeedQuestion(question: "Which branch?")), source: "Claude Code · api",
                                agent: "claude", title: "Question", body: "\n  Which branch?\nmore", createdAt: now)
        let archived = FeedItem(id: "a", kind: .done, source: "x", title: "Old", createdAt: now, archivedAt: now)
        let snoozed = FeedItem(id: "s", kind: .done, source: "x", title: "Later", createdAt: now, snoozedUntil: now)
        let read = FeedItem(id: "r", kind: .done, source: "x", title: "Done", createdAt: now, readAt: now)
        let items = FeedSearchProvider.items(for: [question, archived, snoozed, read])
        #expect(items.map(\.id) == ["feed:q", "feed:r"])
        #expect(items[0].boost == 50)
        #expect(items[0].badge == "Needs input")
        #expect(items[0].subtitle == "Claude Code · api · Which branch?")
        #expect(items[1].boost == 0)
        #expect(items[1].symbolName == "checkmark.circle")
        #expect(SearchRanker().rank(items, query: SearchQuery("claude")).flat.map(\.id) == ["feed:q"])
    }

    @Test func hostsDescribeEndpoints() {
        let ssh = HostRecord(id: HostID("ssh1"), name: "build box",
                             kind: .ssh(endpoint: HostEndpoint(address: "10.0.0.2", port: 2222, user: "me"), jumpHost: nil),
                             reachability: .unreachable(reason: nil))
        let mac = HostRecord(id: HostID("mac"), name: "Studio", kind: .pairedMac, reachability: .unknown)
        let items = [ssh, mac].map(HostSearchProvider.item(for:))
        #expect(items[0].subtitle == "SSH · me@10.0.0.2:2222")
        #expect(items[0].destination == .host(HostID("ssh1"), .ssh))
        #expect(items[0].isDimmed)
        #expect(items[1].destination == .host(HostID("mac"), .pairedMac))
        #expect(!items[1].isDimmed)
        #expect(SearchRanker().rank(items, query: SearchQuery("10.0")).flat.map(\.id) == ["host:ssh1"])
    }

    @Test func providerStreamsMapOwnerSnapshots() async {
        let store = MockHostsStore(hosts: [HostRecord(id: HostID("m"), name: "Studio", kind: .pairedMac, reachability: .unknown)])
        let stream = await HostSearchProvider(store: store).items()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.map(\.id) == ["host:m"])
        _ = try? await store.add(HostDraft(name: "box", kind: .ssh(endpoint: HostEndpoint(address: "b"), jumpHost: nil)),
                                 key: IntentKey())
        #expect(await iterator.next()?.map(\.title) == ["Studio", "box"])
    }
}
