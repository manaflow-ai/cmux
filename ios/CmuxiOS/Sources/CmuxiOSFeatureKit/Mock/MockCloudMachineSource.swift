import Foundation

/// A `CloudMachineSource` over sample machines: one running, one paused by
/// the idle backstop, on a plan with one locked size. Refusals use the
/// owner's error codes, like the real source.
public final class MockCloudMachineSource: CloudMachineSource {
    public let hub: MockSnapshotHub<CloudState>

    public init(state: CloudState = MockCloudMachineSource.sample()) {
        hub = MockSnapshotHub(state)
    }

    public func updates() async -> AsyncStream<SourceSnapshot<CloudState>> {
        await hub.stream()
    }

    public func perform(_ intent: CloudIntent, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { state in
            switch intent {
            case .create(let name, let size):
                let active = state.machines.filter { $0.status != .paused }.count
                if let plan = state.plan, active >= plan.limits.maxActive { throw MockRefusal("cloud.quota.exceeded") }
                if let memory = size.memoryMB, state.plan?.limits.lockedMemoryOptionsMB.contains(memory) == true {
                    throw MockRefusal("cloud.size.locked")
                }
                let id = "vm_" + String(key.rawValue.filter(\.isLetter).prefix(20)).padding(toLength: 20, withPad: "0", startingAt: 0)
                state.machines.append(CloudMachine(id: id, name: name, size: size, status: .running,
                                                   host: HostID("host_" + id.dropFirst(3)), createdAt: Date()))
            case .start(let id):
                try Self.update(id, in: &state) { $0.status = .running; $0.pauseReason = nil }
            case .pause(let id):
                try Self.update(id, in: &state) { $0.status = .paused; $0.pauseReason = nil }
            case .delete(let id):
                guard state.machines.contains(where: { $0.id == id }) else { throw MockRefusal("cloud.machine.not_found") }
                state.machines.removeAll { $0.id == id }
            case .rename(let id, let name):
                try Self.update(id, in: &state) { $0.name = name }
            }
            state.plan?.usage.active = state.machines.filter { $0.status != .paused }.count
            state.plan?.usage.saved = state.machines.filter { $0.status == .paused }.count
        }
    }

    private static func update(_ id: String, in state: inout CloudState, _ change: (inout CloudMachine) -> Void) throws {
        guard let index = state.machines.firstIndex(where: { $0.id == id }) else { throw MockRefusal("cloud.machine.not_found") }
        change(&state.machines[index])
    }

    public static func sample() -> CloudState {
        let size = CloudMachineSize(cpu: 2, memoryMB: 4096, diskMB: 16384)
        return CloudState(
            machines: [
                CloudMachine(id: "vm_mockdevbox0000000001", name: "devbox", size: size, status: .running,
                             daemonVersion: "0.1.0", host: HostID("host_mockdevbox000000001"),
                             createdAt: Date(timeIntervalSince1970: 1_790_000_000), revision: 3),
                CloudMachine(id: "vm_mockscratch00000002", name: "scratch", size: size, status: .paused,
                             host: HostID("host_mockscratch00000002"), createdAt: Date(timeIntervalSince1970: 1_790_100_000),
                             pauseReason: .idle, revision: 5),
            ],
            plan: CloudPlan(planID: "dev", upgradePlan: "pro",
                            limits: CloudPlanLimits(maxActive: 2, maxSaved: 4, memoryOptionsMB: [2048, 4096, 8192, 16384],
                                                    lockedMemoryOptionsMB: [16384], vmHoursIncluded: 100),
                            usage: CloudPlanUsage(active: 1, saved: 1, vmHoursUsed: 12.5,
                                                  periodEnd: Date(timeIntervalSince1970: 1_793_000_000))),
            isLoaded: true
        )
    }
}
