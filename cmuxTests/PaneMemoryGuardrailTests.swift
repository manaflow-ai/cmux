import CMUXAgentLaunch
import CmuxPanes
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// App-target coverage for the pane-memory guardrail that needs the live
/// process-snapshot subsystem (`CmuxTopProcessSnapshot`), the `AppDelegate`
/// window registry, or `TabManager`. The pure engine edge-trigger/hysteresis
/// behavior lives in `CmuxPanes`' `PaneMemoryGuardrailEngineTests`.
@Suite
struct PaneMemoryGuardrailTests {
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
            memoryPressureProcessGroupIDs: pgids,
            foregroundCommand: command
        )
    }

    // MARK: - tty-based attribution summation (the guardrail's core measurement)

    @Test
    func processTreeMemorySummationByTTY() {
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
        #expect(summary.memoryBytes == 9_005_000_000, "tree memory excludes the other tty")

        // The kill target is the high-memory process group (200), not the small
        // shell group (100) that only shares the tty.
        let pgids = PaneMemorySampleProvider.memoryPressureProcessGroupIDs(
            in: snapshot,
            pids: panePIDs,
            clearBytes: Int64(Double(threshold) * PaneMemoryGuardrailEngine.clearFraction)
        )
        #expect(pgids == [200])
    }

    @Test
    func processTreeMemoryIncludesForegroundDescendantWithoutTTYOrCMUXScope() {
        let ws = UUID(), pane = UUID()
        func proc(
            _ pid: Int,
            ppid: Int,
            name: String,
            mem: Int64,
            pgid: Int,
            tty: Int64?,
            surface: UUID?
        ) -> CmuxTopProcessInfo {
            CmuxTopProcessInfo(
                pid: pid, parentPID: ppid, name: name, path: nil, ttyDevice: tty,
                cmuxWorkspaceID: nil, cmuxSurfaceID: surface, cmuxAttributionReason: nil,
                processGroupID: pgid, terminalProcessGroupID: pgid, cpuPercent: 0,
                memoryBytes: mem, memorySource: .physicalFootprint,
                residentBytes: mem, residentMemorySource: .residentSize,
                virtualBytes: 0, threadCount: 1
            )
        }
        let shell = proc(100, ppid: 1, name: "zsh", mem: 10_000_000, pgid: 100, tty: 0x1600_0003, surface: nil)
        let leak = proc(200, ppid: 100, name: "python", mem: 9_000_000_000, pgid: 200, tty: nil, surface: nil)
        let other = proc(300, ppid: 1, name: "other", mem: 1_000_000_000, pgid: 300, tty: nil, surface: nil)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [shell, leak, other],
            sampledAt: Date(),
            includesProcessDetails: false,
            includesCMUXScope: false
        )
        let descriptor = PaneMemoryDescriptor(
            workspaceId: ws,
            panelId: pane,
            workspaceTitle: "Workspace",
            paneTitle: "Terminal",
            ttyName: nil,
            foregroundPID: 100
        )

        let sample = PaneMemorySampleProvider.computeSamples(
            descriptors: [descriptor],
            thresholdBytes: threshold,
            snapshot: snapshot
        ).first

        #expect(sample?.memoryBytes == 9_010_000_000)
        #expect(sample?.memoryPressureProcessGroupIDs == [200])
        #expect(sample?.foregroundCommand == "zsh")
    }

    @Test
    func processTreeMemoryIncludesScopedDaemonWithoutTTYOrParentLink() {
        let ws = UUID(), pane = UUID()
        func proc(
            _ pid: Int,
            ppid: Int,
            name: String,
            mem: Int64,
            pgid: Int,
            tty: Int64?,
            surface: UUID?
        ) -> CmuxTopProcessInfo {
            CmuxTopProcessInfo(
                pid: pid, parentPID: ppid, name: name, path: nil, ttyDevice: tty,
                cmuxWorkspaceID: surface == nil ? nil : ws, cmuxSurfaceID: surface, cmuxAttributionReason: nil,
                processGroupID: pgid, terminalProcessGroupID: pgid, cpuPercent: 0,
                memoryBytes: mem, memorySource: .physicalFootprint,
                residentBytes: mem, residentMemorySource: .residentSize,
                virtualBytes: 0, threadCount: 1
            )
        }
        let shell = proc(100, ppid: 1, name: "zsh", mem: 10_000_000, pgid: 100, tty: 0x1600_0003, surface: nil)
        let daemon = proc(200, ppid: 1, name: "python", mem: 9_000_000_000, pgid: 200, tty: nil, surface: pane)
        let other = proc(300, ppid: 1, name: "other", mem: 1_000_000_000, pgid: 300, tty: nil, surface: nil)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [shell, daemon, other],
            sampledAt: Date(),
            includesProcessDetails: false,
            includesCMUXScope: true
        )
        let descriptor = PaneMemoryDescriptor(
            workspaceId: ws,
            panelId: pane,
            workspaceTitle: "Workspace",
            paneTitle: "Terminal",
            ttyName: nil,
            foregroundPID: 100
        )

        let sample = PaneMemorySampleProvider.computeSamples(
            descriptors: [descriptor],
            thresholdBytes: threshold,
            snapshot: snapshot
        ).first

        #expect(sample?.memoryBytes == 9_010_000_000)
        #expect(sample?.memoryPressureProcessGroupIDs == [200])
        #expect(sample?.foregroundCommand == "zsh")
    }

    @Test
    func unscopedTicksDoNotClearScopedOnlyPressure() {
        let ws = UUID(), pane = UUID()
        let clearBytes = Int64(Double(threshold) * PaneMemoryGuardrailEngine.clearFraction)
        let scopedSample = sample(workspace: ws, pane: pane, memoryGB: 9, pgids: [200])
        let cheapSample = sample(workspace: ws, pane: pane, memoryGB: 0.1, pgids: [])

        let scoped = PaneMemorySampleProvider.reconcileScopedSamples(
            samples: [scopedSample],
            currentScopedOnlySamplesByKey: [scopedSample.key: scopedSample],
            previousScopedOnlySamplesByKey: [:],
            includesCMUXScope: true,
            clearBytes: clearBytes
        )
        let unscoped = PaneMemorySampleProvider.reconcileScopedSamples(
            samples: [cheapSample],
            currentScopedOnlySamplesByKey: [:],
            previousScopedOnlySamplesByKey: scoped.scopedOnlySamplesByKey,
            includesCMUXScope: false,
            clearBytes: clearBytes
        )

        #expect(unscoped.samples.first?.memoryBytes == cheapSample.memoryBytes + scopedSample.memoryBytes)
        #expect(unscoped.samples.first?.memoryPressureProcessGroupIDs == [200])

        let cleared = PaneMemorySampleProvider.reconcileScopedSamples(
            samples: [cheapSample],
            currentScopedOnlySamplesByKey: [:],
            previousScopedOnlySamplesByKey: unscoped.scopedOnlySamplesByKey,
            includesCMUXScope: true,
            clearBytes: clearBytes
        )
        #expect(cleared.scopedOnlySamplesByKey.isEmpty)
        #expect(cleared.samples.first?.memoryBytes == cheapSample.memoryBytes)
    }

    @Test
    func unscopedTicksAddCheapAndScopedOnlyPressure() {
        let ws = UUID(), pane = UUID()
        let clearBytes = Int64(Double(threshold) * PaneMemoryGuardrailEngine.clearFraction)
        let scopedOnlySample = sample(workspace: ws, pane: pane, memoryGB: 7, pgids: [200])
        let cheapSample = sample(workspace: ws, pane: pane, memoryGB: 7, pgids: [300])

        let reconciled = PaneMemorySampleProvider.reconcileScopedSamples(
            samples: [cheapSample],
            currentScopedOnlySamplesByKey: [:],
            previousScopedOnlySamplesByKey: [scopedOnlySample.key: scopedOnlySample],
            includesCMUXScope: false,
            clearBytes: clearBytes
        )

        #expect(reconciled.samples.first?.memoryBytes == 14 * gb)
        #expect(reconciled.samples.first?.memoryPressureProcessGroupIDs == [200, 300])
    }

    @Test
    func memoryPressureProcessGroupsAreEmptyAfterPressureClears() {
        let tty: Int64 = 0x1600_0003
        let shell = CmuxTopProcessInfo(
            pid: 100, parentPID: 1, name: "zsh", path: nil, ttyDevice: tty,
            cmuxWorkspaceID: nil, cmuxSurfaceID: nil, cmuxAttributionReason: nil,
            processGroupID: 100, terminalProcessGroupID: 100, cpuPercent: 0,
            memoryBytes: 20_000_000, memorySource: .physicalFootprint,
            residentBytes: 20_000_000, residentMemorySource: .residentSize,
            virtualBytes: 0, threadCount: 1
        )
        let snapshot = CmuxTopProcessSnapshot(
            processes: [shell],
            sampledAt: Date(),
            includesProcessDetails: false
        )

        let pgids = PaneMemorySampleProvider.memoryPressureProcessGroupIDs(
            in: snapshot,
            pids: [100],
            clearBytes: Int64(Double(threshold) * PaneMemoryGuardrailEngine.clearFraction)
        )
        #expect(pgids.isEmpty)
    }

    @MainActor
    @Test
    func appDelegateGuardrailDescriptorsUseRegisteredWindowManagers() throws {
        let app = AppDelegate()
        let bootstrapManager = TabManager()
        let firstWindowManager = TabManager()
        let secondWindowManager = TabManager()
        app.tabManager = bootstrapManager

        let firstWindowId = app.registerMainWindowContextForTesting(tabManager: firstWindowManager)
        let secondWindowId = app.registerMainWindowContextForTesting(tabManager: secondWindowManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            app.unregisterMainWindowContextForTesting(windowId: secondWindowId)
        }

        let bootstrapWorkspace = try #require(bootstrapManager.selectedWorkspace)
        let firstWindowWorkspace = try #require(firstWindowManager.selectedWorkspace)
        let secondWindowWorkspace = try #require(secondWindowManager.selectedWorkspace)

        let workspaceIds = Set(app.paneMemoryGuardrailDescriptors().map(\.workspaceId))
        #expect(workspaceIds.contains(bootstrapWorkspace.id))
        #expect(workspaceIds.contains(firstWindowWorkspace.id))
        #expect(workspaceIds.contains(secondWindowWorkspace.id))
    }

    @MainActor
    @Test
    func appDelegateGuardrailDescriptorsKeepBackgroundWorkspacesLive() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let firstWorkspace = try #require(manager.selectedWorkspace)
        let backgroundWorkspace = manager.addWorkspace(title: "Background", select: false)

        let initialWorkspaceIds = Set(app.paneMemoryGuardrailDescriptors().map(\.workspaceId))
        #expect(initialWorkspaceIds.contains(firstWorkspace.id))
        #expect(initialWorkspaceIds.contains(backgroundWorkspace.id))

        manager.selectWorkspace(backgroundWorkspace)

        let selectedWorkspaceIds = Set(app.paneMemoryGuardrailDescriptors().map(\.workspaceId))
        #expect(selectedWorkspaceIds.contains(firstWorkspace.id))
        #expect(selectedWorkspaceIds.contains(backgroundWorkspace.id))
    }
}
