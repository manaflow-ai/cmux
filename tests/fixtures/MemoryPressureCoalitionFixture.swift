import Darwin
import Foundation

enum FixtureMemorySource: Sendable {
    case physicalFootprint
    case unavailable
}

struct FixtureProcess: Sendable {
    let pid: Int
    let parentPID: Int
    let memoryBytes: Int64
    let memorySource: FixtureMemorySource
}

struct CmuxTopProcessSnapshot: MemoryPressureAggregateProcessSnapshot {
    let enumerationIsComplete: Bool
    let enumerationMissingProcessCount: Int
    private let rootPID: Int
    private let processes: [FixtureProcess]

    init(scenario: String, rootPID: Int = 101) {
        self.rootPID = rootPID
        let unreadableLogin = scenario == "unreadable-login" || scenario == "exiting-child"
        let unreadableChild = scenario == "unreadable-child"
        let reusedChild = scenario == "pid-reuse"
        let missingCount = scenario == "exiting-child" ? 1 : 0
        processes = [
            FixtureProcess(pid: rootPID, parentPID: 1, memoryBytes: 1_000, memorySource: .physicalFootprint),
            FixtureProcess(
                pid: rootPID + 101,
                parentPID: rootPID,
                memoryBytes: unreadableLogin ? 0 : 100,
                memorySource: unreadableLogin ? .unavailable : .physicalFootprint
            ),
            FixtureProcess(pid: rootPID + 202, parentPID: rootPID + 101, memoryBytes: 200, memorySource: .physicalFootprint),
            FixtureProcess(
                pid: rootPID + 303,
                parentPID: reusedChild ? rootPID + 404 : rootPID + 202,
                memoryBytes: unreadableChild ? 0 : 3_000,
                memorySource: unreadableChild ? .unavailable : .physicalFootprint
            )
        ]
        enumerationIsComplete = missingCount == 0
        enumerationMissingProcessCount = missingCount
    }

    func aggregateExpandedPIDs(rootPIDs: Set<Int>) -> Set<Int> {
        precondition(rootPIDs == [rootPID])
        var childrenByParent: [Int: [Int]] = [:]
        for process in processes {
            childrenByParent[process.parentPID, default: []].append(process.pid)
        }
        var result: Set<Int> = []
        var stack = Array(rootPIDs)
        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }

    func aggregateProcess(pid: Int) -> MemoryPressureAggregateProcessRecord? {
        guard let process = processes.first(where: { $0.pid == pid }) else { return nil }
        return MemoryPressureAggregateProcessRecord(
            pid: process.pid,
            memoryBytes: process.memoryBytes,
            hasReadableMemory: process.memorySource == .physicalFootprint
        )
    }

    static func captureCached(
        includeProcessDetails: Bool,
        includeCMUXScope: Bool,
        maximumAge: TimeInterval
    ) async -> Self {
        fatalError("The probe must use its injected process snapshot")
    }
}

private struct UnavailableCoalition: MemoryPressureCoalitionSampling {
    func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage? { nil }
}

@main
struct MemoryPressureCoalitionFixture {
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        if scenario == "coalition-child" {
            let allocation = UnsafeMutableRawPointer.allocate(
                byteCount: 64 * 1024 * 1024,
                alignment: MemoryLayout<UInt8>.alignment
            )
            allocation.initializeMemory(
                as: UInt8.self,
                repeating: 1,
                count: 64 * 1024 * 1024
            )
            FileHandle.standardOutput.write(Data("ready\n".utf8))
            dispatchMain()
            return
        }
        if scenario == "supported-os" {
            let versions = [13, 14, 15, 16, 25, 26, 27, 28, 99]
            try emit(Dictionary(uniqueKeysWithValues: versions.map {
                (String($0), DarwinMemoryPressureCoalitionSampler.coalitionABIIsSupported(
                    operatingSystemMajorVersion: $0
                ))
            }))
            return
        }

        if scenario == "live" {
            try await emitLiveCoalitionSample()
            return
        }

        let snapshot = CmuxTopProcessSnapshot(scenario: scenario)
        let sampler = DarwinMemoryPressureAggregateSampler(
            processID: 101,
            snapshotProvider: { snapshot },
            coalitionSampler: UnavailableCoalition(),
            physicalMemoryProvider: { scenario == "pid-reuse" ? 2_000 : 8_000 },
            availableMemoryProvider: { nil }
        )
        let sample = await sampler.sample(at: Date(timeIntervalSince1970: 1))
        var payload = sample.privacySafeDiagnosticPayload()
        payload["severity"] = MemoryPressureAggregatePolicy.default.severity(for: sample).logName
        payload["actionable"] = MemoryPressureAggregatePolicy.default.evaluate(sample: sample).isActionable
        try emit(payload)
    }

    private static func emitLiveCoalitionSample() async throws {
        let processID = Int(getpid())
        let sampler = DarwinMemoryPressureAggregateSampler(
            processID: processID,
            snapshotProvider: {
                CmuxTopProcessSnapshot(scenario: "complete-tree", rootPID: processID)
            },
            coalitionSampler: DarwinMemoryPressureCoalitionSampler(),
            physicalMemoryProvider: { ProcessInfo.processInfo.physicalMemory },
            availableMemoryProvider: { nil }
        )
        let baseline = await sampler.sample(at: Date(timeIntervalSince1970: 1))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["coalition-child"]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        let ready = output.fileHandleForReading.readData(ofLength: 6)
        guard String(data: ready, encoding: .utf8)?.contains("ready") == true else {
            child.terminate()
            child.waitUntilExit()
            throw NSError(domain: "MemoryPressureCoalitionFixture", code: 1)
        }

        let withChild = await sampler.sample(at: Date(timeIntervalSince1970: 2))
        child.terminate()
        child.waitUntilExit()
        var payload = withChild.privacySafeDiagnosticPayload()
        payload["baseline_aggregate_bytes"] = baseline.aggregateBytes.map { NSNumber(value: $0) } ?? NSNull()
        payload["child_delta_bytes"] = if let baselineBytes = baseline.aggregateBytes,
                                           let childBytes = withChild.aggregateBytes {
            NSNumber(value: childBytes > baselineBytes ? childBytes - baselineBytes : 0)
        } else {
            NSNull()
        }
        try emit(payload)
    }

    private static func emit(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
