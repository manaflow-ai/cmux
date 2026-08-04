import Dispatch
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CmuxTopProcessTreeTests {
    @Test
    func sevenHundredGenerationTreeFitsSocketWorkerStack() throws {
        let generationCount = 700
        let processIDs = Array(10_000..<(10_000 + generationCount))
        let processes = processIDs.enumerated().map { index, processID in
            CmuxTopProcessInfo(
                pid: processID,
                parentPID: index == 0 ? 1 : processIDs[index - 1],
                name: "chain-\(index)",
                path: "/bin/bash",
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
        let snapshot = CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let inspection = OSAllocatedUnfairLock<PayloadInspection?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        let worker = Thread {
            autoreleasepool {
                let payload = snapshot.processTreePayload(
                    for: Set(processIDs),
                    rootPIDs: [processIDs[0]]
                )
                inspection.withLock {
                    $0 = Self.inspectLinearTree(payload)
                }
            }
            finished.signal()
        }
        worker.stackSize = 512 * 1_024

        worker.start()

        #expect(finished.wait(timeout: .now() + 10) == .success)
        let result = try #require(inspection.withLock { $0 })
        #expect(result.error == nil)
        #expect(result.processIDs == processIDs)
    }

    private struct PayloadInspection: Sendable {
        let processIDs: [Int]
        let error: String?
    }

    private static func inspectLinearTree(_ roots: [[String: Any]]) -> PayloadInspection {
        var processIDs: [Int] = []
        var level = roots

        while !level.isEmpty {
            guard level.count == 1 else {
                return PayloadInspection(
                    processIDs: processIDs,
                    error: "expected one process at depth \(processIDs.count), got \(level.count)"
                )
            }
            let node = level[0]
            guard let processID = node["pid"] as? Int else {
                return PayloadInspection(
                    processIDs: processIDs,
                    error: "missing pid at depth \(processIDs.count)"
                )
            }
            guard let children = node["children"] as? [[String: Any]] else {
                return PayloadInspection(
                    processIDs: processIDs,
                    error: "missing children at depth \(processIDs.count)"
                )
            }
            processIDs.append(processID)
            level = children
        }

        return PayloadInspection(processIDs: processIDs, error: nil)
    }
}
