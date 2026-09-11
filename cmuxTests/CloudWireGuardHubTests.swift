import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The hub lifecycle without a binary or a network: a scripted child process, an
/// immediate readiness probe, and a gated sleeper stand in for `cmux-tui wg hub`, the
/// socket, and the clock.
@Suite(.serialized)
struct CloudWireGuardHubTests {
    @Test
    func cancelledCallbackWaiterFinishesWithoutAValue() async {
        let first = CloudLinkFirstValue<String>()
        let task = Task { await first.result }
        await Task.yield()
        task.cancel()
        #expect(await task.value == nil)
    }

    /// A child process the test ends on demand.
    final class FakeProcess: CloudWireGuardHubProcess, @unchecked Sendable {
        let arguments: [String]
        private let lock = NSLock()
        private var running = true
        private var status: Int32?
        private var handler: (@Sendable (Int32) -> Void)?
        private(set) var terminateCalls = 0

        init(arguments: [String]) {
            self.arguments = arguments
        }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }

        var exitStatus: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return status
        }

        var outputTail: String { "fake hub output" }

        func terminate() {
            lock.lock()
            terminateCalls += 1
            lock.unlock()
            exit(status: 0)
        }

        func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
            lock.lock()
            if let status {
                lock.unlock()
                handler(status)
                return
            }
            self.handler = handler
            lock.unlock()
        }

        /// The process ends (crash or clean exit) and the hub hears about it.
        func exit(status: Int32) {
            lock.lock()
            guard running else {
                lock.unlock()
                return
            }
            running = false
            self.status = status
            let handler = self.handler
            self.handler = nil
            lock.unlock()
            handler?(status)
        }
    }

    final class FakeSpawner: CloudWireGuardHubSpawning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var processes: [FakeProcess] = []
        var failNextSpawn = false

        func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess {
            lock.lock()
            defer { lock.unlock() }
            if failNextSpawn {
                failNextSpawn = false
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such binary"])
            }
            let process = FakeProcess(arguments: arguments)
            processes.append(process)
            return process
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return processes.count
        }

        var last: FakeProcess? {
            lock.lock()
            defer { lock.unlock() }
            return processes.last
        }
    }

    actor AttemptCounter {
        private(set) var value = 0

        func next() -> Int {
            value += 1
            return value
        }
    }

    /// Sleeps park until the test releases them, so idle stops and restart backoffs run
    /// exactly when the test says the clock has reached them.
    actor SleepGate {
        private(set) var requested: [Duration] = []
        private var waiters: [CheckedContinuation<Void, Error>] = []

        func sleep(_ duration: Duration) async throws {
            requested.append(duration)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelAll() }
            }
        }

        func elapse() {
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }

        private func cancelAll() {
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume(throwing: CancellationError()) }
        }

        var pendingCount: Int { waiters.count }
    }

    private struct Harness {
        let hub: CloudWireGuardHub
        let spawner: FakeSpawner
        let gate: SleepGate
        let socketPath: String
        let configPath = "/tmp/cmux-app.conf"
        let routes = ["10.0.0.0/8", "fd00::/8"]
    }

    private func makeHarness(readiness: @escaping @Sendable (String) async throws -> Void = { _ in }) -> Harness {
        let spawner = FakeSpawner()
        let gate = SleepGate()
        let socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hub-test-\(UUID().uuidString.lowercased()).sock")
        let routes = ["10.0.0.0/8", "fd00::/8"]
        let configuration = CloudWireGuardHub.Configuration(
            enroll: { CloudWireGuardHub.Enrollment(configPath: "/tmp/cmux-app.conf", routes: routes) },
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: socketURL,
            spawner: spawner,
            waitUntilReady: readiness,
            sleep: { duration in try await gate.sleep(duration) },
            restartBackoff: [.seconds(1), .seconds(2)],
            idleGrace: .seconds(10)
        )
        return Harness(hub: CloudWireGuardHub(configuration: configuration), spawner: spawner, gate: gate, socketPath: socketURL.path)
    }

    /// Yields until the gate holds `count` parked sleeps (the hub schedules them on its
    /// own tasks), bounded by a generous number of turns.
    private func waitForPendingSleeps(_ gate: SleepGate, count: Int) async {
        for _ in 0..<2_000 {
            if await gate.pendingCount >= count { return }
            await Task.yield()
        }
    }

    private func waitUntilRunning(_ hub: CloudWireGuardHub) async {
        for _ in 0..<2_000 {
            if await hub.status().running { return }
            await Task.yield()
        }
    }

    private func waitForSpawnCount(_ spawner: FakeSpawner, count: Int) async {
        for _ in 0..<2_000 {
            if spawner.count >= count { return }
            await Task.yield()
        }
    }

    @Test
    func firstAcquireSpawnsTheHubAndLaterAcquiresReuseIt() async throws {
        let h = makeHarness()
        let first = try await h.hub.acquire()
        let second = try await h.hub.acquire()
        #expect(h.spawner.count == 1)
        #expect(first.ready == second.ready)
        #expect(first.ready.socketPath == h.socketPath)
        #expect(first.ready.routes == h.routes)
        #expect(h.spawner.last?.arguments == ["wg", "hub", "--config", h.configPath, "--socket", h.socketPath])
        let status = await h.hub.status()
        #expect(status.running)
        #expect(status.leases == 2)
        #expect(!status.pinnedByExternalClient)
    }

    @Test
    func prewarmHoldsAClaimUntilTheFleetIsEmpty() async throws {
        let h = makeHarness()
        let ready = try await h.hub.prewarm()
        #expect(ready.socketPath == h.socketPath)
        #expect(h.spawner.count == 1)
        #expect(await h.hub.status().leases == 1)

        _ = try await h.hub.prewarm()
        #expect(h.spawner.count == 1)
        await h.hub.releasePrewarm()
        await waitForPendingSleeps(h.gate, count: 1)
        #expect(await h.hub.status().leases == 0)
    }

    @Test
    func prewarmRetriesATransientStartupFailure() async throws {
        let attempts = AttemptCounter()
        let h = makeHarness(readiness: { _ in
            if await attempts.next() == 1 {
                throw CloudWireGuardHub.HubError.notReady("transient startup")
            }
        })
        let task = Task { try await h.hub.prewarm() }
        await waitForSpawnCount(h.spawner, count: 1)
        await waitForPendingSleeps(h.gate, count: 1)
        await h.gate.elapse()
        await waitForSpawnCount(h.spawner, count: 2)
        let ready = try await task.value
        #expect(ready.socketPath == h.socketPath)
        #expect(await attempts.value == 2)
        #expect(await h.hub.status().leases == 1)
    }

    @Test
    func hubStopsIdleGraceAfterTheLastRelease() async throws {
        let h = makeHarness()
        let a = try await h.hub.acquire()
        let b = try await h.hub.acquire()
        await h.hub.release(a.lease)
        // One lease still held: no idle stop scheduled.
        #expect(await h.gate.pendingCount == 0)
        await h.hub.release(b.lease)
        await waitForPendingSleeps(h.gate, count: 1)
        #expect(await h.gate.requested == [.seconds(10)])
        #expect(h.spawner.last?.isRunning == true)
        await h.gate.elapse()
        for _ in 0..<2_000 {
            if h.spawner.last?.isRunning != true { break }
            await Task.yield()
        }
        #expect(h.spawner.last?.isRunning == false)
        #expect(h.spawner.last?.terminateCalls == 1)
        #expect(await h.hub.status().running == false)
        // A crash-restart must not follow an intentional stop.
        #expect(h.spawner.count == 1)
    }

    @Test
    func reacquireDuringIdleGraceKeepsTheHub() async throws {
        let h = makeHarness()
        let a = try await h.hub.acquire()
        await h.hub.release(a.lease)
        await waitForPendingSleeps(h.gate, count: 1)
        _ = try await h.hub.acquire()
        // The idle stop was cancelled; elapsing its timer changes nothing.
        await h.gate.elapse()
        await Task.yield()
        #expect(h.spawner.count == 1)
        #expect(h.spawner.last?.isRunning == true)
        #expect(await h.hub.status().running)
    }

    @Test
    func unexpectedExitWhileLeasedRestartsWithBackoff() async throws {
        let h = makeHarness()
        _ = try await h.hub.acquire()
        let first = try #require(h.spawner.last)
        first.exit(status: 1)
        await waitForPendingSleeps(h.gate, count: 1)
        #expect(await h.gate.requested == [.seconds(1)])
        #expect(await h.hub.status().running == false)
        await h.gate.elapse()
        await waitForSpawnCount(h.spawner, count: 2)
        await waitUntilRunning(h.hub)
        let status = await h.hub.status()
        #expect(status.running)
        #expect(status.leases == 1)
        #expect(h.spawner.count == 2)
    }

    @Test
    func restartsAreBoundedByTheBackoffTable() async throws {
        let h = makeHarness()
        _ = try await h.hub.acquire()
        for attempt in 0..<2 {
            try #require(h.spawner.last).exit(status: 1)
            await waitForPendingSleeps(h.gate, count: 1)
            await h.gate.elapse()
            await waitForSpawnCount(h.spawner, count: attempt + 2)
            await waitUntilRunning(h.hub)
        }
        // Third crash: the two-entry table is exhausted, no further spawn.
        try #require(h.spawner.last).exit(status: 1)
        await Task.yield()
        for _ in 0..<200 { await Task.yield() }
        #expect(h.spawner.count == 3)
        #expect(await h.gate.pendingCount == 0)
        let status = await h.hub.status()
        #expect(!status.running)
        #expect(status.lastError?.contains("keeps exiting") == true)
        // The next explicit acquire starts over.
        _ = try await h.hub.acquire()
        #expect(h.spawner.count == 4)
    }

    @Test
    func intentionalStopTerminatesWithoutRestart() async throws {
        let h = makeHarness()
        _ = try await h.hub.acquire()
        await h.hub.stop()
        for _ in 0..<200 { await Task.yield() }
        #expect(h.spawner.last?.isRunning == false)
        #expect(h.spawner.last?.terminateCalls == 1)
        #expect(h.spawner.count == 1)
        let status = await h.hub.status()
        #expect(!status.running)
        #expect(status.leases == 0)
        #expect(await h.gate.pendingCount == 0)
    }

    @Test
    func exitBeforeReadyFailsTheAcquireAndDropsTheLease() async throws {
        let h = makeHarness(readiness: { _ in
            // Never ready; the process death must win the race.
            try await Task.sleep(for: .seconds(30))
        })
        let task = Task { try await h.hub.acquire() }
        await waitForSpawnCount(h.spawner, count: 1)
        try #require(h.spawner.last).exit(status: 3)
        await #expect(throws: CloudWireGuardHub.HubError.self) { try await task.value }
        let status = await h.hub.status()
        #expect(!status.running)
        #expect(status.leases == 0)
        #expect(status.lastError?.contains("status 3") == true)
    }

    @Test
    func spawnFailureSurfacesAsHubError() async throws {
        let h = makeHarness()
        h.spawner.failNextSpawn = true
        await #expect(throws: CloudWireGuardHub.HubError.self) { _ = try await h.hub.acquire() }
        #expect(await h.hub.status().leases == 0)
    }

    @Test
    func externalPinKeepsTheHubAfterAppLeasesEnd() async throws {
        let h = makeHarness()
        let ready = try await h.hub.pinForExternalClient()
        #expect(ready.socketPath == h.socketPath)
        let a = try await h.hub.acquire()
        await h.hub.release(a.lease)
        for _ in 0..<200 { await Task.yield() }
        // Pinned: no idle stop is scheduled and the hub keeps running.
        #expect(await h.gate.pendingCount == 0)
        let status = await h.hub.status()
        #expect(status.running)
        #expect(status.pinnedByExternalClient)
        // Only an explicit stop ends it.
        await h.hub.stop()
        #expect(await h.hub.status().running == false)
    }

    @Test
    func routesHostUsesEnrolledRoutesWhenKnownElsePrivateRanges() {
        #expect(CloudWireGuardHub.routesHost("10.100.0.10", enrolledRoutes: []))
        #expect(!CloudWireGuardHub.routesHost("100.64.0.1", enrolledRoutes: []))
        #expect(CloudWireGuardHub.routesHost("100.64.0.1", enrolledRoutes: ["100.64.0.0/10"]))
        #expect(!CloudWireGuardHub.routesHost("10.100.0.10", enrolledRoutes: ["100.64.0.0/10"]))
    }
}
