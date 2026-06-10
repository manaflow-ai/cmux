import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceSidebarObservationTests: XCTestCase {
    func testSidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    func testSidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    func testSidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        XCTAssertEqual(
            publishCount,
            0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    // The sidebar `status`/`metadata` socket API lets agents and CI scripts
    // insert entries under arbitrary caller-chosen keys. With ~30 long-running
    // agent sessions over hours, an integration that uses ever-distinct keys
    // grows these @Published dictionaries without bound, which both leaks memory
    // (footprint climbed to 6–8 GB in https://github.com/manaflow-ai/cmux/issues/5845)
    // and makes the per-tick `removeDuplicates` equality check and
    // `sidebarStatusEntriesInDisplayOrder()` sort that feed the sidebar view
    // graph progressively more expensive on the main thread. They must stay
    // bounded like `logEntries` already is.
    func testStatusEntriesStayBoundedUnderUnboundedDistinctKeys() {
        let workspace = Workspace()
        // Mirrors `Workspace.maxSidebarStatusEntries`; kept as a literal so this
        // regression test compiles and fails on the assertion (not a missing
        // symbol) in the pre-fix commit.
        let cap = 200

        for index in 0..<(cap * 3) {
            workspace.statusEntries["key_\(index)"] = SidebarStatusEntry(
                key: "key_\(index)",
                value: "value_\(index)",
                priority: 0,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertLessThanOrEqual(
            workspace.statusEntries.count,
            cap,
            "statusEntries must stay bounded so unbounded agent telemetry cannot grow the sidebar view-graph inputs without limit"
        )
        // Eviction keeps the most recent entries (highest timestamp) and drops
        // the oldest, so the newest key survives and the oldest is gone.
        XCTAssertNotNil(
            workspace.statusEntries["key_\(cap * 3 - 1)"],
            "The most recent status entry must be retained after trimming"
        )
        XCTAssertNil(
            workspace.statusEntries["key_0"],
            "The oldest status entry must be evicted once the cap is exceeded"
        )
    }

    func testMetadataBlocksStayBoundedUnderUnboundedDistinctKeys() {
        let workspace = Workspace()
        // Mirrors `Workspace.maxSidebarMetadataBlocks`; kept as a literal so this
        // regression test compiles and fails on the assertion (not a missing
        // symbol) in the pre-fix commit.
        let cap = 200

        for index in 0..<(cap * 3) {
            workspace.metadataBlocks["key_\(index)"] = SidebarMetadataBlock(
                key: "key_\(index)",
                markdown: "block_\(index)",
                priority: 0,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertLessThanOrEqual(
            workspace.metadataBlocks.count,
            cap,
            "metadataBlocks must stay bounded so unbounded agent telemetry cannot grow the sidebar view-graph inputs without limit"
        )
        XCTAssertNotNil(
            workspace.metadataBlocks["key_\(cap * 3 - 1)"],
            "The most recent metadata block must be retained after trimming"
        )
        XCTAssertNil(
            workspace.metadataBlocks["key_0"],
            "The oldest metadata block must be evicted once the cap is exceeded"
        )
    }
}
