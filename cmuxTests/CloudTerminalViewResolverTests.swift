import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Exact Cloud terminal views")
struct CloudTerminalViewResolverTests {
    @Test
    func twoViewsOfOneTerminalResolveTheirOwnSurfaceInOneBatch() async throws {
        let runner = ViewRunner(snapshot: try snapshot(tabs: ["tab_a", "tab_b"]), tree: try tree(tabs: [
            ["tab_resource_id": "tab_a", "terminal_resource_id": "term_live", "surface": 17],
            ["tab_resource_id": "tab_b", "terminal_resource_id": "term_live", "surface": 23]
        ]))
        let resolved = await CloudTerminalViewResolver(commandRunner: runner, socketPath: "/fixture")
            .resolve(terminalByTab: ["tab_a": "term_live", "tab_b": "term_live"])
        #expect(resolved == ["tab_a": .resolved(17), "tab_b": .resolved(23)])
        #expect(await runner.calls == 2)
    }

    @Test
    func aRemovedTabNeverBorrowsItsLiveSiblingAndCanRecoverOnTheNextRead() async throws {
        let runner = ViewRunner(snapshot: try snapshot(tabs: ["tab_b"]), tree: try tree(tabs: [
            ["tab_resource_id": "tab_b", "terminal_resource_id": "term_live", "surface": 23]
        ]))
        let resolver = CloudTerminalViewResolver(commandRunner: runner, socketPath: "/fixture")
        let first = await resolver.resolve(terminalByTab: ["tab_a": "term_live"])
        guard case .retryable = first["tab_a"] else { Issue.record("missing tab must remain retryable"); return }
        #expect(await runner.calls == 1, "do not ask for another tab's surface")
        await runner.replace(snapshot: try snapshot(tabs: ["tab_a"]), tree: try tree(tabs: [
            ["tab_resource_id": "tab_a", "terminal_resource_id": "term_live", "surface": 41]
        ]))
        #expect(await resolver.resolve(terminalByTab: ["tab_a": "term_live"])["tab_a"] == .resolved(41))
    }

    @Test
    func changedTerminalOwnershipBetweenSnapshotAndTreeIsRejected() async throws {
        let runner = ViewRunner(snapshot: try snapshot(tabs: ["tab_a"]), tree: try tree(tabs: [
            ["tab_resource_id": "tab_a", "terminal_resource_id": "term_other", "surface": 17]
        ]))
        let result = await CloudTerminalViewResolver(commandRunner: runner, socketPath: "/fixture")
            .resolve(terminalByTab: ["tab_a": "term_live"])
        guard case .retryable = result["tab_a"] else { Issue.record("changed ownership must be rejected"); return }
    }

    private func snapshot(tabs: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "workspaces": [["id": "ws_a"]],
            "screens": [["id": "screen_a", "workspace_id": "ws_a"]],
            "panes": [["id": "pane_a", "screen_id": "screen_a"]],
            "tabs": tabs.map { ["id": $0, "pane_id": "pane_a", "content_kind": "terminal", "content_id": "term_live"] },
            "terminals": [["id": "term_live", "lifecycle": "running"]], "browsers": [], "agents": []
        ])
    }

    private func tree(tabs: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["workspaces": [["screens": [["panes": [["tabs": tabs]]]]]]])
    }

    private actor ViewRunner: CloudTuiCommandRunning {
        var snapshot: Data
        var tree: Data
        private(set) var calls = 0

        init(snapshot: Data, tree: Data) { self.snapshot = snapshot; self.tree = tree }
        func replace(snapshot: Data, tree: Data) { self.snapshot = snapshot; self.tree = tree }
        func runTuiCommand(arguments: [String], deadline: Duration) async throws -> Data {
            calls += 1
            if arguments.suffix(3) == ["session", "current", "snapshot"] { return snapshot }
            return tree
        }
    }
}
