import CnxModel
import CnxTransport
import Foundation
import Testing
@testable import CnxLive

/// V5-5 / T-TABS-08: closing a terminal tab on the phone ends its Mac session
/// at once. `close-surface` only detaches the terminal (the daemon reaps a
/// tab-less terminal after its grace period, so the Mac listed it `running`
/// 50 s after the close); the phone has no undo, so it ends the terminal with
/// `close-terminal` right after the tab closes, unless another tab still
/// shows that terminal.
@MainActor
@Suite struct TabCloseEndsTerminalTests {
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        func append(_ object: [String: Any]) { lock.withLock { items.append(object) } }
        var all: [[String: Any]] { lock.withLock { items } }
        var mutations: [[String: Any]] {
            all.filter { ["close-surface", "close-terminal"].contains($0["cmd"] as? String ?? "") }
        }
    }

    /// wk1: s10 (pty, term_a), s11 (pty, term_b), s12 (remote-terminal, term_r);
    /// wk2: s13 shows term_b too.
    nonisolated static let tree = #"""
    {"workspaces":[
      {"id":1,"key":"wk1","name":"main","screens":[{"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[
        {"surface":10,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_a","terminal_incarnation":"inc_a"},
        {"surface":11,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_b"},
        {"surface":12,"kind":"remote-terminal","title":"ssh","dead":false,"terminal_id":"term_r"}]}]}]},
      {"id":2,"key":"wk2","name":"other","screens":[{"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[
        {"surface":13,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_b"}]}]}]}
    ]}
    """#

    nonisolated static func daemon(_ seen: Requests) -> MockMacLink {
        MockMacLink { _, data in
            data.split(separator: 0x0A).map { request -> Data in
                let object = try! JSONSerialization.jsonObject(with: Data(request)) as! [String: Any]
                seen.append(object)
                let id = object["id"] as! String
                let line: String
                switch object["cmd"] as? String ?? "" {
                case "list-workspaces":
                    // One line: the client splits replies on newlines.
                    line = #"{"id":"\#(id)","ok":true,"data":\#(tree.replacingOccurrences(of: "\n", with: ""))}"#
                case "list-agents":
                    line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                default:
                    line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                }
                return Data(line.utf8) + Data([0x0A])
            }
        }
    }

    func connected(_ seen: Requests) async throws -> (LiveWorkspaceCreationBackend, WorkspaceSync) {
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        await sync.bind(try await Self.daemon(seen).openChannel(service: "daemon", args: [:]), macID: "m")
        return (LiveWorkspaceCreationBackend(sync: sync, link: controller), sync)
    }

    func tab(_ id: String, in sync: WorkspaceSync) throws -> (WorkspaceTab, Workspace) {
        let workspace = try #require(sync.tree?.workspaces.first { ws in ws.tabs.contains { $0.id == id } })
        return (try #require(workspace.tabs.first { $0.id == id }), workspace)
    }

    @Test func closingATerminalTabEndsItsTerminalOnTheMac() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (tab, workspace) = try tab("s10", in: sync)
        try await backend.closeTab(tab, in: workspace)
        let mutations = seen.mutations
        #expect(mutations.map { $0["cmd"] as? String } == ["close-surface", "close-terminal"])
        #expect(mutations.first?["surface"] as? Int == 10)
        #expect(mutations.last?["terminal_id"] as? String == "term_a")
        #expect(mutations.last?["terminal_incarnation"] as? String == "inc_a")
    }

    @Test func aTerminalShownInAnotherTabKeepsRunning() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (tab, workspace) = try tab("s11", in: sync)
        try await backend.closeTab(tab, in: workspace)
        #expect(seen.mutations.map { $0["cmd"] as? String } == ["close-surface"])
    }

    @Test func aRemoteTerminalIsOnlyDetached() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (tab, workspace) = try tab("s12", in: sync)
        try await backend.closeTab(tab, in: workspace)
        #expect(seen.mutations.map { $0["cmd"] as? String } == ["close-surface"])
    }
}
