import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PaneMemoryGuardrailTests: XCTestCase {
    private let gb: Int64 = 1024 * 1024 * 1024
    private var threshold: Int64 { 8 * gb }

    private func sample(
        workspace: UUID,
        pane: UUID,
        memoryGB: Double,
        pgids: [Int] = [4242],
        command: String? = "pytest"
    ) -> PaneMemorySample {
        let descriptor = PaneMemoryDescriptor(
            workspaceId: workspace,
            panelId: pane,
            workspaceTitle: "Workspace",
            paneTitle: "Terminal",
            ttyName: "/dev/ttys003",
            foregroundPID: 99
        )
        let bytes = Int64(memoryGB * Double(gb))
        return PaneMemorySample(
            descriptor: descriptor,
            memoryBytes: bytes,
            residentBytes: bytes,
            runawayProcessGroupIDs: pgids,
            runawayMemberPIDs: pgids,
            foregroundCommand: command
        )
    }

    func testStaysSilentBelowThreshold() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        let output = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 1)], thresholdBytes: threshold)
        XCTAssertTrue(output.presentableWarnings.isEmpty)
        XCTAssertTrue(output.warnedWorkspaceIds.isEmpty)
    }

    func testWarnedPaneStaysPresentableWhileHigh() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()

        let first = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)
        XCTAssertEqual(first.presentableWarnings.map(\.panelId), [pane])
        XCTAssertEqual(first.warnedWorkspaceIds, [ws])

        // Still high next tick: still presentable (the monitor keeps showing the
        // same active banner; it does not re-fire a second one).
        let second = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)
        XCTAssertEqual(second.presentableWarnings.map(\.panelId), [pane])
        XCTAssertEqual(second.warnedWorkspaceIds, [ws])
    }

    func testDismissRemovesFromPresentableButKeepsBadge() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        _ = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)

        engine.dismiss(PaneMemoryPaneKey(workspaceId: ws, panelId: pane))
        // Drop into the hysteresis band so the pane re-evaluates without clearing.
        let banded = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 7)], thresholdBytes: threshold)
        XCTAssertTrue(banded.presentableWarnings.isEmpty, "dismissed pane is not re-presented")
        XCTAssertEqual(banded.warnedWorkspaceIds, [ws], "badge persists through the hysteresis band")
    }

    func testHysteresisClearsBelowClearLevelThenReWarns() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        let key = PaneMemoryPaneKey(workspaceId: ws, panelId: pane)

        _ = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)
        engine.dismiss(key)

        // 7 GB is in the band (6.4–8): still warned.
        let banded = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 7)], thresholdBytes: threshold)
        XCTAssertEqual(banded.warnedWorkspaceIds, [ws])

        // 5 GB is below clear (0.8 × 8 = 6.4): clears and resets dismissal.
        let cleared = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 5)], thresholdBytes: threshold)
        XCTAssertTrue(cleared.clearedPanes.contains(key))
        XCTAssertTrue(cleared.warnedWorkspaceIds.isEmpty)

        // Re-crossing makes it presentable again (dismissal was reset on clear).
        let reWarn = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)
        XCTAssertEqual(reWarn.presentableWarnings.map(\.panelId), [pane])
    }

    func testClosedPaneDropsBadge() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        _ = engine.ingest(samples: [sample(workspace: ws, pane: pane, memoryGB: 9)], thresholdBytes: threshold)

        // Pane is gone from the live set: warned state must not linger.
        let output = engine.ingest(samples: [], thresholdBytes: threshold)
        XCTAssertTrue(output.warnedWorkspaceIds.isEmpty)
        XCTAssertTrue(output.presentableWarnings.isEmpty)
    }

    func testSimultaneousCrossingsAreAllPresentableHighestFirst() {
        var engine = PaneMemoryGuardrailEngine()
        let wsA = UUID(), paneA = UUID(), wsB = UUID(), paneB = UUID()
        let output = engine.ingest(
            samples: [
                sample(workspace: wsA, pane: paneA, memoryGB: 9),
                sample(workspace: wsB, pane: paneB, memoryGB: 10)
            ],
            thresholdBytes: threshold
        )
        // Both are presentable (each gets a banner in turn), highest memory first.
        XCTAssertEqual(output.presentableWarnings.map(\.panelId), [paneB, paneA])
        XCTAssertEqual(output.warnedWorkspaceIds, [wsA, wsB])

        // After the first (paneB) is dismissed, paneA remains the next banner —
        // the follow-up runaway is NOT lost (autoreview P2 regression guard).
        engine.dismiss(PaneMemoryPaneKey(workspaceId: wsB, panelId: paneB))
        let next = engine.ingest(
            samples: [
                sample(workspace: wsA, pane: paneA, memoryGB: 9),
                sample(workspace: wsB, pane: paneB, memoryGB: 10)
            ],
            thresholdBytes: threshold
        )
        XCTAssertEqual(next.presentableWarnings.map(\.panelId), [paneA])
    }

    // MARK: - tty-based attribution summation (the guardrail's core measurement)

    func testProcessTreeMemorySummationByTTY() {
        let tty: Int64 = 0x1600_0003
        func proc(_ pid: Int, ppid: Int, mem: Int64, pgid: Int, tpgid: Int) -> CmuxTopProcessInfo {
            CmuxTopProcessInfo(
                pid: pid, parentPID: ppid, name: "pytest", path: nil, ttyDevice: tty,
                cmuxWorkspaceID: nil, cmuxSurfaceID: nil, cmuxAttributionReason: nil,
                processGroupID: pgid, terminalProcessGroupID: tpgid, cpuPercent: 0,
                memoryBytes: mem, memorySource: .physicalFootprint,
                residentBytes: mem, residentMemorySource: .residentSize,
                virtualBytes: 0, threadCount: 1
            )
        }
        // shell (foreground group == its own) + leaking child sharing the tty,
        // plus an unrelated process on a different tty that must be excluded.
        let shell = proc(100, ppid: 1, mem: 5_000_000, pgid: 100, tpgid: 200)
        let leak = proc(200, ppid: 100, mem: 9_000_000_000, pgid: 200, tpgid: 200)
        let other = CmuxTopProcessInfo(
            pid: 300, parentPID: 1, name: "other", path: nil, ttyDevice: 0x1600_0099,
            cmuxWorkspaceID: nil, cmuxSurfaceID: nil, cmuxAttributionReason: nil,
            processGroupID: 300, terminalProcessGroupID: 300, cpuPercent: 0,
            memoryBytes: 1_000_000_000, memorySource: .physicalFootprint,
            residentBytes: 1_000_000_000, residentMemorySource: .residentSize,
            virtualBytes: 0, threadCount: 1
        )
        let snapshot = CmuxTopProcessSnapshot(
            processes: [shell, leak, other],
            sampledAt: Date(),
            includesProcessDetails: false
        )

        let panePIDs: Set<Int> = [100, 200]
        let summary = snapshot.summary(for: panePIDs)
        XCTAssertEqual(summary.memoryBytes, 9_005_000_000, "tree memory excludes the other tty")

        // The kill target is the pane's foreground process group (200), where
        // pgid == terminal pgid. The shell (pgid 100 != tpgid 200) is excluded.
        let pgids = snapshot.foregroundProcessGroupIDs(for: panePIDs)
        XCTAssertEqual(pgids, [200])
    }

    // MARK: - kill-target selection (must catch a BACKGROUND leak, not the shell)

    func testKillTargetPicksDominantBackgroundGroupNotForeground() {
        // Shell is foreground (pgid 100) but tiny; the leak is a backgrounded
        // job in group 200. The kill target must be 200, not the shell.
        let processes: [(memoryBytes: Int64, processGroupID: Int?)] = [
            (5_000_000, 100),          // shell (foreground)
            (12_000_000_000, 200),     // backgrounded leak
            (3_000_000, 200)           // a child of the leak's group
        ]
        let targets = PaneMemoryGuardrail.killTargetProcessGroupIDs(
            processes: processes,
            totalMemoryBytes: 12_008_000_000
        )
        XCTAssertEqual(targets, [200])
    }

    func testKillTargetFallsBackToLargestProcessGroup() {
        // No group clears the 25% dominance bar individually, so fall back to
        // the single largest process's group rather than killing nothing.
        let processes: [(memoryBytes: Int64, processGroupID: Int?)] = [
            (200_000_000, 100),
            (210_000_000, 300),
            (190_000_000, 400)
        ]
        let targets = PaneMemoryGuardrail.killTargetProcessGroupIDs(
            processes: processes,
            totalMemoryBytes: 600_000_000
        )
        XCTAssertEqual(targets, [300])
    }

    func testKillTargetIgnoresInitAndSessionGroups() {
        let processes: [(memoryBytes: Int64, processGroupID: Int?)] = [
            (9_000_000_000, 1),   // pgid 1 must never be a target
            (9_000_000_000, nil)  // unknown group must never be a target
        ]
        let targets = PaneMemoryGuardrail.killTargetProcessGroupIDs(
            processes: processes,
            totalMemoryBytes: 18_000_000_000
        )
        XCTAssertTrue(targets.isEmpty)
    }
}
