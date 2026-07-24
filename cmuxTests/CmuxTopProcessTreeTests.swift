import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CmuxTopProcessTreeTests {
    @Test func deepProcessChainIsSplitIntoStackSafeSegments() throws {
        let processCount = 96
        let firstPID = 920_000
        let processes = (0..<processCount).map { index in
            processInfo(
                pid: firstPID + index,
                parentPID: index == 0 ? 0 : firstPID + index - 1
            )
        }
        let snapshot = CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )

        let payload = snapshot.processTreePayload(
            for: Set(processes.map(\.pid)),
            rootPIDs: [firstPID]
        )

        var pending = payload.map { (node: $0, depth: 1) }
        var seenPIDs: [Int] = []
        var maximumDepth = 0
        while let current = pending.popLast() {
            maximumDepth = max(maximumDepth, current.depth)
            seenPIDs.append(try #require(current.node["pid"] as? Int))
            let children = current.node["children"] as? [[String: Any]] ?? []
            pending.append(contentsOf: children.map { (node: $0, depth: current.depth + 1) })
        }

        #expect(payload.count == 3)
        #expect(maximumDepth <= 32)
        #expect(seenPIDs.count == processCount)
        #expect(Set(seenPIDs) == Set(processes.map(\.pid)))
    }

    private func processInfo(pid: Int, parentPID: Int) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: "process-\(pid)",
            path: nil,
            ttyDevice: nil,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }
}
