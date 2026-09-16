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
        let snapshot = CmuxTopProcessSnapshot(
            processes: [process(pid: 42, parentPID: 1, bytes: 9_000)],
            sampledAt: .distantPast,
            includesProcessDetails: false,
            enumerationIsComplete: false,
            enumerationMissingProcessCount: 1
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

    @Test("A later live child cannot join an earlier captured topology")
    func accountingUsesOnlyCapturedTopology() throws {
        let input = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
            try? input.fileHandleForReading.close()
        }
        // This PID was unrelated in the captured table. A fresh OS child query
        // must not attach its old metrics to the app (e.g. after PID reuse).
        let rootPID = Int(getpid())
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: rootPID, parentPID: 1, bytes: 100),
                process(pid: Int(child.processIdentifier), parentPID: 1, bytes: 9_000)
            ],
            sampledAt: .distantPast,
            includesProcessDetails: false
        )
        let diagnostics = MemoryResourceDiagnostics(snapshot: snapshot, appPID: rootPID)
        #expect(diagnostics.descendantCount == 0)
        #expect(diagnostics.childRSSBytes == 0)
        let sample = DarwinMemoryPressureAggregateSampler(
            processID: rootPID,
            snapshotProvider: { snapshot },
            coalitionSampler: Coalition(bytes: 0),
            physicalMemoryProvider: { 8_000 },
            availableMemoryProvider: { nil }
        ).sample(at: .now)
        #expect(sample.aggregateBytes == 100)
        #expect(MemoryPressureAggregatePolicy.default.severity(for: sample) == .normal)
    }

    @Test("Only the five largest anonymous workspace totals are emitted at scale")
    func workspaceTelemetryIsBoundedAtScale() {
        let processes = [process(pid: 42, parentPID: 1, bytes: 100)] + (1...1_000).map {
            process(pid: 10_000 + $0, parentPID: 42, bytes: Int64($0), workspace: UUID())
        }
        let snapshot = CmuxTopProcessSnapshot(
            processes: processes, sampledAt: .distantPast, includesProcessDetails: false
        )
        let diagnostics = MemoryResourceDiagnostics(snapshot: snapshot, appPID: 42)
        #expect(diagnostics.descendantCount == 1_000)
        #expect(diagnostics.childRSSBytes == 500_500)
        #expect(diagnostics.workspaceRSSBytesByRank == [1_000, 999, 998, 997, 996])
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
