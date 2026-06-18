import Foundation
import Testing

// `ClusterSSHLayoutBuilder` lives in `CLI/ClusterSSHLayoutBuilder.swift`, which is
// compiled into BOTH the `cmux-cli` target and this test target (mirrors
// `CLI/FeedEventClassifier.swift`), so the pure grid math can be unit-tested
// directly without `@testable`-importing the CLI executable module.
@Suite("Cluster SSH layout builder")
struct ClusterSSHLayoutBuilderTests {
    private func pane(_ name: String) -> ClusterSSHLayoutBuilder.Pane {
        ClusterSSHLayoutBuilder.Pane(command: "ssh \(name)", name: name)
    }

    /// Depth-first collection of every leaf surface command in the layout tree.
    private func commands(in node: [String: Any]) -> [String] {
        if let pane = node["pane"] as? [String: Any],
           let surfaces = pane["surfaces"] as? [[String: Any]] {
            return surfaces.compactMap { $0["command"] as? String }
        }
        if let children = node["children"] as? [[String: Any]] {
            return children.flatMap { commands(in: $0) }
        }
        return []
    }

    private func leafCount(in node: [String: Any]) -> Int {
        if node["pane"] != nil { return 1 }
        if let children = node["children"] as? [[String: Any]] {
            return children.reduce(0) { $0 + leafCount(in: $1) }
        }
        return 0
    }

    @Test("a single host is a bare leaf, no split")
    func singleHost() {
        let node = ClusterSSHLayoutBuilder.layout(panes: [pane("a")])
        #expect(node["direction"] == nil)
        #expect(node["pane"] != nil)
        #expect(commands(in: node) == ["ssh a"])
    }

    @Test("two hosts split side by side (horizontal)")
    func twoHosts() {
        let node = ClusterSSHLayoutBuilder.layout(panes: [pane("a"), pane("b")])
        #expect(node["direction"] as? String == "horizontal")
        #expect((node["children"] as? [[String: Any]])?.count == 2)
        #expect(commands(in: node) == ["ssh a", "ssh b"])
    }

    @Test("four hosts auto-grid into 2x2 rows of columns")
    func fourHostsAuto() {
        let node = ClusterSSHLayoutBuilder.layout(panes: [pane("a"), pane("b"), pane("c"), pane("d")])
        #expect(node["direction"] as? String == "vertical")
        let rows = node["children"] as? [[String: Any]]
        #expect(rows?.count == 2)
        #expect(rows?.allSatisfy { $0["direction"] as? String == "horizontal" } == true)
        #expect(Set(commands(in: node)) == ["ssh a", "ssh b", "ssh c", "ssh d"])
        #expect(leafCount(in: node) == 4)
    }

    @Test("columns:1 stacks every host vertically")
    func singleColumn() {
        let node = ClusterSSHLayoutBuilder.layout(panes: [pane("a"), pane("b"), pane("c")], columns: 1)
        #expect(node["direction"] as? String == "vertical")
        #expect(leafCount(in: node) == 3)
    }

    @Test("every host appears exactly once regardless of count")
    func allHostsPresent() {
        for count in 1...12 {
            let panes = (0..<count).map { pane("h\($0)") }
            let node = ClusterSSHLayoutBuilder.layout(panes: panes)
            #expect(leafCount(in: node) == count)
            #expect(Set(commands(in: node)).count == count)
        }
    }

    @Test("grid dimensions are near-square by default and honor -C/-R")
    func gridDimensions() {
        #expect(ClusterSSHLayoutBuilder.gridDimensions(count: 9, columns: nil, rows: nil).columns == 3)
        let five = ClusterSSHLayoutBuilder.gridDimensions(count: 5, columns: nil, rows: nil)
        #expect(five.columns == 3)
        #expect(five.rows == 2)
        let forcedCols = ClusterSSHLayoutBuilder.gridDimensions(count: 6, columns: 2, rows: nil)
        #expect(forcedCols.columns == 2)
        #expect(forcedCols.rows == 3)
        #expect(ClusterSSHLayoutBuilder.gridDimensions(count: 6, columns: nil, rows: 2).rows == 2)
    }
}
