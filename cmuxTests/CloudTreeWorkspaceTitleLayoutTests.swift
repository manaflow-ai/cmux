import AppKit
import CmuxSurfaceCatalogModel
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud tree workspace title layout")
struct CloudTreeWorkspaceTitleLayoutTests {
    @Test("Disclosure controls leave a readable gap at every tree depth",
          arguments: CloudTreeStyle.presets)
    func disclosureSpacing(style: CloudTreeStyle) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.coordinator.apply(style: style)
        fixture.coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(fixture.coordinator.outlineView)
        outline.expandItem(nil, expandChildren: true)
        fixture.container.layoutSubtreeIfNeeded()
        for row in 0..<outline.numberOfRows {
            let node = try #require(outline.item(atRow: row) as? CloudTreeNode)
            guard !node.children.isEmpty else { continue }
            let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView)
            cell.layoutSubtreeIfNeeded()
            let host = try #require(cell.subviews.first { $0 is CloudTreePassthroughHostingView })
            let content = outline.convert(host.bounds, from: host)
            let disclosure = outline.frameOfOutlineCell(atRow: row)
            #expect(content.minX - disclosure.maxX >= CloudTreeStyle.compact.rowGrid.disclosureGap,
                    "Chevron crowds the content for \(node.structureTag) in \(style.id)")
            if style.machineRowLayout == .singleLine {
                #expect(abs(disclosure.midY - outline.rect(ofRow: row).midY) <= 1)
            }
        }
    }

    @Test("the display host reaches the visible cell trailing edge")
    func displayHostUsesVisibleCellWidth() {
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 700, height: 24))
        guard let host = cell.subviews.compactMap({ $0 as? CloudTreePassthroughHostingView }).first else {
            Issue.record("Cloud tree cell should host a pass-through display view")
            return
        }
        guard let trailingConstraint = cell.constraints.first(where: { constraint in
            (constraint.firstItem as? NSView) === host
                && constraint.firstAttribute == .trailing
                && (constraint.secondItem as? NSView) === cell
        }) else {
            Issue.record("Cloud tree display host should have a trailing constraint")
            return
        }

        #expect(trailingConstraint.relation == .equal)
        #expect(trailingConstraint.priority == NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.required.rawValue - 1))
    }

    @Test("the container document fills narrow and wide scroll viewports")
    func containerDocumentFillsScrollViewportAtWideAndNarrowSizes() {
        let machineActions = MachineRowActions.bound(onDidMutate: {})
        let nodeActions = CloudTreeNodeActions.bound(
            navigationHost: AppDelegate.makeCloudTerminalNavigationHost(),
            catalog: { SurfaceCatalog.shared }, selectedWorkspaceID: { nil },
            selectLocalWorkspace: { _ in }, onWillMutate: { _ in },
            onDidMutate: {}, onFailure: { _ in }, refresh: {}
        )
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: machineActions,
            nodeActions: nodeActions,
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-layout-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let machine = SurfaceMachineID.cloud("layout-test")
        container.frame = NSRect(x: 0, y: 0, width: 180, height: 300)
        container.layoutSubtreeIfNeeded()
        coordinator.apply(nodes: (0..<20).map { index in
            CloudTreeNode(
                id: "layout-placeholder-\(index)",
                kind: .placeholder(
                    machine: machine,
                    CloudTreePlaceholder(text: "row \(index)", style: .dimmed)
                )
            )
        })
        container.layoutSubtreeIfNeeded()

        for width in [180, 420] {
            container.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            container.layoutSubtreeIfNeeded()
            guard let scroll = container.subviews.compactMap({ $0 as? NSScrollView }).first,
                  let outline = scroll.documentView else {
                Issue.record("Cloud tree should install an outline document view")
                return
            }
            #expect(abs(outline.frame.width - scroll.contentView.bounds.width) <= 0.5)
            #expect(outline.frame.height >= scroll.contentView.bounds.height - 0.5)
            #expect(outline.frame.height > scroll.contentView.bounds.height)
        }
    }
}
