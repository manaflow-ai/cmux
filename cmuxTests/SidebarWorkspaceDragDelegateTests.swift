import AppKit
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
    func provisionalDelegateDoesNotRetainControllerOrReleasedSource() throws {
        var controller: SidebarWorkspaceTableController? = SidebarWorkspaceTableController()
        weak var originalController = controller
        var table: SidebarWorkspaceTableViewImpl? = SidebarWorkspaceTableViewImpl()
        weak var sourceTable = table
        table?.delegate = controller
        let writer = makeWriter(table: try #require(table), controller: try #require(controller))

        writer.installProvisionalDelegate()
        controller = nil
        #expect(originalController == nil)
        #expect(!writer.responds(to: NSSelectorFromString("cmuxUnknownDragDelegateCallback:")))

        writer.releaseSourceGraph()
        #expect(table?.delegate == nil)
        table = nil
        #expect(sourceTable == nil)
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
