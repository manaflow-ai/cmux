import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CmuxTopProcessTreeTests {
    @Test
    func boundsDeepProcessTreesBeforeWireEncoding() async {
        let processCount = 700
        let processes = (1...processCount).map { pid in
            Self.process(
                pid: pid,
                parentPID: pid == 1 ? 0 : pid - 1,
                name: "process",
                cpuPercent: 1,
                memoryBytes: 1,
                residentBytes: 1
            )
        }
        let snapshot = CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )
        let allowedPIDs = Set(1...processCount)

        let result = await Self.onSocketWorkerStack {
            let roots = snapshot.processTreePayload(for: allowedPIDs, rootPIDs: [1])
            var emittedPIDs: [Int] = []
            var current = roots.first
            var childrenTruncated = false
            var truncatedDescendantCount = 0
            var summarizedPIDs: [Int] = []
            var summarizedProcessCount = 0
            var visibleCPUPercent = 0.0
            var visibleProcessCount = 0

            while let node = current {
                guard let pid = node["pid"] as? Int else { break }
                emittedPIDs.append(pid)
                let resources = node["resources"] as? [String: Any] ?? [:]
                visibleCPUPercent += resources["cpu_percent"] as? Double ?? 0
                visibleProcessCount += resources["process_count"] as? Int ?? 0
                if node["children_truncated"] as? Bool == true {
                    childrenTruncated = true
                    truncatedDescendantCount = node["truncated_descendant_count"] as? Int ?? 0
                    summarizedPIDs = resources["pids"] as? [Int] ?? []
                    summarizedProcessCount = resources["process_count"] as? Int ?? 0
                }
                current = (node["children"] as? [[String: Any]])?.first
            }

            let envelope: [String: Any] = [
                "windows": [[
                    "workspaces": [[
                        "panes": [[
                            "surfaces": [[
                                "processes": roots
                            ] as [String: Any]]
                        ] as [String: Any]]
                    ] as [String: Any]]
                ] as [String: Any]]
            ]
            let wireEncoded: Bool
            if let value = JSONValue(foundationObject: envelope) {
                wireEncoded = ControlResponseEncoder().ok(id: nil, result: value)
                    != ControlResponseEncoder.encodeFailureResponse
            } else {
                wireEncoded = false
            }

            return DeepTreeResult(
                emittedPIDs: emittedPIDs,
                childrenTruncated: childrenTruncated,
                truncatedDescendantCount: truncatedDescendantCount,
                summarizedPIDs: summarizedPIDs,
                summarizedProcessCount: summarizedProcessCount,
                visibleCPUPercent: visibleCPUPercent,
                visibleProcessCount: visibleProcessCount,
                wireEncoded: wireEncoded
            )
        }

        #expect(result.emittedPIDs == Array(1...128))
        #expect(result.childrenTruncated)
        #expect(result.truncatedDescendantCount == processCount - result.emittedPIDs.count)
        #expect(result.summarizedPIDs == Array(128...processCount))
        #expect(result.summarizedProcessCount == processCount - 127)
        #expect(result.visibleCPUPercent == Double(processCount))
        #expect(result.visibleProcessCount == processCount)
        #expect(result.wireEncoded)
    }

    @Test
    func shallowPayloadPreservesExactContract() throws {
        let workspaceID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let surfaceID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let process = Self.process(
            pid: 42,
            parentPID: 1,
            name: "codex",
            path: "/usr/local/bin/codex",
            ttyDevice: 7,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            attributionReason: "test-fixture",
            processGroupID: 42,
            terminalProcessGroupID: 42,
            cpuPercent: 12.5,
            memoryBytes: 4_096,
            residentBytes: 2_048,
            virtualBytes: 8_192,
            threadCount: 3
        )
        let snapshot = CmuxTopProcessSnapshot(
            processes: [process],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )

        let actual = snapshot.processTreePayload(for: [42], rootPIDs: [42])
        let expected: [[String: Any]] = [[
            "kind": "process",
            "pid": 42,
            "ppid": 1,
            "name": "codex",
            "path": "/usr/local/bin/codex",
            "attribution_reason": "test-fixture",
            "thread_count": 3,
            "memory_source": CmuxTopProcessMemorySource.physicalFootprint.rawValue,
            "resident_memory_source": CmuxTopProcessMemorySource.residentSize.rawValue,
            "resources": [
                "cpu_percent": 12.5,
                "memory_bytes": 4_096,
                "resident_bytes": 2_048,
                "virtual_bytes": 8_192,
                "process_count": 1,
                "pids": [42],
                "missing_pids": [],
                "memory_source_fallback_pids": [],
                "memory_source_fallback_count": 0,
                "resident_memory_source_fallback_pids": [],
                "resident_memory_source_fallback_count": 0,
                "unavailable_memory_pids": [],
                "unavailable_memory_count": 0,
                "unavailable_resident_memory_pids": [],
                "unavailable_resident_memory_count": 0
            ] as [String: Any],
            "children": [],
            "tty_device": 7,
            "cmux_workspace_id": workspaceID.uuidString,
            "cmux_surface_id": surfaceID.uuidString,
            "pgid": 42,
            "tpgid": 42
        ]]

        #expect(try Self.canonicalJSON(actual) == Self.canonicalJSON(expected))
    }

    @Test
    func sortsChildrenAndFiltersDisallowedPIDsWhileKeepingOrphanedRoots() throws {
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                Self.process(pid: 100, parentPID: 1, name: "alpha-root"),
                Self.process(pid: 200, parentPID: 100, name: "zeta-child"),
                Self.process(pid: 300, parentPID: 100, name: "alpha-child"),
                Self.process(pid: 400, parentPID: 300, name: "excluded-grandchild"),
                Self.process(pid: 500, parentPID: 999, name: "zeta-orphan")
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )

        let roots = snapshot.processTreePayload(
            for: [100, 200, 300, 500, 9_999],
            rootPIDs: [100, 9_999]
        )
        #expect(roots.compactMap { $0["pid"] as? Int } == [100, 500])

        let root = try #require(roots.first)
        let children = try #require(root["children"] as? [[String: Any]])
        #expect(children.compactMap { $0["pid"] as? Int } == [300, 200])
        #expect(root["attribution_reason"] as? String == "explicit-root-pid")
        #expect(children.allSatisfy { $0["attribution_reason"] as? String == "child-process" })
        #expect(roots[1]["attribution_reason"] as? String == "included-process")
        #expect(children.allSatisfy { ($0["children"] as? [[String: Any]])?.isEmpty == true })
    }

    @Test
    func explicitRootsBreakCyclesWithoutDuplicatingVisitedProcesses() throws {
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                Self.process(pid: 1, parentPID: 2, name: "alpha"),
                Self.process(pid: 2, parentPID: 1, name: "beta")
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )

        #expect(snapshot.processTreePayload(for: [1, 2]).isEmpty)

        let roots = snapshot.processTreePayload(for: [1, 2], rootPIDs: [1, 2])
        let root = try #require(roots.first)
        let children = try #require(root["children"] as? [[String: Any]])
        let child = try #require(children.first)

        #expect(roots.count == 1)
        #expect(root["pid"] as? Int == 1)
        #expect(children.count == 1)
        #expect(child["pid"] as? Int == 2)
        #expect((child["children"] as? [[String: Any]])?.isEmpty == true)
    }

    private struct DeepTreeResult: Sendable {
        let emittedPIDs: [Int]
        let childrenTruncated: Bool
        let truncatedDescendantCount: Int
        let summarizedPIDs: [Int]
        let summarizedProcessCount: Int
        let visibleCPUPercent: Double
        let visibleProcessCount: Int
        let wireEncoded: Bool
    }

    private static func onSocketWorkerStack<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: operation())
            }
            thread.stackSize = 512 * 1_024
            thread.start()
        }
    }

    private static func canonicalJSON(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func process(
        pid: Int,
        parentPID: Int,
        name: String,
        path: String? = nil,
        ttyDevice: Int64? = nil,
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil,
        attributionReason: String? = nil,
        processGroupID: Int? = nil,
        terminalProcessGroupID: Int? = nil,
        cpuPercent: Double = 0,
        memoryBytes: Int64? = nil,
        residentBytes: Int64 = 0,
        virtualBytes: Int64 = 0,
        threadCount: Int = 1
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: path,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: surfaceID,
            cmuxAttributionReason: attributionReason,
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: cpuPercent,
            memoryBytes: memoryBytes,
            residentBytes: residentBytes,
            virtualBytes: virtualBytes,
            threadCount: threadCount
        )
    }
}
