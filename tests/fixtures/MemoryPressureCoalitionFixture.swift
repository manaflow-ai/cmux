import Darwin
import Foundation

// Only the snapshot dependency is replaced. The sampler, coalition ABI and
// pressure policy are compiled from their unchanged production source files.
enum FixtureMemorySource: Sendable {
    case physicalFootprint, unavailable
}

struct FixtureProcess: Sendable {
    let pid: Int
    let memoryBytes: Int64
    let memorySource: FixtureMemorySource
}

struct CmuxTopProcessSnapshot: Sendable {
    let enumerationIsComplete = true
    let enumerationMissingProcessCount = 0
    private let processes: [FixtureProcess]

    init(unreadableLogin: Bool) {
        processes = [
            FixtureProcess(pid: Int(getpid()), memoryBytes: 100, memorySource: .physicalFootprint),
            FixtureProcess(pid: 1_000_001, memoryBytes: unreadableLogin ? -1 : 10,
                           memorySource: unreadableLogin ? .unavailable : .physicalFootprint),
            FixtureProcess(pid: 1_000_002, memoryBytes: 2_000, memorySource: .physicalFootprint)
        ]
    }

    static func captureCached(
        includeProcessDetails: Bool, includeCMUXScope: Bool, maximumAge: TimeInterval
    ) async -> Self {
        fatalError("The probe must use its injected process snapshot")
    }

    func expandedPIDs(rootPIDs: [Int]) -> Set<Int> {
        precondition(rootPIDs == [Int(getpid())])
        // A fixed app -> unreadable login -> memory-consuming child fixture.
        return Set(processes.map(\.pid))
    }

    func process(pid: Int) -> FixtureProcess? {
        processes.first { $0.pid == pid }
    }
}

private struct UnavailableCoalition: MemoryPressureCoalitionSampling {
    func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage? { nil }
}

@main
struct MemoryPressureCoalitionFixture {
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        if scenario == "supported-os" {
            let versions = [13, 14, 15, 16, 25, 26, 27, 28, 99]
            try emit(Dictionary(uniqueKeysWithValues: versions.map {
                (String($0), DarwinMemoryPressureCoalitionSampler.coalitionABIIsSupported(
                    operatingSystemMajorVersion: $0
                ))
            }))
            return
        }
        if scenario == "invalid-pids" {
            let coalition = DarwinMemoryPressureCoalitionSampler()
            try emit([0, -1].map { coalition.usage(forProcessID: $0) == nil })
            return
        }

        let snapshot = CmuxTopProcessSnapshot(unreadableLogin: scenario != "complete-tree")
        let coalition: any MemoryPressureCoalitionSampling
        if scenario == "live" {
            coalition = DarwinMemoryPressureCoalitionSampler()
        } else {
            coalition = UnavailableCoalition()
        }
        let sampler = DarwinMemoryPressureAggregateSampler(
            snapshotProvider: { snapshot },
            coalitionSampler: coalition,
            // A synthetic threshold exercises policy without creating pressure
            // or invoking any responder that could hibernate a process.
            physicalMemoryProvider: { 1_000 },
            availableMemoryProvider: { nil }
        )
        let sample = await sampler.sample(at: Date(timeIntervalSince1970: 1))
        var payload = sample.privacySafeDiagnosticPayload()
        payload["actionable"] = MemoryPressureAggregatePolicy.default.evaluate(sample: sample).isActionable
        try emit(payload)
    }

    private static func emit(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
