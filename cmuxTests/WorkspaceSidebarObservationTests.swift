import Foundation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct WorkspaceSidebarObservationTests {
    @Test func testSidebarObservationPublisherEmitsForLateStatusSubscriber() {
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

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    @Test func testSidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    @Test func testSidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        #expect(
            publishCount == 0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    // The sidebar `status`/`metadata` socket API lets agents and CI scripts
    // insert entries under arbitrary caller-chosen keys. With ~30 long-running
    // agent sessions over hours, an integration that uses ever-distinct keys
    // grows these forwarded dictionaries without bound, which both leaks memory
    // (footprint climbed to 6–8 GB in https://github.com/manaflow-ai/cmux/issues/5845)
    // and makes the sidebar observation `removeDuplicates` equality check and
    // `sidebarStatusEntriesInDisplayOrder()` sort that feed the sidebar view
    // graph progressively more expensive on the main thread. They must stay
    // bounded like `logEntries` already is.
    @Test func testStatusEntriesStayBoundedUnderUnboundedDistinctKeys() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries

        for index in 0..<(cap * 3) {
            workspace.statusEntries["key_\(index)"] = SidebarStatusEntry(
                key: "key_\(index)",
                value: "value_\(index)",
                priority: 0,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        #expect(
            workspace.statusEntries.count <= cap,
            "statusEntries must stay bounded so unbounded agent telemetry cannot grow the sidebar view-graph inputs without limit"
        )
        // Eviction keeps the most recent entries (highest timestamp) and drops
        // the oldest, so the newest key survives and the oldest is gone.
        #expect(
            workspace.statusEntries["key_\(cap * 3 - 1)"] != nil,
            "The most recent status entry must be retained after trimming"
        )
        #expect(
            workspace.statusEntries["key_0"] == nil,
            "The oldest status entry must be evicted once the cap is exceeded"
        )
    }

    @Test func testMetadataBlocksStayBoundedUnderUnboundedDistinctKeys() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarMetadataBlocks

        for index in 0..<(cap * 3) {
            workspace.metadataBlocks["key_\(index)"] = SidebarMetadataBlock(
                key: "key_\(index)",
                markdown: "block_\(index)",
                priority: 0,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        #expect(
            workspace.metadataBlocks.count <= cap,
            "metadataBlocks must stay bounded so unbounded agent telemetry cannot grow the sidebar view-graph inputs without limit"
        )
        #expect(
            workspace.metadataBlocks["key_\(cap * 3 - 1)"] != nil,
            "The most recent metadata block must be retained after trimming"
        )
        #expect(
            workspace.metadataBlocks["key_0"] == nil,
            "The oldest metadata block must be evicted once the cap is exceeded"
        )
    }

    // Metadata blocks have no PID/lifecycle coupling, so priority is the primary
    // retention signal: a newer low-priority flood must not displace an existing
    // high-priority block at the cap (#5845 follow-up — the original change gave
    // metadata an unwarranted just-inserted grace tier).
    @Test func testMetadataCapRetainsHighPriorityOverNewerLowPriorityFlood() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarMetadataBlocks

        workspace.metadataBlocks["important"] = SidebarMetadataBlock(
            key: "important",
            markdown: "m",
            priority: 100,
            timestamp: Date(timeIntervalSince1970: 0)
        )
        for index in 0..<(cap * 2) {
            workspace.metadataBlocks["low_\(index)"] = SidebarMetadataBlock(
                key: "low_\(index)",
                markdown: "m",
                priority: 0,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 100))
            )
        }

        #expect(workspace.metadataBlocks.count <= cap)
        #expect(
            workspace.metadataBlocks["important"] != nil,
            "A high-priority metadata block must survive a newer low-priority flood"
        )
    }

    // `set_status --pid` couples a status key to agent PID runtime state
    // (agentPIDs / ownership maps / port-scan tags). When the cap evicts the
    // status key, that coupled state must be torn down too, otherwise the same
    // ever-distinct-key workload keeps those maps growing without bound (#5845).
    @Test func testStatusCapEvictionClearsCoupledAgentPIDState() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries

        // Every key is backed by a live agent PID, so the cap must still evict
        // the oldest and purge its coupled agent PID state. PIDs are recorded
        // first so all keys count as live when the cap trims.
        for index in 0...cap {
            _ = workspace.recordAgentPID(
                key: "key_\(index)",
                pid: pid_t(4000 + index),
                panelId: nil,
                refreshPorts: false
            )
        }
        for index in 0...cap {
            workspace.statusEntries["key_\(index)"] = SidebarStatusEntry(
                key: "key_\(index)",
                value: "value_\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        #expect(workspace.statusEntries.count <= cap)
        #expect(
            workspace.statusEntries["key_0"] == nil,
            "The oldest status entry must be evicted once the cap is exceeded"
        )
        #expect(
            workspace.agentPIDs["key_0"] == nil,
            "Evicting a status key must also clear its coupled agent PID runtime state"
        )
    }

    // A brand-new agent status with a pending PID handoff (set_status --pid
    // inserts the status first, then records the PID) must survive its own
    // synchronous trim even when the workspace is already at cap with
    // higher-priority plain telemetry, so the follow-up PID can still be tracked
    // instead of lost to a self-eviction (#5845).
    @Test func testNewPIDHandoffStatusSurvivesOwnTrimOverPlainTelemetry() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries

        // Fill the cap with high-priority plain telemetry.
        for index in 0..<cap {
            workspace.statusEntries["high_\(index)"] = SidebarStatusEntry(
                key: "high_\(index)",
                value: "value_\(index)",
                priority: 100,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        #expect(workspace.statusEntries.count == cap)

        // Insert a lower-priority, newest PID-handoff status; the grace tier
        // keeps it until recordAgentPIDForSurvivingStatusKey can mark it live.
        workspace.setSidebarStatusEntry(SidebarStatusEntry(
            key: "agent",
            value: "Running",
            priority: 0,
            timestamp: Date(timeIntervalSince1970: TimeInterval(cap + 1))
        ), allowingPIDHandoffGrace: true)
        #expect(workspace.statusEntries.count <= cap)
        #expect(
            workspace.statusEntries["agent"] != nil,
            "A just-inserted status must survive its own trim over plain telemetry"
        )
    }

    // Plain status telemetry has no follow-up PID/lifecycle coupling, so it must
    // not use the PID-handoff grace tier to displace existing higher-priority
    // status entries at the cap.
    @Test func testNewPlainStatusSelfEvictsAgainstHigherPriorityTelemetry() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries

        for index in 0..<cap {
            workspace.statusEntries["high_\(index)"] = SidebarStatusEntry(
                key: "high_\(index)",
                value: "value_\(index)",
                priority: 100,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        #expect(workspace.statusEntries.count == cap)

        workspace.statusEntries["victim"] = SidebarStatusEntry(
            key: "victim",
            value: "victim",
            priority: 0,
            timestamp: Date(timeIntervalSince1970: TimeInterval(cap + 1))
        )

        #expect(workspace.statusEntries.count <= cap)
        #expect(
            workspace.statusEntries["victim"] == nil,
            "A plain low-priority status must not displace higher-priority telemetry"
        )
        #expect(
            workspace.statusEntries["high_0"] != nil,
            "Existing high-priority status entries must be retained over plain low-priority inserts"
        )
    }

    // When every cap slot is held by a live agent status, a new non-live status
    // can't displace a live one and self-evicts on insert — the precondition that
    // makes the command path skip recording its coupled PID (#5845).
    @Test func testNewNonLiveStatusSelfEvictsAgainstFullLiveStatuses() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries

        // Fill the cap with live agent statuses (PID recorded before status).
        for index in 0..<cap {
            let key = "live_\(index)"
            _ = workspace.recordAgentPID(key: key, pid: pid_t(5000 + index), panelId: nil, refreshPorts: false)
            workspace.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: "Running",
                priority: 100,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        #expect(workspace.statusEntries.count == cap)

        workspace.statusEntries["victim"] = SidebarStatusEntry(
            key: "victim",
            value: "victim",
            priority: 0,
            timestamp: Date(timeIntervalSince1970: TimeInterval(cap + 1))
        )
        #expect(
            workspace.statusEntries["victim"] == nil,
            "A new non-live status can't displace a full set of live agent statuses"
        )
    }

    // `set_status key Running --pid=...` re-pings are display no-ops, so a live
    // agent status keeps its original (old) insertion timestamp. A pure
    // timestamp cap would evict it under a flood of newer distinct keys, hiding a
    // live agent. Statuses backed by a coupled agent PID must be retained (#5845).
    @Test func testStatusCapRetainsLiveAgentBackedStatusOverNewerKeys() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries

        // Oldest possible timestamp, but backed by a live agent PID.
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        _ = workspace.recordAgentPID(key: "claude_code", pid: 9001, panelId: nil, refreshPorts: false)

        // Flood with newer, distinct, non-agent telemetry keys.
        for index in 0..<(cap * 2) {
            workspace.statusEntries["key_\(index)"] = SidebarStatusEntry(
                key: "key_\(index)",
                value: "value_\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 100))
            )
        }

        #expect(workspace.statusEntries.count <= cap)
        #expect(
            workspace.statusEntries["claude_code"] != nil,
            "A live agent-backed status must survive the cap even with an older timestamp"
        )
        #expect(
            workspace.agentPIDs["claude_code"] == 9001,
            "The retained live status must keep its coupled agent PID"
        )
    }

    // Some active agent statuses are lifecycle-backed with no PID — e.g. a
    // FeedCoordinator needs-input badge recorded via setAgentLifecycle. These
    // must also survive the cap; evicting one would hide a pending agent
    // decision (#5845).
    @Test func testStatusCapRetainsLifecycleBackedStatusWithoutPID() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries
        let panelId = UUID()

        // Oldest timestamp, no PID, but lifecycle-backed (needs input).
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        workspace.agentLifecycleStatesByPanelId[panelId] = ["claude_code": .needsInput]

        for index in 0..<(cap * 2) {
            workspace.statusEntries["key_\(index)"] = SidebarStatusEntry(
                key: "key_\(index)",
                value: "value_\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 100))
            )
        }

        #expect(workspace.statusEntries.count <= cap)
        #expect(
            workspace.statusEntries["claude_code"] != nil,
            "A lifecycle-backed needs-input status must survive the cap even without a PID"
        )
    }

    // cmux-owned status keys (remote.error, remote.port_conflicts) carry
    // application state and must never be evicted, even with the worst-case
    // ranking inputs (oldest timestamp, lowest priority, no agent runtime),
    // because remote-connection handling reads them back (#5845).
    @Test func testStatusCapNeverEvictsReservedCmuxOwnedKeys() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries
        // Literal values of the cmux-owned reserved status keys.
        let reservedKeys = ["remote.error", "remote.port_conflicts"]

        for reservedKey in reservedKeys {
            workspace.statusEntries[reservedKey] = SidebarStatusEntry(
                key: reservedKey,
                value: "state",
                priority: -100,
                timestamp: Date(timeIntervalSince1970: 0)
            )
        }

        for index in 0..<(cap * 2) {
            workspace.statusEntries["key_\(index)"] = SidebarStatusEntry(
                key: "key_\(index)",
                value: "value_\(index)",
                priority: 100,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 100))
            )
        }

        #expect(workspace.statusEntries.count <= cap)
        for reservedKey in reservedKeys {
            #expect(
                workspace.statusEntries[reservedKey] != nil,
                "cmux-owned reserved status key \(reservedKey) must never be evicted by the cap"
            )
        }
    }

    // When more distinct lifecycle-backed status keys than the cap are inserted,
    // the evicted ones must also have their lifecycle state cleared — otherwise
    // agentLifecycleStatesByPanelId grows unbounded and is re-traversed on every
    // trim, reintroducing the memory/CPU growth class (#5845).
    @Test func testStatusCapClearsLifecycleStateForEvictedKeys() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries
        let panelId = UUID()

        // Mirror FeedCoordinator: lifecycle recorded before the status entry.
        for index in 0..<(cap * 2) {
            let key = "lc_\(index)"
            workspace.agentLifecycleStatesByPanelId[panelId, default: [:]][key] = .needsInput
            workspace.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: "value_\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        #expect(workspace.statusEntries.count <= cap)
        let retainedLifecycleKeys = workspace.agentLifecycleStatesByPanelId.values
            .reduce(0) { $0 + $1.count }
        #expect(
            retainedLifecycleKeys <= cap,
            "Lifecycle state for evicted status keys must be cleared so it stays bounded"
        )
        #expect(
            workspace.agentLifecycleStatesByPanelId[panelId]?["lc_0"] == nil,
            "The oldest evicted lifecycle-backed status must have its lifecycle state cleared"
        )
    }

    // Detached-surface adoption also writes the status before recording the
    // transferred PID. If the destination is full of live statuses the adopted
    // status self-evicts, and its PID must not be recreated as an orphan (#5845).
    @Test func testDetachedAdoptionSkipsPIDWhenAdoptedStatusEvicted() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries

        for index in 0..<cap {
            let key = "live_\(index)"
            _ = workspace.recordAgentPID(key: key, pid: pid_t(5000 + index), panelId: nil, refreshPorts: false)
            workspace.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: "Running",
                priority: 100,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        #expect(workspace.statusEntries.count == cap)

        let runtime = Workspace.DetachedAgentRuntimeState(
            panelId: UUID(),
            statusEntries: [
                "adopted": SidebarStatusEntry(
                    key: "adopted",
                    value: "Running",
                    priority: 0,
                    timestamp: Date(timeIntervalSince1970: 0)
                )
            ],
            agentPIDs: ["adopted": 8888],
            agentPIDKeys: ["adopted"]
        )
        workspace.adoptDetachedAgentRuntimeState(runtime)

        #expect(
            workspace.statusEntries["adopted"] == nil,
            "The adopted status self-evicts when the destination is full of live statuses"
        )
        #expect(
            workspace.agentPIDs["adopted"] == nil,
            "The adopted PID must not be recorded when its status self-evicted"
        )
    }

    @Test func testDetachedAdoptionSkipsDottedPIDWhenExactDottedStatusEvicted() {
        let workspace = Workspace()
        let cap = Workspace.maxSidebarStatusEntries

        for index in 0..<cap {
            let key = "live_\(index)"
            _ = workspace.recordAgentPID(key: key, pid: pid_t(5000 + index), panelId: nil, refreshPorts: false)
            workspace.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: "Running",
                priority: 100,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        #expect(workspace.statusEntries.count == cap)

        let runtime = Workspace.DetachedAgentRuntimeState(
            panelId: UUID(),
            statusEntries: [
                "adopted.session": SidebarStatusEntry(
                    key: "adopted.session",
                    value: "Running",
                    priority: 0,
                    timestamp: Date(timeIntervalSince1970: 0)
                )
            ],
            agentPIDs: ["adopted.session": 8888],
            agentPIDKeys: ["adopted.session"]
        )
        workspace.adoptDetachedAgentRuntimeState(runtime)

        #expect(
            workspace.statusEntries["adopted.session"] == nil,
            "The exact dotted adopted status self-evicts when the destination is full of live statuses"
        )
        #expect(
            workspace.agentPIDs["adopted.session"] == nil,
            "The exact dotted adopted PID must not be recorded when its status self-evicted"
        )
    }

    @Test func testDetachedAdoptionRecordsPIDWhenStatusSurvives() {
        let workspace = Workspace()
        let runtime = Workspace.DetachedAgentRuntimeState(
            panelId: UUID(),
            statusEntries: [
                "adopted": SidebarStatusEntry(
                    key: "adopted",
                    value: "Running",
                    timestamp: Date(timeIntervalSince1970: 0)
                )
            ],
            agentPIDs: ["adopted": 8888],
            agentPIDKeys: ["adopted"]
        )
        workspace.adoptDetachedAgentRuntimeState(runtime)

        #expect(workspace.statusEntries["adopted"] != nil)
        #expect(workspace.agentPIDs["adopted"] == 8888)
    }
}
