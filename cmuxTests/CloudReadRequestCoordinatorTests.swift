import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#else
@testable import CloudReadFixture
#endif

@Suite("Cloud read deadline and cancellation", .timeLimit(.minutes(1)))
struct CloudReadRequestCoordinatorTests {
    private typealias Owner = CloudReadRequestCoordinator
    private func key(_ id: String = "vm", account: String = "fixture", generation: UInt64 = 1) -> Owner.Key {
        .init(path: id, accountID: account, generation: generation, teamID: "team")
    }
    private func response(_ status: Int = 200) -> Owner.Response {
        .init(data: Data(), http: HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    @Test("Four owners issue one request per machine", arguments: [1, 10, 100, 1000])
    func scale(machines: Int) async throws {
        let gate = CloudReadResponseGate()
        let owner = Owner()
        let tasks = (0..<(machines * 4)).map { index in
            Task { try await owner.read(key("vm-\(index % machines)")) { await gate.read(response()) } }
        }
        try await eventually { await owner.entries.values.reduce(0) { $0 + $1.waiters.count } == machines * 4 }
        await gate.release()
        for task in tasks { _ = try await task.value }
        #expect(await gate.requests == machines)
        #expect(await owner.entries.isEmpty)
        print("cloud-read-scale machines=\(machines) owners=4 requests=\(await gate.requests) requests_per_machine=1")
    }

    @Test("Cancelling one waiter preserves another; the last cancels and holds the draining slot")
    func independentCancellation() async throws {
        let gate = CloudReadResponseGate()
        let owner = Owner()
        let first = Task { try await owner.read(key()) { await gate.read(response()) } }
        let second = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await owner.entries.values.first?.waiters.count == 2 }
        try await eventually { await gate.requests == 1 }
        first.cancel()
        do { _ = try await first.value; Issue.record("cancelled waiter returned a value") } catch is CancellationError {} catch { Issue.record("\(error)") }
        #expect(await owner.entries.values.first?.waiters.count == 1)
        second.cancel()
        _ = await second.result
        let replacement = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await owner.entries.values.first?.pending?.waiters.count == 1 }
        #expect(await gate.requests == 1)
        await gate.release()
        #expect(try await replacement.value.http.statusCode == 200)
        #expect(await gate.requests == 2)
        try await eventually { await owner.entries.isEmpty }
    }

