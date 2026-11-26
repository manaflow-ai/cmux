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

    @Test(arguments: [CGFloat(180), 280, 600])
    func disconnectedMessageFitsSidebar(width: CGFloat) throws {
        let store = FileExplorerStore()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(coordinator: coordinator, presentation: .files)
        container.frame = NSRect(x: 0, y: 0, width: width, height: 480)
        let message = "Remote files unavailable: Cloud machine is not connected"
        container.updateVisibility(hasContent: false, isLoading: false, statusMessage: message, showsRemoteTarget: true)
        container.layoutSubtreeIfNeeded()
        let label = try #require(container.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == message })
        #expect(!label.isHidden)
        // Text fields include cell padding outside the rectangle used by layout anchors.
        let alignmentRect = label.alignmentRect(forFrame: label.frame)
        #expect(alignmentRect.minX >= 16)
        #expect(alignmentRect.maxX <= width - 16)
        if width < 320 {
            #expect(label.frame.height > (label.font?.pointSize ?? 13) * 1.5)
        }
    }

    @Test func disconnectedCloudHeaderKeepsMachineName() {
        let store = FileExplorerStore()
        store.applyWorkspaceRoot(.remoteCloud(
            workspaceId: UUID(), vmID: "vm-fixture", displayTarget: "giddy-lilac-lemur",
            rootPath: nil, isAvailable: false, unavailableDetail: nil, target: nil
        ))
        #expect(store.displayRootPath == "giddy-lilac-lemur")
    }

}
