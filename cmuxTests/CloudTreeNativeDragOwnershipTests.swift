import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud tree native drag ownership", .serialized)
struct CloudTreeNativeDragOwnershipTests {
    @Test("An abandoned Cloud writer revokes its provisional capability on deallocation")
    func abandonedWriterRevokesProvisionalCapability() async throws {
        let transferRegistry = TabDragTransferRegistry()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions,
            nodeActions: Self.nodeActions,
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-drag-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { transferRegistry }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let outline = try #require(coordinator.outlineView)
        let node = Self.terminalNode()
        coordinator.apply(nodes: [node])

        // The provisional writer must not claim an active native owner before
        // AppKit has called willBeginAt.
        var writer: (any NSPasteboardWriting)? = coordinator.outlineView(
            outline,
            pasteboardWriterForItem: node
        )
        let dragID: UUID = try {
            let writer = try #require(writer as? CloudTreeSurfaceDragPasteboardWriter)
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("cloud-tree-provisional-payload-\(UUID().uuidString)")
            )
            #expect(pasteboard.writeObjects([writer]))
            #expect(transferRegistry.resolve(from: pasteboard) != nil)
            let record = try #require(
                pasteboard.data(forType: DragOverlayRoutingPolicy.surfaceResourceTransferType)
                    .flatMap { try? JSONDecoder().decode(SurfaceResourceDragPasteboardRecord.self, from: $0) }
            )
            #expect(record.dragID == writer.dragID)
            let expectedResources = try #require(node.dragGroup?.resources)
            #expect(record.resourceIDs == expectedResources)
            return writer.dragID
        }()
        #expect(outline.activeNativeDragCoordinator == nil)
        #expect(SurfaceResourceDragRegistry.shared.group(id: dragID) != nil)

        // No native session was promoted. Releasing the writer is the exact
        // terminal boundary and must revoke both process-local registries now.
        writer = nil
        await flushMainActor()

        #expect(SurfaceResourceDragRegistry.shared.group(id: dragID) == nil)
        #expect(!coordinator.isDragging)
        #expect(outline.activeNativeDragCoordinator == nil)
        _ = container
    }

    @Test("A promoted Cloud writer stays owned until matching endedAt")
    func promotedWriterEndsOnlyAtMatchingNativeCompletion() throws {
        let transferRegistry = TabDragTransferRegistry()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions,
            nodeActions: Self.nodeActions,
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-drag-active-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { transferRegistry }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let outline = try #require(coordinator.outlineView)
        let node = Self.terminalNode()
        coordinator.apply(nodes: [node])

        var writer: (any NSPasteboardWriting)? = coordinator.outlineView(
            outline,
            pasteboardWriterForItem: node
        )
        let session = TestDraggingSession(sequence: 7)
        coordinator.outlineView(
            outline,
            draggingSession: session,
            willBeginAt: NSPoint.zero,
            forItems: [node]
        )

        #expect(coordinator.isDragging)
        #expect(outline.activeNativeDragCoordinator === coordinator)
        #expect(outline.activeNativeDragSession === session)

        // Releasing the provisional writer after promotion must not terminate
        // the active registration; only the matching native callback can do so.
        writer = nil
        #expect(coordinator.isDragging)
        #expect(outline.activeNativeDragSession === session)

        coordinator.outlineView(
            outline,
            draggingSession: session,
            endedAt: NSPoint.zero,
            operation: []
        )
        #expect(!coordinator.isDragging)
        #expect(outline.activeNativeDragCoordinator == nil)
        #expect(outline.activeNativeDragSession == nil)
        _ = container
    }

    @Test("A pointer boundary reclaims a Cloud drag whose endedAt was lost")
    func pointerBoundaryReclaimsCloudDragAfterReconstruction() throws {
        let transferRegistry = TabDragTransferRegistry()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions,
            nodeActions: Self.nodeActions,
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-drag-boundary-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { transferRegistry }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let outline = try #require(coordinator.outlineView)
        let node = Self.terminalNode()
        coordinator.apply(nodes: [node])

        let writer = try #require(
            coordinator.outlineView(outline, pasteboardWriterForItem: node)
                as? CloudTreeSurfaceDragPasteboardWriter
        )
        let session = TestDraggingSession(sequence: 12)
        coordinator.outlineView(
            outline,
            draggingSession: session,
            willBeginAt: NSPoint.zero,
            forItems: [node]
        )
        #expect(coordinator.isDragging)
        #expect(SurfaceResourceDragRegistry.shared.group(id: writer.dragID) != nil)

        // Rebuilding the representable installs a new current outline while
        // AppKit still retains the original source through the writer. The
        // pointer boundary on that rebuilt source must retire the old owner.
        let rebuiltContainer = CloudTreeContainerView(coordinator: coordinator)
        let rebuiltOutline = try #require(coordinator.outlineView)
        #expect(rebuiltOutline !== outline)
        coordinator.prepareForNativeDragBoundary(on: rebuiltOutline)
        #expect(!coordinator.isDragging)
        #expect(SurfaceResourceDragRegistry.shared.group(id: writer.dragID) == nil)
        #expect(outline.activeNativeDragCoordinator == nil)
        #expect(outline.activeNativeDragSession == nil)
        #expect(rebuiltOutline.activeNativeDragCoordinator == nil)
        #expect(rebuiltOutline.activeNativeDragSession == nil)

        // A replacement writer may be requested before the retired source's
        // delayed endedAt callback arrives. The superseded-session fence must
        // keep that new registration intact.
        let replacementWriter = try #require(
            coordinator.outlineView(outline, pasteboardWriterForItem: node)
                as? CloudTreeSurfaceDragPasteboardWriter
        )
        coordinator.outlineView(
            outline,
            draggingSession: session,
            endedAt: NSPoint.zero,
            operation: []
        )
        #expect(SurfaceResourceDragRegistry.shared.group(id: replacementWriter.dragID) != nil)
        _ = rebuiltContainer
        _ = container
    }

    @Test("An unattributable late callback does not revoke a pending writer")
    func lateUnknownEndedAtLeavesReplacementWriterPending() throws {
        let transferRegistry = TabDragTransferRegistry()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions,
            nodeActions: Self.nodeActions,
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-drag-unknown-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { transferRegistry }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let outline = try #require(coordinator.outlineView)
        let node = Self.terminalNode()
        coordinator.apply(nodes: [node])

        let firstWriter = try #require(
            coordinator.outlineView(outline, pasteboardWriterForItem: node)
                as? CloudTreeSurfaceDragPasteboardWriter
        )
        let firstSession = TestDraggingSession(sequence: 31)
        coordinator.outlineView(
            outline,
            draggingSession: firstSession,
            willBeginAt: NSPoint.zero,
            forItems: [node]
        )
        coordinator.prepareForNativeDragBoundary(on: outline)

        let secondWriter = try #require(
            coordinator.outlineView(outline, pasteboardWriterForItem: node)
                as? CloudTreeSurfaceDragPasteboardWriter
        )
        let secondSession = TestDraggingSession(sequence: 32)
        coordinator.outlineView(
            outline,
            draggingSession: secondSession,
            willBeginAt: NSPoint.zero,
            forItems: [node]
        )
        coordinator.outlineView(
            outline,
            draggingSession: secondSession,
            endedAt: NSPoint.zero,
            operation: []
        )

        let pendingWriter = try #require(
            coordinator.outlineView(outline, pasteboardWriterForItem: node)
                as? CloudTreeSurfaceDragPasteboardWriter
        )
        coordinator.outlineView(
            outline,
            draggingSession: firstSession,
            endedAt: NSPoint.zero,
            operation: []
        )
        #expect(SurfaceResourceDragRegistry.shared.group(id: pendingWriter.dragID) != nil)
        _ = firstWriter
        _ = secondWriter
        _ = container
    }

    private static func terminalNode() -> CloudTreeNode {
        let resource = SurfaceResource(
            id: SurfaceResourceID(
                machine: .cloud("cloud-tree-test"),
                kind: .terminal,
                key: "term-1"
            ),
            title: "Terminal",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: nil,
            port: nil,
            url: nil
        )
        return CloudTreeNode(
            id: "terminal/cloud-tree-test/term-1",
            kind: .terminal(CloudTreeTerminalRow(resource: resource, isOpen: false, viewBadge: nil))
        )
    }

    @Test("Reveal selects the exact placement of a shared terminal and expands collapsed parents")
    func revealSelectsExactPlacement() throws {
        let defaultsName = "cloud-sidebar-reveal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let expansion = CloudTreeExpansionStore(defaults: defaults)
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions,
            nodeActions: Self.nodeActions,
            expansionStore: expansion,
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 320), styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.close() }
        let outline = try #require(coordinator.outlineView)
        let machine = SurfaceMachineID.cloud("cloud-tree-test")
        let remoteWorkspace = SurfaceRemoteWorkspace(id: "ws-2", name: "Second", index: 1, focused: false)
        let resource = try #require(Self.terminalNode().dragGroup?.resources.first)
        let sharedResource = SurfaceResource(
            id: resource, title: "Shell", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: remoteWorkspace, port: nil, url: nil
        )
        let siblings = (1...30).map { "tab-\($0)" }.map { tabID in
            CloudTreeNode(id: tabID, kind: .terminal(CloudTreeTerminalRow(
                resource: sharedResource, isOpen: true, viewBadge: nil,
                remoteView: SurfaceRemoteView(tabID: tabID, workspace: remoteWorkspace)
            )))
        }
        let workspaceNode = CloudTreeNode(
            id: "ws-2", kind: .workspace(machine: machine, remoteWorkspace, terminalCount: siblings.count, hiddenTabCount: 0, openIn: nil),
            children: siblings
        )
        let root = CloudTreeNode(
            id: "workspaces", kind: .workspacesGroup(machine: machine), children: [workspaceNode]
        )
        expansion.setExpanded(false, node: root)
        expansion.setExpanded(false, node: workspaceNode)
        coordinator.apply(nodes: [root])
        #expect(outline.numberOfRows == 1)
        let projection = SurfaceProjection(
            resource: resource, workspaceID: UUID(), panelID: UUID(),
            remoteWorkspaceID: "ws-2", remoteTabID: "tab-30"
        )
        let target = try #require(CloudSidebarRevealTarget(
            projection: projection
        ))
        let request = CloudSidebarNavigationState.Request(target: target)
        coordinator.reveal(request)
        container.layoutSubtreeIfNeeded()
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == "tab-30")
        #expect(outline.isItemExpanded(root))
        #expect(outline.isItemExpanded(workspaceNode))
        #expect(expansion.isExpanded(root))
        #expect(outline.visibleRect.intersects(outline.rect(ofRow: outline.selectedRow)))

        // Catalog refreshes must not override a subsequent manual selection.
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.reveal(request)
        #expect(outline.selectedRow == 0)
        coordinator.reveal(CloudSidebarNavigationState.Request(target: target))
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == "tab-30")
        withExtendedLifetime(container) {}
    }

    @Test("A local pane has no Cloud sidebar target; a projected tab resolves its row")
    func revealResolvesLocalAndBoundWorkspaces() throws {
        #expect(CloudSidebarRevealTarget(projection: nil) == nil)
        let projection = SurfaceProjection(
            resource: SurfaceResourceID(machine: .cloud("test-machine"), kind: .terminal, key: "terminal"),
            workspaceID: UUID(), panelID: UUID(), remoteWorkspaceID: "ws-1", remoteTabID: "tab-1"
        )
        let target = try #require(CloudSidebarRevealTarget(projection: projection))
        let node = CloudTreeNode(
            id: "ws-1",
            kind: .workspace(
                machine: .cloud("test-machine"),
                SurfaceRemoteWorkspace(id: "ws-1", name: "First", index: 0, focused: false),
                terminalCount: 0, hiddenTabCount: 0, openIn: nil
            )
        )
        #expect(target.path(in: [node])?.last === node)
        #expect(target.path(in: []) == nil)
        #expect(target.machine == .cloud("test-machine"))
        let navigation = CloudSidebarNavigationState()
        navigation.reveal(target)
        let request = try #require(navigation.pendingRequest)
        navigation.complete(request.id)
        #expect(navigation.pendingRequest == nil)
        navigation.reveal(target)
        #expect(navigation.pendingRequest?.id != request.id)
    }

    private static let machineActions = MachineRowActions(
        setupVPN: { _ in },
        openShell: { _ in },
        openDesktop: { _ in },
        runCommand: { _, _ in },
        confirmDelete: { _ in },
        promptRename: { _, _ in },
        resizeDisk: { _, _ in },
        promptUpgrade: {}
    )

    private static let nodeActions = CloudTreeNodeActions(
        project: { _, _, _ in },
        projectRemoteView: { _, _, _, _ in },
        projectInLocalWorkspace: { _, _ in },
        projectRemoteViewInLocalWorkspace: { _, _, _ in },
        newTerminal: { _, _ in },
        openGroup: { _, _, _, _ in },
        openGroupAsWorkspace: { _, _, _ in },
        newWorkspace: { _ in },
        closeTerminal: { _ in },
        closeWorkspace: { _, _ in },
        renameWorkspace: { _, _ in },
        renameTerminal: { _, _ in },
        selectLocalWorkspace: { _ in },
        copyToPasteboard: { _ in },
        copyPortLink: { _ in },
        refresh: {}
    )

    private func flushMainActor() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private final class TestDraggingSession: NSDraggingSession {
        private let sequence: Int
        private let pasteboard: NSPasteboard

        init(sequence: Int) {
            self.sequence = sequence
            pasteboard = NSPasteboard(
                name: NSPasteboard.Name("cloud-tree-session-\(sequence)-\(UUID().uuidString)")
            )
            super.init()
        }

        override var draggingSequenceNumber: Int { sequence }
        override var draggingPasteboard: NSPasteboard { pasteboard }
    }
}