    @Test("Deadline returns before an uncooperative loader, retaining only its draining slot")
    func deadlineDoesNotJoinStuckChild() async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock), budget: .seconds(30))
        let gate = CloudReadResponseGate()
        let task = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await gate.requests == 1 }
        clock.advance(by: .seconds(31))
        do { _ = try await task.value; Issue.record("expired request succeeded") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(await owner.entries.count == 1)
        #expect(await owner.entries.values.first?.waiters.isEmpty == true)
        await gate.release()
        try await eventually { await owner.entries.isEmpty }
    }

    @Test("A queued replacement has its own deadline while old cleanup stays held")
    func queuedReplacementDeadline() async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock), budget: .seconds(30))
        let gate = CloudReadResponseGate()
        let first = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await gate.requests == 1 }
        first.cancel()
        _ = await first.result
        let replacement = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await owner.entries.values.first?.pending?.waiters.count == 1 }
        clock.advance(by: .seconds(31))
        do { _ = try await replacement.value; Issue.record("queued deadline missed") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(await gate.requests == 1)
        await gate.release()
        try await eventually { await owner.entries.isEmpty }
    }

    @Test("Time spent acquiring read scope consumes the original budget")
    func admissionUsesOriginalDeadline() async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let deadline = owner.makeDeadline()
        clock.advance(by: .seconds(600), deliverTimers: false)
        do {
            _ = try await owner.read(key(), deadline: deadline) { Issue.record("started after admission expired"); return response() }
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(await owner.entries.isEmpty)
    }

    @Test("A short waiter cannot shorten another caller's deadline", arguments: [false, true], [false, true])
    func independentDeadlines(queued: Bool, deliverTimers: Bool) async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let gate = CloudReadResponseGate()
        if queued {
            let retired = Task { try await owner.read(key()) { await gate.read(response()) } }
            try await eventually { await gate.requests == 1 }
            retired.cancel()
            _ = await retired.result
        }
        let long = Task { try await owner.read(key(), deadline: .seconds(20)) { await gate.read(response()) } }
        try await eventually {
            let entry = await owner.entries.values.first
            return queued ? entry?.pending?.waiters.count == 1 : entry?.waiters.count == 1
        }
        let short = Task { try await owner.read(key(), deadline: .seconds(1)) { await gate.read(response()) } }
        try await eventually {
            let entry = await owner.entries.values.first
            return queued ? entry?.pending?.waiters.count == 2 : entry?.waiters.count == 2
        }
        clock.advance(by: .seconds(2), deliverTimers: deliverTimers)
        if deliverTimers {
            _ = await short.result
            let entry = await owner.entries.values.first
            #expect(queued ? entry?.pending?.waiters.count == 1 : entry?.waiters.count == 1)
        }
        await gate.release()
        do { _ = try await short.value; Issue.record("short waiter exceeded its deadline") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(try await long.value.http.statusCode == 200)
        #expect(await gate.requests == (queued ? 2 : 1))
        #expect(await owner.entries.isEmpty)
    }

    @Test("Response-first delivery after a simulated wake still expires")
    func responseAfterDeadline() async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let gate = CloudReadResponseGate()
        let task = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await gate.requests == 1 }
        try await eventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: .seconds(600), deliverTimers: false)
        await gate.release()
        do { _ = try await task.value; Issue.record("late response succeeded") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
    }

    @Test("A reader arriving after wake waits for a fresh pass instead of inheriting the old timeout")
    func freshReaderAfterWake() async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let gate = CloudReadResponseGate()
        let old = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await gate.requests == 1 && clock.pendingSleeperCount == 1 }
        clock.advance(by: .seconds(600), deliverTimers: false)
        let fresh = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await owner.entries.values.first?.pending?.waiters.count == 1 }
        await gate.release()
        do { _ = try await old.value; Issue.record("old request survived its deadline") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(try await fresh.value.http.statusCode == 200)
        #expect(await gate.requests == 2)
    }

    @Test("Retry-After survives operation completion and offline recovery")
    func serverCooldown() async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let throttled = response(429)
        let first = try await owner.read(key()) {
            #expect(await owner.noteRetryAfter(key(), seconds: 60, response: throttled) == false)
            return throttled
        }
        #expect(first.http.statusCode == 429)
        await owner.networkChanged(isOnline: false)
        await owner.networkChanged(isOnline: true)
        let cached = try await owner.read(key()) { Issue.record("retried before the server allowed it"); return response() }
        #expect(cached.http.statusCode == 429)
        clock.advance(by: .seconds(60))
        let recovered = try await owner.read(key()) { response() }
        #expect(recovered.http.statusCode == 200)
    }

    @Test("An arbitrarily long Retry-After does not overflow or become an early retry")
    func oversizedRetryAfter() async throws {
        let owner = Owner()
        let throttled = response(429)
        _ = try await owner.read(key()) {
            #expect(await owner.noteRetryAfter(key(), seconds: TimeInterval(Int.max), response: throttled) == false)
            return throttled
        }
        #expect(try await owner.read(key()) { Issue.record("ignored long server cooldown"); return response() }.http.statusCode == 429)
    }

    @Test("Offline cancels readers, refuses more work, and reconnect recovers")
    func offlineRecovery() async throws {
        let owner = Owner()
        let gate = CloudReadResponseGate()
        let task = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await gate.requests == 1 }
        await owner.networkChanged(isOnline: false)
        do { _ = try await task.value; Issue.record("offline returned live data") }
        catch { #expect((error as? URLError)?.code == .notConnectedToInternet) }
        await gate.release()
        try await eventually { await owner.entries.isEmpty }
        do { _ = try await owner.read(key()) { Issue.record("started offline"); return response() } }
        catch { #expect((error as? URLError)?.code == .notConnectedToInternet) }
        await owner.networkChanged(isOnline: true)
        #expect(try await owner.read(key()) { response() }.http.statusCode == 200)
    }

    @Test("Account and session generations never share responses")
    func identityIsolation() async throws {
        let owner = Owner()
        let gate = CloudReadResponseGate()
        let first = Task { try await owner.read(key()) { await gate.read(response()) } }
        let replacement = try await owner.read(key(generation: 2)) { response(201) }
        #expect(replacement.http.statusCode == 201)
        await gate.release()
        #expect(try await first.value.http.statusCode == 200)
    }

    @Test("A mutation landing during a read shares one fresh trailing pass")
    func mutationInvalidatesRunningRead() async throws {
        let owner = Owner()
        let gate = CloudReadResponseGate()
        let operation: @Sendable () async -> Owner.Response = {
            await gate.read(response(await gate.requests == 0 ? 200 : 201))
        }
        let first = Task { try await owner.read(key(), operation: operation) }
        try await eventually { await gate.requests == 1 }
        await owner.invalidate()
        let second = Task { try await owner.read(key(), operation: operation) }
        try await eventually { await owner.entries.values.first?.waiters.count == 2 }
        await gate.release()
        #expect(try await first.value.http.statusCode == 201)
        #expect(try await second.value.http.statusCode == 201)
        #expect(await gate.requests == 2)
    }

    private func eventually(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition(), "Fixture did not reach its expected actor state")
    }
}

actor CloudReadResponseGate {
    private(set) var requests = 0
    private var released = false
    private var waiting: [(CloudReadRequestCoordinator.Response, CheckedContinuation<CloudReadRequestCoordinator.Response, Never>)] = []
    func read(_ response: CloudReadRequestCoordinator.Response) async -> CloudReadRequestCoordinator.Response {
        requests += 1
        if released { return response }
        return await withCheckedContinuation { waiting.append((response, $0)) }
    }
    func release() {
        released = true
        let pending = waiting
        waiting.removeAll()
        for (response, continuation) in pending { continuation.resume(returning: response) }
    }
}
