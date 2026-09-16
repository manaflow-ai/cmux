import Foundation
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AggregateMemoryRetentionTests {
    private struct Coalition: MemoryPressureCoalitionSampling {
        let bytes: UInt64
        func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage? {
            MemoryPressureCoalitionUsage(physicalFootprintBytes: bytes)
        }
    }

    @Test("Coalition pressure survives RAM overflow and descendant reparenting",
          arguments: [UInt64(36) << 30, UInt64(45) << 30, UInt64(72) << 30])
    func retainedDescendantsStayAccounted(coalitionBytes: UInt64) {
        // A small app remains after its large child's parent exits. The child
        // retains coalition membership, but a PPID walk can no longer find it.
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: 42, parentPID: 1, bytes: 2 << 30),
                process(pid: 43, parentPID: 1, bytes: 20 << 30)
            ],
            sampledAt: .distantPast,
            includesProcessDetails: false
        )
        let sampler = DarwinMemoryPressureAggregateSampler(
            processID: 42,
            snapshotProvider: { snapshot },
            coalitionSampler: Coalition(bytes: coalitionBytes),
            physicalMemoryProvider: { 36 << 30 },
            availableMemoryProvider: { 512 << 20 }
        )

        let sample = sampler.sample(at: Date(timeIntervalSince1970: 1))
        #expect(sample.source == .coalition)
        #expect(sample.aggregateBytes == coalitionBytes)
        #expect(sample.isUsable)
        #expect(MemoryPressureAggregatePolicy.default.evaluate(sample: sample).isActionable)
        #expect(MemoryPressureAggregatePolicy.default.severity(for: sample) == .critical)
    }

    @Test("An unreadable process-table edge never authorizes hibernation")
    func incompleteListingFailsClosed() {
        let listing = CmuxTopBSDProcessListing.capture(
            listPIDs: { pointer, _ in
                guard let pointer else { return 2 }
                let pids = pointer.assumingMemoryBound(to: pid_t.self)
                pids[0] = 42
                pids[1] = 43
                return 2
            },
            readProcess: { pid in
                guard pid == 42 else { return nil }
                var info = proc_bsdinfo()
                info.pbi_pid = UInt32(pid)
                return info
            }
        )
        #expect(!listing.isComplete)
        #expect(listing.missingProcessCount == 1)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [process(pid: 42, parentPID: 1, bytes: 9_000)],
            sampledAt: .distantPast,
            includesProcessDetails: false,
            enumerationIsComplete: listing.isComplete,
            enumerationMissingProcessCount: listing.missingProcessCount
        )
        let sampler = DarwinMemoryPressureAggregateSampler(
            processID: 42,
            snapshotProvider: { snapshot },
            coalitionSampler: Coalition(bytes: 0),
            physicalMemoryProvider: { 8_000 },
            availableMemoryProvider: { nil }
        )
        let sample = sampler.sample(at: .now)
        #expect(sample.source == .unavailable)
        #expect(sample.missingProcessCount == 1)
        #expect(!MemoryPressureAggregatePolicy.default.evaluate(sample: sample).isActionable)
    }

    @Test("Truncated PID buffers remain incomplete after bounded retries")
    func growingProcessTableFailsClosed() {
        var readCount = 0
        let listing = CmuxTopBSDProcessListing.capture(
            listPIDs: { pointer, bytes in
                guard let pointer else { return 1 }
                readCount += 1
                let count = Int(bytes) / MemoryLayout<pid_t>.stride
                let pids = pointer.assumingMemoryBound(to: pid_t.self)
                for index in 0..<count { pids[index] = pid_t(index + 1) }
                return Int32(count)
            },
            readProcess: { pid in
                var info = proc_bsdinfo()
                info.pbi_pid = UInt32(pid)
                return info
            }
        )
        #expect(readCount == 3)
        #expect(!listing.isComplete)
        #expect(!listing.processes.isEmpty)
    }

    @Test("Topology fallback preserves kernel parent and process generation")
    func publicTopologyFallbackRetainsIdentity() throws {
        let info = try #require(CmuxTopBSDProcessListing.fallbackBSDInfo(getpid()))
        #expect(info.pbi_pid == UInt32(getpid()))
        #expect(info.pbi_ppid == UInt32(getppid()))
        #expect(info.pbi_pgid == UInt32(getpgrp()))
        #expect(info.pbi_start_tvsec > 0)
    }

    @Test("Resource telemetry excludes process names, paths and workspace IDs")
    func resourceTelemetryIsBoundedAndPrivate() throws {
        let privateWorkspace = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: 42, parentPID: 1, bytes: 1_000),
                process(pid: 43, parentPID: 42, bytes: 2_000, name: "private-project", workspace: privateWorkspace),
                process(pid: 44, parentPID: 43, bytes: 3_000, name: "node", workspace: privateWorkspace)
            ],
            sampledAt: .distantPast,
            includesProcessDetails: true
        )
        let diagnostics = MemoryResourceDiagnostics(snapshot: snapshot, appPID: 42)
        #expect(diagnostics.childRSSBytes == 5_000)
        #expect(diagnostics.childAccountedBytes == 5_000)
        #expect(diagnostics.descendantCount == 2)
        #expect(diagnostics.workspaceRSSBytesByRank == [5_000])
        #expect(diagnostics.familyRSSBytes == ["other": 2_000, "javascript_runtime": 3_000])
        let data = try JSONSerialization.data(withJSONObject: diagnostics.payload())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("private-project"))
        #expect(!text.contains(privateWorkspace.uuidString))
        #expect(!text.contains("/private"))
    }

    @Test("FD telemetry distinguishes allocated slots from actual open descriptors")
    func liveDescriptorTypesAreMeasured() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let sample = DarwinFileDescriptorSnapshot.capture()
        try #require(sample.isComplete)
        #expect(sample.typeCounts["pipe", default: 0] >= 2)
        let tableCapacity = try #require(sample.tableCapacity)
        #expect(tableCapacity >= sample.typeCounts.values.reduce(0, +))
        #expect(DarwinFileDescriptorSnapshot.capture(processID: -1).isComplete == false)
    }

    private func process(
        pid: Int, parentPID: Int, bytes: Int64,
        name: String = "fixture", workspace: UUID? = nil
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid, parentPID: parentPID, name: name, path: "/private/project/tool",
            ttyDevice: nil, cmuxWorkspaceID: workspace, cmuxSurfaceID: nil,
            cmuxAttributionReason: nil, processGroupID: nil, terminalProcessGroupID: nil,
            cpuPercent: 0, memoryBytes: bytes, memorySource: .physicalFootprint,
            residentBytes: bytes, virtualBytes: bytes, threadCount: 1
        )
    }
}
