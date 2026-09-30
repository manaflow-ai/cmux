import AppKit
import Bonsplit
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarWorkspaceDragDelegateTests {
    @Test
    func repeatedInstallationPreservesForwardingAndRestoresOriginalDelegate() {
        let controller = SidebarWorkspaceTableController()
        let table = SidebarWorkspaceTableViewImpl()
        table.delegate = controller
        table.rowHeight = 37
        let writer = makeWriter(table: table, controller: controller)

        writer.installProvisionalDelegate()
        // Each representable reconstruction can revisit the same pending writer.
        writer.installProvisionalDelegate()

        #expect(table.delegate === writer)
        expectForwardedDelegateCallbacks(writer, table: table)
        writer.releaseSourceGraph()
        #expect(table.delegate === controller)
        #expect(writer.sourceViewForDrag == nil)
    }

    @Test
    func replacingWriterSurvivesRetirementOfEarlierWriter() {
        let controller = SidebarWorkspaceTableController()
        let table = SidebarWorkspaceTableViewImpl()
        table.delegate = controller
        table.rowHeight = 43
        let earlierWriter = makeWriter(table: table, controller: controller)
        let selectedWriter = makeWriter(table: table, controller: controller)

        earlierWriter.installProvisionalDelegate()
        selectedWriter.installProvisionalDelegate()
        earlierWriter.releaseSourceGraph()

        #expect(table.delegate === selectedWriter)
        expectForwardedDelegateCallbacks(selectedWriter, table: table)
        selectedWriter.releaseSourceGraph()
        #expect(table.delegate === controller)
    }

    @Test
    func reinstallingSupersededWriterDoesNotCreateAForwardingCycle() {
        let controller = SidebarWorkspaceTableController()
        let table = SidebarWorkspaceTableViewImpl()
        table.delegate = controller
        table.rowHeight = 51
        let firstWriter = makeWriter(table: table, controller: controller)
        let secondWriter = makeWriter(table: table, controller: controller)

        firstWriter.installProvisionalDelegate()
        secondWriter.installProvisionalDelegate()
        firstWriter.installProvisionalDelegate()

        #expect(table.delegate === firstWriter)
        expectForwardedDelegateCallbacks(firstWriter, table: table)
        secondWriter.releaseSourceGraph()
        #expect(table.delegate === firstWriter)
        firstWriter.releaseSourceGraph()
        #expect(table.delegate === controller)
    }

    @Test
    func provisionalDelegateDoesNotRetainControllerOrReleasedSource() {
        weak var originalController: SidebarWorkspaceTableController?
        weak var sourceTable: SidebarWorkspaceTableViewImpl?
        let writer = autoreleasepool {
            let controller = SidebarWorkspaceTableController()
            originalController = controller
            let table = SidebarWorkspaceTableViewImpl()
            sourceTable = table
            table.delegate = controller
            let writer = makeWriter(table: table, controller: controller)
            writer.installProvisionalDelegate()
            return writer
        }
        #expect(originalController == nil)
        #expect(!writer.responds(to: NSSelectorFromString("cmuxUnknownDragDelegateCallback:")))

        // AppKit can autorelease the table while changing delegates. Drain those
        // temporary owners before checking whether the still-live writer leaks it.
        autoreleasepool {
            writer.releaseSourceGraph()
            #expect(sourceTable?.delegate == nil)
        }
        withExtendedLifetime(writer) {
            #expect(sourceTable == nil)
        }
    }

    @Test
    func workspaceWriterExportsLiveSurfaceGroupAlongsideReorderPayload() throws {
        let registry = TabDragTransferRegistry()
        let group = SurfaceResourceGroup(
            title: "workspace",
            placements: [SurfaceResourcePlacement(resource: SurfaceResourceID(
                machine: .cloud("test-machine"),
                kind: .terminal,
                key: UUID().uuidString
            ))]
        )
        let controller = SidebarWorkspaceTableController()
        let table = SidebarWorkspaceTableViewImpl()
        table.delegate = controller
        let writer = SidebarWorkspaceDragPasteboardWriter(
            workspaceId: UUID(),
            sessionId: nil,
            sourceView: table,
            controller: controller,
            provisionalToken: ProvisionalDragWriterOwnershipToken(onDeallocated: { _ in }),
            surfaceResourceGroup: group,
            transferRegistry: registry
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspace-surface-\(UUID())"))
        defer {
            writer.releaseSourceGraph()
            pasteboard.clearContents()
        }

        #expect(pasteboard.writeObjects([writer]))
        #expect(pasteboard.types?.contains(TabDragTransferRegistry.pasteboardType) == true)
        #expect(pasteboard.types?.contains(DragOverlayRoutingPolicy.surfaceResourceTransferType) == true)
        let transfer = try #require(registry.resolve(from: pasteboard))
        #expect(SurfaceResourceDragRegistry.shared.group(id: transfer.tab.id.uuid) == group)

        writer.releaseSourceGraph()
        #expect(registry.resolve(from: pasteboard) == nil)
        #expect(SurfaceResourceDragRegistry.shared.group(id: transfer.tab.id.uuid) == nil)
    }

    @Test
    func localWorkspaceGroupDoesNotRegisterPaneProjection() {
        let local = SurfaceResourceGroup(
            title: "local",
            resources: [SurfaceResourceID(machine: .local, kind: .terminal, key: UUID().uuidString)],
            representsWorkspace: true
        )
        #expect(!local.supportsNonDestructivePaneProjection)

        let remote = SurfaceResourceGroup(
            title: "remote",
            resources: [SurfaceResourceID(machine: .cloud("test-machine"), kind: .terminal, key: "term-1")]
        )
        #expect(remote.supportsNonDestructivePaneProjection)
    }

    @Test
    func localWorkspaceWriterPublishesOnlySidebarReorderPayload() {
        let registry = TabDragTransferRegistry()
        let table = SidebarWorkspaceTableViewImpl()
        let controller = SidebarWorkspaceTableController()
        let group = SurfaceResourceGroup(
            title: "local",
            resources: [SurfaceResourceID(machine: .local, kind: .terminal, key: UUID().uuidString)],
            representsWorkspace: true
        )
        let writer = SidebarWorkspaceDragPasteboardWriter(
            workspaceId: UUID(),
            sessionId: nil,
            sourceView: table,
            controller: controller,
            provisionalToken: ProvisionalDragWriterOwnershipToken(onDeallocated: { _ in }),
            surfaceResourceGroup: group,
            transferRegistry: registry
        )
        let types = writer.writableTypes(
            for: NSPasteboard(name: NSPasteboard.Name("local-only-\(UUID())"))
        )
        #expect(!types.contains(TabDragTransferRegistry.pasteboardType))
        writer.releaseSourceGraph()
    }

    @Test
    func sidebarReorderTypeSuppressesPaneDropRouting() throws {
        let registry = TabDragTransferRegistry()
        let registration = try #require(
            registry.register(
                TabDragTransfer(
                    tab: Bonsplit.Tab(title: "workspace"),
                    sourcePaneId: Bonsplit.PaneID()
                )
            )
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("mixed-sidebar-\(UUID())"))
        defer {
            registry.end(registration)
            pasteboard.clearContents()
        }
        #expect(registration.write(to: pasteboard))
        #expect(
            pasteboard.setString("workspace", forType: DragOverlayRoutingPolicy.sidebarTabReorderType)
        )
        #expect(
            BonsplitTabDragPayload.transfer(from: pasteboard, registry: registry) == nil
        )
    }

    private func makeWriter(
        table: SidebarWorkspaceTableViewImpl,
        controller: SidebarWorkspaceTableController
    ) -> SidebarWorkspaceDragPasteboardWriter {
        SidebarWorkspaceDragPasteboardWriter(
            workspaceId: UUID(),
            sessionId: nil,
            sourceView: table,
            controller: controller,
            provisionalToken: ProvisionalDragWriterOwnershipToken(onDeallocated: { _ in })
        )
    }

    private func expectForwardedDelegateCallbacks(
        _ writer: SidebarWorkspaceDragPasteboardWriter,
        table: SidebarWorkspaceTableViewImpl
    ) {
        #expect(!writer.responds(to: NSSelectorFromString("cmuxUnknownDragDelegateCallback:")))
        // An optional delegate method exercises NSObject's actual forwarding path.
        let delegate: any NSTableViewDelegate = writer
        #expect(delegate.tableView?(table, heightOfRow: 0) == table.rowHeight)
    }
}
