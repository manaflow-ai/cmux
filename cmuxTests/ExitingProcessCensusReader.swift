@testable import CmuxFoundation
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A census in which one listed process exits before enrichment reads it.
struct ExitingProcessCensusReader: CmuxTopProcessReading {
    struct ListedProcess {
        let pid: Int
        let parentPID: Int
        let startSeconds: Int64
        var startMicroseconds: Int64 = 0
        let scoped: Bool
    }

    let processes: [ListedProcess]
    let exitedPID: Int
    let workspaceId: UUID
    let panelId: UUID

    func enumerate() -> DarwinProcessListing {
        DarwinProcessListing(
            processes: processes.map { process in
                var info = proc_bsdinfo()
                info.pbi_pid = UInt32(process.pid)
                info.pbi_ppid = UInt32(process.parentPID)
                info.pbi_pgid = UInt32(process.pid)
                info.pbi_start_tvsec = UInt64(process.startSeconds)
                info.pbi_start_tvusec = UInt64(process.startMicroseconds)
                return info
            },
            isComplete: true,
            missingProcessCount: 0
        )
    }

    func taskInfo(for pid: Int) -> proc_taskinfo? { nil }
    func resourceUsage(for pid: Int) -> rusage_info_v4? { nil }
    func processName(pid: Int, fallback: String) -> String { fallback }
    func processPath(pid: Int) -> String? { nil }

    func scope(for pid: Int, key: CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScope? {
        guard pid != exitedPID, processes.first(where: { $0.pid == pid })?.scoped == true else { return nil }
        return CmuxTopProcessScope(workspaceID: workspaceId, surfaceID: panelId, attributionReason: "cmux-test")
    }

    func matches(pid: Int, key: CmuxTopProcessScopeCacheKey) -> Bool { pid != exitedPID }
    func processHasExited(pid: Int) -> Bool { pid == exitedPID }
}
