import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("AppKit sidebar snapshot store scale")
struct SidebarAppKitSnapshotStoreTests {
    private struct Input: Equatable {
        let revision: Int
    }

    private struct Presentation: Equatable {
        let revision: Int
        let isHovered: Bool
    }

    private typealias Store = SidebarAppKitSnapshotStore<Int, Input, Presentation>
    private typealias Item = SidebarAppKitSnapshotItem<Int, Input>
    private typealias Snapshot = SidebarAppKitSnapshot<Int, Input>

    @Test(arguments: [1, 10, 100, 1_000])
    func keyedUpdateVisitsProjectsAndReloadsExactlyOneRow(itemCount: Int) {
        let store = Self.makeStore(itemCount: itemCount)
        let targetID = itemCount / 2
        store.resetInstrumentation()

        let diff = store.updatePresentation(
            for: targetID,
            input: Input(revision: 1)
        )

        #expect(diff.insertedItemIDs.isEmpty)
        #expect(diff.removedItemIDs.isEmpty)
        #expect(diff.movedItemIDs.isEmpty)
        #expect(diff.reloadedItemIDs == Set([targetID]))
        #expect(diff.reloadedItemIDs.count <= 1)
        #expect(diff.reloadedRows == IndexSet(integer: targetID))
        #expect(store.rowIndex(for: targetID) == targetID)
        #expect(store.presentation(for: targetID) == Presentation(revision: 1, isHovered: false))
        #expect(store.instrumentation.keyedPresentationUpdateCount == 1)
        #expect(store.instrumentation.lastOperationItemVisitCount == 1)
        #expect(store.instrumentation.lastOperationProjectionCount == 1)
        #expect(store.instrumentation.lastOperationReloadCount == 1)
        #expect(store.lastProjectedItemIDs == Set([targetID]))
    }

    @Test(arguments: [1, 10, 100, 1_000])
    func structuralSingleInputChangeProjectsAndReloadsOnlyChangedRow(itemCount: Int) {
        let store = Self.makeStore(itemCount: itemCount)
        let targetID = itemCount / 2
        store.resetInstrumentation()

        let diff = store.apply(snapshot: Self.makeSnapshot(
            itemCount: itemCount,
            revisions: [targetID: 1]
        ))

        #expect(diff.insertedItemIDs.isEmpty)
        #expect(diff.removedItemIDs.isEmpty)
        #expect(diff.movedItemIDs.isEmpty)
        #expect(diff.reloadedItemIDs == Set([targetID]))
        #expect(diff.reloadedRows == IndexSet(integer: targetID))
        #expect(store.instrumentation.structuralSnapshotApplyCount == 1)
        #expect(store.instrumentation.lastOperationItemVisitCount == itemCount)
        #expect(store.instrumentation.lastOperationProjectionCount == 1)
        #expect(store.instrumentation.lastOperationReloadCount == 1)
        #expect(store.lastProjectedItemIDs == Set([targetID]))
    }

    @Test(arguments: [1, 10, 100, 1_000])
    func hoverTransitionTouchesOnlyOldAndNewRows(itemCount: Int) {
        let store = Self.makeStore(itemCount: itemCount)
        let oldHoveredID = 0
        _ = store.setHoveredItemID(oldHoveredID)
        store.resetInstrumentation()

        let nextHoveredID: Int? = itemCount == 1 ? nil : itemCount - 1
        let diff = store.setHoveredItemID(nextHoveredID)
        let expectedIDs = nextHoveredID.map { Set([oldHoveredID, $0]) } ?? Set([oldHoveredID])
        var expectedRows = IndexSet()
        for itemID in expectedIDs {
            expectedRows.insert(itemID)
        }

        #expect(diff.insertedItemIDs.isEmpty)
        #expect(diff.removedItemIDs.isEmpty)
        #expect(diff.movedItemIDs.isEmpty)
        #expect(diff.reloadedItemIDs == expectedIDs)
        #expect(diff.reloadedItemIDs.count <= 2)
        #expect(diff.reloadedRows == expectedRows)
        #expect(diff.reloadedRows.count <= 2)
        #expect(store.instrumentation.hoverTransitionCount == 1)
        #expect(store.instrumentation.lastOperationItemVisitCount == expectedIDs.count)
        #expect(store.instrumentation.lastOperationProjectionCount == expectedIDs.count)
        #expect(store.instrumentation.lastOperationReloadCount == expectedIDs.count)
        #expect(store.lastProjectedItemIDs == expectedIDs)
        #expect(store.presentation(for: oldHoveredID)?.isHovered == false)
        if let nextHoveredID {
            #expect(store.presentation(for: nextHoveredID)?.isHovered == true)
        }
    }

    @Test func structuralDiffReportsInsertRemoveMoveAndReloadSets() {
        let store = Store(
            snapshot: Snapshot(items: [0, 1, 2, 3].map {
                Item(id: $0, input: Input(revision: 0))
            }),
            projector: Self.project
        )
        store.resetInstrumentation()

        let next = Snapshot(items: [
            Item(id: 3, input: Input(revision: 0)),
            Item(id: 1, input: Input(revision: 0)),
            Item(id: 2, input: Input(revision: 1)),
            Item(id: 4, input: Input(revision: 0)),
        ])
        let diff = store.apply(snapshot: next)

        #expect(diff.insertedItemIDs == Set([4]))
        #expect(diff.removedItemIDs == Set([0]))
        #expect(diff.movedItemIDs == Set([3]))
        #expect(diff.reloadedItemIDs == Set([2]))
        #expect(diff.insertedRows == IndexSet(integer: 3))
        #expect(diff.removedRows == IndexSet(integer: 0))
        #expect(diff.moves == [SidebarAppKitSnapshotMove(itemID: 3, fromRow: 3, toRow: 0)])
        #expect(diff.reloadedRows == IndexSet(integer: 2))
        #expect(store.orderedItemIDs == [3, 1, 2, 4])
        #expect(store.rowIndex(for: 3) == 0)
        #expect(store.rowIndex(for: 4) == 3)
        #expect(store.itemID(atRow: 2) == 2)
        #expect(store.instrumentation.lastOperationItemVisitCount == 4)
        #expect(store.instrumentation.lastOperationProjectionCount == 2)
        #expect(store.lastProjectedItemIDs == Set([2, 4]))
    }

    private static func makeStore(itemCount: Int) -> Store {
        Store(
            snapshot: makeSnapshot(itemCount: itemCount),
            projector: project
        )
    }

    private static func makeSnapshot(
        itemCount: Int,
        revisions: [Int: Int] = [:]
    ) -> Snapshot {
        Snapshot(items: (0..<itemCount).map { itemID in
            Item(
                id: itemID,
                input: Input(revision: revisions[itemID] ?? 0)
            )
        })
    }

    private static func project(
        _ itemID: Int,
        _ input: Input,
        _ context: SidebarAppKitProjectionContext
    ) -> Presentation {
        _ = itemID
        return Presentation(
            revision: input.revision,
            isHovered: context.isHovered
        )
    }
}
