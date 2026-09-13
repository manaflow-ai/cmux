import AppKit
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudTreeWorkspaceTitleLayoutTests: XCTestCase {
    func testDisplayHostUsesVisibleCellWidth() {
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 700, height: 24))
        guard let host = cell.subviews.compactMap({ $0 as? CloudTreePassthroughHostingView }).first else {
            return XCTFail("Cloud tree cell should host a pass-through display view")
        }
        guard let trailingConstraint = cell.constraints.first(where: { constraint in
            (constraint.firstItem as? NSView) === host
                && constraint.firstAttribute == .trailing
                && (constraint.secondItem as? NSView) === cell
        }) else {
            return XCTFail("Cloud tree display host should have a trailing constraint")
        }

        XCTAssertEqual(trailingConstraint.relation, .equal)
        XCTAssertEqual(
            trailingConstraint.priority,
            NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.required.rawValue - 1)
        )
    }

    @MainActor
    func testContainerDocumentFillsScrollViewportAtWideAndNarrowSizes() {
        let machineActions = MachineRowActions.bound(onDidMutate: {})
        let nodeActions = CloudTreeNodeActions.bound(
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

        for width in [180, 420] {
            container.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            container.layoutSubtreeIfNeeded()
            guard let scroll = container.subviews.compactMap({ $0 as? NSScrollView }).first,
                  let outline = scroll.documentView else {
                return XCTFail("Cloud tree should install an outline document view")
            }
            XCTAssertEqual(outline.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
        }
    }
}
