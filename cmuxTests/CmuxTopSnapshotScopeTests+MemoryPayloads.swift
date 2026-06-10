import XCTest
import Foundation
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Memory payloads
extension CmuxTopSnapshotScopeTests {
    func testSummaryPayloadIncludesPhysicalFootprintMemoryBytes() throws {
        let pid = Int(Darwin.getpid())
        let expectedFootprintBytes = try XCTUnwrap(
            physicalFootprintBytes(for: pid),
            "proc_pid_rusage did not return physical footprint for current process"
        )

        let snapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
        let payload = snapshot.summaryPayload(for: [pid])
        let memoryBytes = int64(payload["memory_bytes"])

        XCTAssertGreaterThan(memoryBytes, 0)
        XCTAssertLessThanOrEqual(
            abs(memoryBytes - expectedFootprintBytes),
            max(16 * 1024 * 1024, expectedFootprintBytes / 5)
        )
    }

    func testSamplePayloadDescribesPhysicalFootprintFallbackSource() {
        let sample = CmuxTopProcessSnapshot.capture(includeProcessDetails: false).samplePayload()

        XCTAssertEqual(
            sample["memory_source"] as? String,
            CmuxTopProcessMemorySource.physicalFootprint.rawValue
        )
        XCTAssertEqual(
            sample["memory_fallback_source"] as? String,
            CmuxTopProcessMemorySource.residentSize.rawValue
        )
        XCTAssertEqual(
            sample["resident_memory_fallback_source"] as? String,
            CmuxTopProcessMemorySource.rusageResidentSize.rawValue
        )

        let fallbackSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: 1,
                    parentPID: 0,
                    name: "resident-fallback",
                    path: nil,
                    ttyDevice: nil,
                    cmuxWorkspaceID: nil,
                    cmuxSurfaceID: nil,
                    cmuxAttributionReason: nil,
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 1024,
                    residentMemorySource: .rusageResidentSize,
                    virtualBytes: 0,
                    threadCount: 1
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )
        let fallbackSample = fallbackSnapshot.samplePayload()
        XCTAssertEqual(
            fallbackSample["resident_memory_source"] as? String,
            CmuxTopProcessMemorySource.rusageResidentSize.rawValue
        )
        XCTAssertEqual(
            fallbackSample["resident_memory_sources"] as? [String],
            [CmuxTopProcessMemorySource.rusageResidentSize.rawValue]
        )
    }

    func testUnavailableMemorySourcesAreExposedInAggregatePayloads() throws {
        let unavailablePID = 1111
        let fallbackPID = 2222
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: unavailablePID,
                    parentPID: 0,
                    name: "codex",
                    path: nil,
                    ttyDevice: nil,
                    cmuxWorkspaceID: nil,
                    cmuxSurfaceID: nil,
                    cmuxAttributionReason: nil,
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 1,
                    memoryBytes: 0,
                    memorySource: .unavailable,
                    residentBytes: 0,
                    residentMemorySource: .unavailable,
                    virtualBytes: 0,
                    threadCount: 1
                ),
                CmuxTopProcessInfo(
                    pid: fallbackPID,
                    parentPID: 0,
                    name: "codex",
                    path: nil,
                    ttyDevice: nil,
                    cmuxWorkspaceID: nil,
                    cmuxSurfaceID: nil,
                    cmuxAttributionReason: nil,
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 2,
                    memoryBytes: 2048,
                    memorySource: .residentSize,
                    residentBytes: 1024,
                    residentMemorySource: .rusageResidentSize,
                    virtualBytes: 4096,
                    threadCount: 1
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: false
        )

        let summary = snapshot.summaryPayload(for: [unavailablePID, fallbackPID])
        assertUnavailableMemoryPayload(summary, unavailablePID: unavailablePID, fallbackPID: fallbackPID)

        let program = try XCTUnwrap(snapshot.programSummaryPayload(for: [unavailablePID, fallbackPID]).first)
        let programResources = try XCTUnwrap(program["resources"] as? [String: Any])
        assertUnavailableMemoryPayload(programResources, unavailablePID: unavailablePID, fallbackPID: fallbackPID)

        let codingAgent = try XCTUnwrap(
            snapshot.codingAgentSummaryPayload(for: [unavailablePID, fallbackPID])
                .first { $0["id"] as? String == "codex" }
        )
        let codingAgentResources = try XCTUnwrap(codingAgent["resources"] as? [String: Any])
        assertUnavailableMemoryPayload(codingAgentResources, unavailablePID: unavailablePID, fallbackPID: fallbackPID)
    }

    private func physicalFootprintBytes(for pid: Int) -> Int64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutableBytes(of: &info) { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            // proc_pid_rusage imports as rusage_info_t *; callers pass the concrete
            // rusage struct address cast to that opaque buffer type.
            let buffer = baseAddress.assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                pid_t(pid),
                RUSAGE_INFO_V2,
                buffer
            )
        }
        guard result == 0 else { return nil }
        return int64Clamped(info.ri_phys_footprint)
    }

    private func assertUnavailableMemoryPayload(
        _ payload: [String: Any],
        unavailablePID: Int,
        fallbackPID: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(intArray(payload["memory_source_fallback_pids"]), [fallbackPID], file: file, line: line)
        XCTAssertEqual(int(payload["memory_source_fallback_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["resident_memory_source_fallback_pids"]), [fallbackPID], file: file, line: line)
        XCTAssertEqual(int(payload["resident_memory_source_fallback_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["unavailable_memory_pids"]), [unavailablePID], file: file, line: line)
        XCTAssertEqual(int(payload["unavailable_memory_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["unavailable_resident_memory_pids"]), [unavailablePID], file: file, line: line)
        XCTAssertEqual(int(payload["unavailable_resident_memory_count"]), 1, file: file, line: line)
    }

    private func int64Clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

}
