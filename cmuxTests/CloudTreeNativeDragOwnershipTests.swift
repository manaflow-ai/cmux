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
    @Test("An abandoned Cloud writer revokes its provisional capability immediately")
    func abandonedWriterRevokesProvisionalCapability() throws {
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
            willBeginAt: .zero,
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
            endedAt: .zero,
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
            willBeginAt: .zero,
            forItems: [node]
        )
        #expect(coordinator.isDragging)
        #expect(SurfaceResourceDragRegistry.shared.group(id: writer.dragID) != nil)

        // The next pointer gesture is an authoritative native boundary even if
        // AppKit omitted endedAt during an outline reconstruction.
        coordinator.prepareForNativeDragBoundary()
        #expect(!coordinator.isDragging)
        #expect(SurfaceResourceDragRegistry.shared.group(id: writer.dragID) == nil)
        #expect(outline.activeNativeDragCoordinator == nil)
        #expect(outline.activeNativeDragSession == nil)

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
            endedAt: .zero,
            operation: []
        )
        #expect(SurfaceResourceDragRegistry.shared.group(id: replacementWriter.dragID) != nil)
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

    private static let machineActions = MachineRowActions(
        openShell: { _ in },
        openDesktop: { _ in },
        runCommand: { _, _ in },
        confirmDelete: { _ in },
        promptRename: { _, _ in },
        promptUpgrade: {}
    )

    private static let nodeActions = CloudTreeNodeActions(
        project: { _, _, _ in },
        newTerminal: { _, _ in },
        openGroup: { _, _, _, _ in },
        openGroupAsWorkspace: { _, _, _ in },
        newWorkspace: { _ in },
        closeTerminal: { _ in },
        closeWorkspace: { _, _ in },
        deleteWorkspace: { _, _ in },
        renameWorkspace: { _, _ in },
        selectLocalWorkspace: { _ in },
        copyToPasteboard: { _ in },
        refresh: {}
    )

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
