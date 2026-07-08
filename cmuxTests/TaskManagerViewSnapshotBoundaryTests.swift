import Observation
import SwiftUI
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
/// The behavioral invariant that keeps that cache stable: the row view
/// must be `Equatable`, and equality must depend only on the value-typed
/// `row` snapshot, not on the closure identities the parent rebuilds on
/// every render. If `==` ever returns false for two row instances that
/// carry the same `row` payload, `.equatable()` cannot suppress body
/// re-evaluation and the leak is back.
@MainActor
final class TaskManagerViewSnapshotBoundaryTests: XCTestCase {
    func testTaskManagerRowViewEqualityIgnoresClosureIdentity() {
        let row = Self.makeRow()
        let leftView = CmuxTaskManagerRowView(
            row: row,
            onViewWorkspace: {},
            onViewTerminal: {},
            onKillProcess: {},
            onActivate: {}
        )
        // Distinct closures simulate the parent rebuilding the action
        // bundle on every render tick (a side-effect of the snapshot
        // mutation). Closure identity must be excluded from `==` so the
        // lazy list cache does not invalidate.
        let rightView = CmuxTaskManagerRowView(
            row: row,
            onViewWorkspace: { _ = 1 },
            onViewTerminal: { _ = 2 },
            onKillProcess: { _ = 3 },
            onActivate: { _ = 4 }
        )

        XCTAssertEqual(
            leftView,
            rightView,
            "Row views with identical row snapshots must compare equal even when the parent rebuilds closure bundles each render; otherwise .equatable() cannot suppress body re-eval and LazyVStack thrashes its layout cache (issue #2586 / #4529)."
        )
    }

    func testTaskManagerRowViewEqualityDetectsRowChanges() {
        let baseRow = Self.makeRow()
        let bumpedRow = Self.makeRow(memoryBytes: baseRow.resources.memoryBytes + 1)

        let left = CmuxTaskManagerRowView(
            row: baseRow,
            onViewWorkspace: {},
            onViewTerminal: {},
            onKillProcess: {},
            onActivate: {}
        )
        let right = CmuxTaskManagerRowView(
            row: bumpedRow,
            onViewWorkspace: {},
            onViewTerminal: {},
            onKillProcess: {},
            onActivate: {}
        )

        XCTAssertNotEqual(
            left,
            right,
            "Row view equality must still detect changes to the underlying row snapshot, otherwise updated CPU/memory values would never repaint."
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
