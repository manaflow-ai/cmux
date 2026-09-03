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
    /// A child process the test ends on demand.
    final class FakeProcess: CloudWireGuardHubProcess, @unchecked Sendable {
        let arguments: [String]
        private let lock = NSLock()
        private var running = true
        private var status: Int32?
        private var handler: (@Sendable (Int32) -> Void)?
        private(set) var terminateCalls = 0
        let stdoutLines: AsyncStream<String>
        private let stdout: AsyncStream<String>.Continuation

        init(arguments: [String]) {
            self.arguments = arguments
            (stdoutLines, stdout) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        }

        /// The hub's readiness announcement, as `cmux-tui wg hub` prints it.
        func announceReady(socket: String, routes: [String]) {
            let quoted = routes.map { "\"\($0)\"" }.joined(separator: ",")
            stdout.yield("{\"event\":\"hub-ready\",\"socket\":\"\(socket)\",\"routes\":[\(quoted)]}")
        }

        func emitStdout(_ line: String) { stdout.yield(line) }

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
            stdout.finish()
            handler?(status)
        }
    }

    final class FakeSpawner: CloudWireGuardHubSpawning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var processes: [FakeProcess] = []
        var failNextSpawn = false
        /// When set, every spawned hub announces readiness at once with these routes,
        /// like a healthy `wg hub`. Nil leaves the announcement to the test.
        var announceRoutesOnSpawn: [String]? = ["10.0.0.0/8", "fd00::/8"]

        func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess {
            lock.lock()
            defer { lock.unlock() }
            if failNextSpawn {
                failNextSpawn = false
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such binary"])
            }
            let process = FakeProcess(arguments: arguments)
            processes.append(process)
            if let routes = announceRoutesOnSpawn {
                let socket = arguments.firstIndex(of: "--socket").map { arguments[$0 + 1] } ?? ""
                process.emitStdout("starting")
                process.announceReady(socket: socket, routes: routes)
            }
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

    /// Sleeps park until the test releases them, so idle stops and restart backoffs run
    /// exactly when the test says the clock has reached them. Each sleep is keyed by
    /// its duration, so a test elapses the idle grace without touching the ready
    /// timeout that every start races against.
    actor SleepGate {
        private var nextID = 0
        private var waiters: [Int: (duration: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
        private(set) var requested: [Duration] = []

        func sleep(_ duration: Duration) async throws {
            let id = nextID
            nextID += 1
            requested.append(duration)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    waiters[id] = (duration, continuation)
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: Int) {
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }

        /// Wakes every sleeper parked on `duration`.
        func elapse(_ duration: Duration) {
            for (id, waiter) in waiters where waiter.duration == duration {
                waiters.removeValue(forKey: id)
                waiter.continuation.resume()
            }
        }

        func pending(_ duration: Duration) -> Int {
            waiters.values.filter { $0.duration == duration }.count
        }

        /// Durations requested other than the ready timeout, which every start races.
        var requestedTimers: [Duration] { requested.filter { $0 != CloudWireGuardHubTests.readyTimeout } }
    }

    private static let readyTimeout: Duration = .seconds(20)
    private static let idleGrace: Duration = .seconds(10)

    private struct Harness {
        let hub: CloudWireGuardHub
        let spawner: FakeSpawner
        let gate: SleepGate
        let socketPath: String
        let configPath = "/tmp/cmux-app.conf"
        let routes = ["10.0.0.0/8", "fd00::/8"]
    }

    private func makeHarness(
        verifySocket: @escaping @Sendable (String) -> Bool = { _ in true },
        enrolledRoutes: [String] = ["10.0.0.0/8", "fd00::/8"]
    ) -> Harness {
        let spawner = FakeSpawner()
        let gate = SleepGate()
        let socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hub-test-\(UUID().uuidString.lowercased()).sock")
        let configuration = CloudWireGuardHub.Configuration(
            enroll: { CloudWireGuardHub.Enrollment(configPath: "/tmp/cmux-app.conf", routes: enrolledRoutes) },
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: socketURL,
            spawner: spawner,
            verifySocket: verifySocket,
            readyTimeout: Self.readyTimeout,
            sleep: { duration in try await gate.sleep(duration) },
            restartBackoff: [.seconds(1), .seconds(2)],
            idleGrace: Self.idleGrace
        )
        return Harness(hub: CloudWireGuardHub(configuration: configuration), spawner: spawner, gate: gate, socketPath: socketURL.path)
    }

    /// Yields until the gate holds `count` parked sleeps (the hub schedules them on its
    /// own tasks), bounded by a generous number of turns.
    private func waitForPendingSleep(_ gate: SleepGate, _ duration: Duration) async {
        for _ in 0..<2_000 {
            if await gate.pending(duration) >= 1 { return }
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
    func hubStopsIdleGraceAfterTheLastRelease() async throws {
        let h = makeHarness()
        let a = try await h.hub.acquire()
        let b = try await h.hub.acquire()
        await h.hub.release(a.lease)
        // One lease still held: no idle stop scheduled.
        #expect(await h.gate.pending(Self.idleGrace) == 0)
        await h.hub.release(b.lease)
        await waitForPendingSleep(h.gate, Self.idleGrace)
        #expect(await h.gate.requestedTimers == [Self.idleGrace])
        #expect(h.spawner.last?.isRunning == true)
        await h.gate.elapse(Self.idleGrace)
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
        await waitForPendingSleep(h.gate, Self.idleGrace)
        _ = try await h.hub.acquire()
        // The idle stop was cancelled; elapsing its timer changes nothing.
        await h.gate.elapse(Self.idleGrace)
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
        await waitForPendingSleep(h.gate, .seconds(1))
        #expect(await h.gate.requestedTimers == [.seconds(1)])
        #expect(await h.hub.status().running == false)
        await h.gate.elapse(.seconds(1))
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
            let delay: Duration = attempt == 0 ? .seconds(1) : .seconds(2)
            await waitForPendingSleep(h.gate, delay)
            await h.gate.elapse(delay)
            await waitForSpawnCount(h.spawner, count: attempt + 2)
            await waitUntilRunning(h.hub)
        }
        // Third crash: the two-entry table is exhausted, no further spawn.
        try #require(h.spawner.last).exit(status: 1)
        await Task.yield()
        for _ in 0..<200 { await Task.yield() }
        #expect(h.spawner.count == 3)
        #expect(await h.gate.pending(.seconds(1)) == 0)
        #expect(await h.gate.pending(.seconds(2)) == 0)
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
        #expect(await h.gate.pending(Self.idleGrace) == 0)
        #expect(await h.gate.pending(.seconds(1)) == 0)
    }

    @Test
    func exitBeforeReadyFailsTheAcquireAndDropsTheLease() async throws {
        let h = makeHarness()
        // The hub never announces readiness; its death must end the acquire.
        h.spawner.announceRoutesOnSpawn = nil
        let task = Task { try await h.hub.acquire() }
        await waitForSpawnCount(h.spawner, count: 1)
        try #require(h.spawner.last).exit(status: 3)
        await #expect(throws: CloudWireGuardHub.HubError.self) { try await task.value }
        let status = await h.hub.status()
        #expect(!status.running)
        #expect(status.leases == 0)
        // The exit status is the attributed failure, not the incidental stdout EOF that
        // ends the reader at the same moment.
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
        #expect(await h.gate.pending(Self.idleGrace) == 0)
        let status = await h.hub.status()
        #expect(status.running)
        #expect(status.pinnedByExternalClient)
        // Only an explicit stop ends it.
        await h.hub.stop()
        #expect(await h.hub.status().running == false)
    }

    @Test
    func readyRoutesComeFromTheHubAnnouncementNotTheEnrollment() async throws {
        let h = makeHarness(enrolledRoutes: ["192.168.0.0/16"])
        h.spawner.announceRoutesOnSpawn = ["100.64.0.0/10"]
        let claim = try await h.hub.acquire()
        #expect(claim.ready.routes == ["100.64.0.0/10"])
        #expect(claim.ready.socketPath == h.socketPath)
    }

    @Test
    func enrollmentRoutesAreTheFallbackWhenTheHubAnnouncesNone() async throws {
        let h = makeHarness(enrolledRoutes: ["10.0.0.0/8"])
        h.spawner.announceRoutesOnSpawn = []
        let claim = try await h.hub.acquire()
        #expect(claim.ready.routes == ["10.0.0.0/8"])
    }

    @Test
    func noAnnouncementWithinTheTimeoutFailsTheStart() async throws {
        let h = makeHarness()
        h.spawner.announceRoutesOnSpawn = nil
        let task = Task { try await h.hub.acquire() }
        await waitForSpawnCount(h.spawner, count: 1)
        // A hub that prints anything but hub-ready is still not ready.
        h.spawner.last?.emitStdout("{\"event\":\"something-else\"}")
        await waitForPendingSleep(h.gate, Self.readyTimeout)
        await h.gate.elapse(Self.readyTimeout)
        await #expect(throws: CloudWireGuardHub.HubError.self) { try await task.value }
        #expect(h.spawner.last?.isRunning == false)
        #expect(await h.hub.status().leases == 0)
    }

    @Test
    func announcedSocketThatDoesNotAcceptFailsTheStart() async throws {
        let h = makeHarness(verifySocket: { _ in false })
        await #expect(throws: CloudWireGuardHub.HubError.self) { _ = try await h.hub.acquire() }
        #expect(h.spawner.last?.isRunning == false)
    }

    @Test
    func readyEventParsesOnlyTheHubReadyLine() {
        let line = "{\"event\":\"hub-ready\",\"socket\":\"/w/hub-1.sock\",\"routes\":[\"10.0.0.0/8\",\"fd00::/8\"]}"
        let event = CloudWireGuardHubReadyEvent(line: line)
        #expect(event?.socketPath == "/w/hub-1.sock")
        #expect(event?.routes == ["10.0.0.0/8", "fd00::/8"])
        #expect(CloudWireGuardHubReadyEvent(line: "{\"event\":\"other\",\"socket\":\"/x\"}") == nil)
        #expect(CloudWireGuardHubReadyEvent(line: "not json") == nil)
        #expect(CloudWireGuardHubReadyEvent(line: "{\"event\":\"hub-ready\"}") == nil)
    }

    @Test
    func routesHostUsesEnrolledRoutesWhenKnownElsePrivateRanges() {
        #expect(CloudWireGuardHub.routesHost("10.100.0.10", enrolledRoutes: []))
        #expect(!CloudWireGuardHub.routesHost("100.64.0.1", enrolledRoutes: []))
        #expect(CloudWireGuardHub.routesHost("100.64.0.1", enrolledRoutes: ["100.64.0.0/10"]))
        #expect(!CloudWireGuardHub.routesHost("10.100.0.10", enrolledRoutes: ["100.64.0.0/10"]))
    }
}
