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

struct CmuxTopProcessSnapshot: Sendable {
    let enumerationIsComplete: Bool
    let enumerationMissingProcessCount: Int
    private let processes: [FixtureProcess]

    init(scenario: String) {
        let unreadableLogin = scenario == "unreadable-login" || scenario == "exiting-child"
        let unreadableChild = scenario == "unreadable-child"
        let reusedChild = scenario == "pid-reuse"
        let missingCount = scenario == "exiting-child" ? 1 : 0
        processes = [
            FixtureProcess(pid: 101, parentPID: 1, memoryBytes: 1_000, memorySource: .physicalFootprint),
            FixtureProcess(
                pid: 202,
                parentPID: 101,
                memoryBytes: unreadableLogin ? 0 : 100,
                memorySource: unreadableLogin ? .unavailable : .physicalFootprint
            ),
            FixtureProcess(pid: 303, parentPID: 202, memoryBytes: 200, memorySource: .physicalFootprint),
            FixtureProcess(
                pid: 404,
                parentPID: reusedChild ? 505 : 303,
                memoryBytes: unreadableChild ? 0 : 3_000,
                memorySource: unreadableChild ? .unavailable : .physicalFootprint
            )
        ]
        enumerationIsComplete = missingCount == 0
        enumerationMissingProcessCount = missingCount
    }

    func expandedPIDs(rootPIDs: [Int]) -> Set<Int> {
        precondition(rootPIDs == [101])
        var childrenByParent: [Int: [Int]] = [:]
        for process in processes {
            childrenByParent[process.parentPID, default: []].append(process.pid)
        }
        var result: Set<Int> = []
        var stack = rootPIDs
        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }

    func process(pid: Int) -> FixtureProcess? {
        processes.first { $0.pid == pid }
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
        if scenario == "supported-os" {
            let versions = [13, 14, 15, 16, 25, 26, 27, 28, 99]
            try emit(Dictionary(uniqueKeysWithValues: versions.map {
                (String($0), DarwinMemoryPressureCoalitionSampler.coalitionABIIsSupported(
                    operatingSystemMajorVersion: $0
                ))
            }))
            return
        }

        let snapshot = CmuxTopProcessSnapshot(scenario: scenario)
        let sampler = DarwinMemoryPressureAggregateSampler(
            processID: 101,
            snapshotProvider: { snapshot },
            coalitionSampler: UnavailableCoalition(),
            physicalMemoryProvider: { 8_000 },
            availableMemoryProvider: { nil }
        )
        let sample = await sampler.sample(at: Date(timeIntervalSince1970: 1))
        var payload = sample.privacySafeDiagnosticPayload()
        payload["severity"] = MemoryPressureAggregatePolicy.default.severity(for: sample).logName
        payload["actionable"] = MemoryPressureAggregatePolicy.default.evaluate(sample: sample).isActionable
        try emit(payload)
    }

    private static func emit(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
