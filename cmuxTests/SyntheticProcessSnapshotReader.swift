import Darwin
import Foundation
import os
@testable import CmuxFoundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

/// Injects process syscalls into the real enumeration and enrichment pipeline.
/// No live PIDs, argv, session files or user settings are read.
final class SyntheticProcessSnapshotReader: CmuxTopProcessReading, Sendable {
    struct Counts: Sendable {
        var enumerations = 0
        var bsd = 0
        var task = 0
        var rusage = 0
        var names = 0
        var paths = 0
        var scope = 0
        var identity = 0
    }
    struct State {
        var counts = Counts()
        var replacedPID: Int?
        var missingPID: Int?
        var complete = true
        var hasScope = true
        var mainThreadReads = 0
        var reads = 0
    }
    // Only fixture instrumentation/clock counters cross concurrent providers.
    let state = OSAllocatedUnfairLock(initialState: State())
    let count: Int
    let workspaces = (0..<125).map { _ in UUID() }
    let surfaces = (0..<427).map { _ in UUID() }
    let admissions = AsyncStream<Int>.makeStream()

    init(count: Int = 4096) { self.count = count }

    func now() -> ContinuousClock.Instant {
        let read = state.withLock { $0.reads += 1; return $0.reads }
        admissions.continuation.yield(read)
        return ContinuousClock.now
    }

    func waitForAdmissions(_ count: Int) async {
        for await read in admissions.stream where read >= count { return }
    }

    func enumerate() -> DarwinProcessListing {
        state.withLock { $0.counts.enumerations += 1; if Thread.isMainThread { $0.mainThreadReads += 1 } }
        let listing = DarwinProcessEnumerator(
            listPIDs: { [count] pointer, _ in
                guard let pointer else { return Int32(count) }
                let pids = pointer.assumingMemoryBound(to: pid_t.self)
                for index in 0..<count { pids[index] = pid_t(index + 100) }
                return Int32(count)
            },
            readProcess: { [self] pid in
                let missing = state.withLock { $0.counts.bsd += 1; return $0.missingPID }
                guard Int(pid) != missing else { return nil }
                var info = proc_bsdinfo()
                info.pbi_pid = UInt32(pid)
                info.pbi_ppid = pid == 100 ? 1 : 100
                info.pbi_pgid = UInt32(pid)
                info.e_tdev = UInt32(1000 + (Int(pid) - 100) % 427)
                info.e_tpgid = UInt32(pid)
                info.pbi_start_tvsec = 100
                return info
            }
        ).capture()
        return DarwinProcessListing(
            processes: listing.processes,
            isComplete: listing.isComplete && state.withLock { $0.complete },
            missingProcessCount: listing.missingProcessCount
        )
    }

    func taskInfo(for pid: Int) -> proc_taskinfo? {
        state.withLock { $0.counts.task += 1 }
        var result = proc_taskinfo()
        result.pti_resident_size = 1_048_576
        result.pti_virtual_size = 4_194_304
        result.pti_threadnum = 2
        return result
    }

    func resourceUsage(for pid: Int) -> rusage_info_v4? {
        state.withLock { $0.counts.rusage += 1 }
        var result = rusage_info_v4()
        result.ri_phys_footprint = 2_097_152
        result.ri_resident_size = 1_048_576
        return result
    }

    func processName(pid: Int, fallback: String) -> String {
        state.withLock { $0.counts.names += 1 }
        return pid.isMultiple(of: 3) ? "codex" : "claude"
    }

    func processPath(pid: Int) -> String? {
        state.withLock { $0.counts.paths += 1; if Thread.isMainThread { $0.mainThreadReads += 1 } }
        return "/synthetic/workspace-\(pid % 125)/bin/agent-\(pid)"
    }

    func scope(for pid: Int, key: CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScope? {
        guard state.withLock({ $0.counts.scope += 1; return $0.hasScope }) else { return nil }
        return CmuxTopProcessSnapshot.cmuxScope(arguments: ["agent", "--session", "fixture-\(pid)"], environment: [
            "CMUX_WORKSPACE_ID": workspaces[pid % 125].uuidString,
            "CMUX_SURFACE_ID": surfaces[pid % 427].uuidString
        ])
    }

    func matches(pid: Int, key: CmuxTopProcessScopeCacheKey) -> Bool {
        state.withLock { value in
            value.counts.identity += 1
            return value.replacedPID != pid && key.startSeconds == 100
        }
    }
}
