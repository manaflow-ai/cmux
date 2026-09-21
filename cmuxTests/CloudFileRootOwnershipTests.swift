import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudFileRootOwnershipTests {
    @Test func changingWorkspaceClearsSelectionEvenWhenPathMatches() {
        let store = FileExplorerStore()
        let path = "/tmp/cmux-cloud-files-fixture"
        store.applyWorkspaceRoot(.local(workspaceId: UUID(), path: path))
        let node = FileExplorerNode(name: "old", path: path + "/old", isDirectory: true)
        node.children = []
        store.expand(node: node)
        store.select(node: node)
        store.applyWorkspaceRoot(.local(workspaceId: UUID(), path: path))
        #expect(store.selectedPath == nil)
        #expect(store.expandedPaths.isEmpty)
        store.applyWorkspaceRoot(.none)
    }
}
