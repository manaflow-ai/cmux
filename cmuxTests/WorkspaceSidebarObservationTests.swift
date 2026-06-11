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

    // `set_status --pid` couples a status key to agent PID runtime state
    // (agentPIDs / ownership maps / port-scan tags). When the cap evicts the
    // status key, that coupled state must be torn down too, otherwise the same
    // ever-distinct-key workload keeps those maps growing without bound (#5845).
    func testStatusCapEvictionClearsCoupledAgentPIDState() {
        let workspace = Workspace()
        let cap = 200

        // The oldest status key carries an agent PID and will be evicted first.
        workspace.statusEntries["key_0"] = SidebarStatusEntry(
            key: "key_0",
            value: "value_0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        _ = workspace.recordAgentPID(key: "key_0", pid: 4242, panelId: nil, refreshPorts: false)
        XCTAssertEqual(
            workspace.agentPIDs["key_0"],
            4242,
            "Precondition: the status key should have a coupled agent PID"
        )

        for index in 1..<(cap * 3) {
            workspace.statusEntries["key_\(index)"] = SidebarStatusEntry(
                key: "key_\(index)",
                value: "value_\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertNil(
            workspace.statusEntries["key_0"],
            "The oldest status entry must be evicted once the cap is exceeded"
        )
        XCTAssertNil(
            workspace.agentPIDs["key_0"],
            "Evicting a status key must also clear its coupled agent PID runtime state"
        )
    }

    // `set_status --pid` inserts the status entry first, then records the PID. If
    // the workspace is already at cap with higher-priority entries, a new
    // low-priority status self-evicts on insert, so its PID must not be recorded
    // — otherwise a flood of distinct low-priority keys grows agentPIDs without
    // bound despite the status cap (#5845).
    func testStatusPIDNotRecordedWhenNewStatusSelfEvicts() {
        let workspace = Workspace()
        let cap = 200

        // Fill the cap with high-priority entries so any new low-priority key is
        // evicted immediately on insert.
        for index in 0..<cap {
            workspace.statusEntries["high_\(index)"] = SidebarStatusEntry(
                key: "high_\(index)",
                value: "value_\(index)",
                priority: 100,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        XCTAssertEqual(workspace.statusEntries.count, cap)

        // Mirror the command path: insert the status, then record the PID only if
        // the entry survived the cap.
        workspace.statusEntries["victim"] = SidebarStatusEntry(
            key: "victim",
            value: "victim",
            priority: 0,
            timestamp: Date(timeIntervalSince1970: TimeInterval(cap + 1))
        )
        XCTAssertNil(
            workspace.statusEntries["victim"],
            "A new low-priority status should self-evict when the workspace is at cap"
        )
        _ = workspace.recordAgentPIDForSurvivingStatusKey("victim", pid: 7777, panelId: nil)

        XCTAssertNil(
            workspace.agentPIDs["victim"],
            "A PID for a status key that did not survive the cap must not be recorded"
        )
    }
}
