import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/4529.
///
/// PR https://github.com/manaflow-ai/cmux/pull/4437 migrated
/// `CmuxTaskManagerModel` to `@Observable` and the Task Manager view body
/// held `@Bindable var model` while rendering
/// `ScrollView { LazyVStack { ForEach { ... } } }`. That violates the
/// snapshot-boundary rule documented in `repo/CLAUDE.md` (referencing
/// https://github.com/manaflow-ai/cmux/issues/2586): any view rendered
/// inside a lazy list subtree may only see immutable value snapshots and
/// closure bundles, never the store. Combined with the 3 s refresh timer
/// in `TaskManagerWindowController` mutating `model.snapshot`, every
/// orthogonal mutation invalidates every row and thrashes the
/// `LazyLayoutViewCache`, leaking AttributeGraph nodes.
///
/// The native table now consumes immutable value rows directly. These tests
/// keep the snapshot equality contract that lets recycled cells skip unchanged
/// presentations without retaining model or action closures.
@MainActor
final class TaskManagerViewSnapshotBoundaryTests: XCTestCase {
    func testTaskManagerNativeRowsUseValueSnapshotEquality() {
        let left = Self.makeRow()
        let right = Self.makeRow()
        XCTAssertEqual(left, right)
    }

    func testTaskManagerRowViewEqualityDetectsRowChanges() {
        let baseRow = Self.makeRow()
        let bumpedRow = Self.makeRow(memoryBytes: baseRow.resources.memoryBytes + 1)

        XCTAssertNotEqual(
            baseRow,
            bumpedRow,
            "Native row equality must detect updated CPU or memory values so recycled cells repaint."
        )
    }

    // MARK: - Fixtures

    private static func makeRow(memoryBytes: Int64 = 1_024) -> CmuxTaskManagerRow {
        CmuxTaskManagerRow(
            id: "test-row",
            kind: .process,
            level: 0,
            title: "Test Row",
            detail: "PID 42",
            resources: CmuxTaskManagerResources(
                cpuPercent: 1.5,
                residentBytes: memoryBytes,
                memoryBytes: memoryBytes,
                processCount: 1,
                processIds: [42]
            ),
            isDimmed: false,
            workspaceId: nil,
            surfaceId: nil,
            terminalSurfaceId: nil,
            processId: 42,
            rootProcessIds: [42],
            foregroundProcessGroupIds: [],
            agentAssetName: nil
        )
    }
}
