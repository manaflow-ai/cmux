import CmuxiOSPairingCore

/// The signed-in account's B6 runtime (trust store mirror, owner sockets),
/// made on first use and shared; `reset` (sign-out, account switch) stops it.
actor PairingRuntimeCache {
    private var current: Task<PairingRuntime, any Error>?

    func runtime(_ make: @escaping @Sendable () async throws -> PairingRuntime) async throws -> PairingRuntime {
        if let current { return try await current.value }
        let task = Task { try await make() }
        current = task
        do {
            return try await task.value
        } catch {
            if current == task { current = nil }
            throw error
        }
    }

    func reset() async {
        let old = current
        current = nil
        if let runtime = try? await old?.value { await runtime.stop() }
    }
}
