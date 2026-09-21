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
    private func key(_ id: String = "vm", account: String = "fixture", generation: UInt64 = 1, team: String = "team") -> Owner.Key {
        .init(path: id, accountID: account, generation: generation, teamID: team)
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

    @Test("Reachability changes fan out to every panel subscriber")
    func networkChangesBroadcast() async {
        let owner = Owner()
        let first = await owner.networkChanges()
        let second = await owner.networkChanges()
        let firstValue = Task {
            var iterator = first.makeAsyncIterator()
            return await iterator.next()
        }
        let secondValue = Task {
            var iterator = second.makeAsyncIterator()
            return await iterator.next()
        }
        await owner.networkChanged(isOnline: false)
        #expect(await firstValue.value == .some(false))
        #expect(await secondValue.value == .some(false))
    }

    @Test("A late reachability subscriber receives the current offline state")
    func networkChangesReplayCurrentState() async {
        let owner = Owner()
        await owner.networkChanged(isOnline: false)
        let stream = await owner.networkChanges()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .some(false))
    }

    @Test("The final waiter cancels and holds the draining slot after another caller leaves", arguments: [false, true])
    func independentCancellation(expireFirst: Bool) async throws {
        let gate = CloudReadResponseGate()
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let first = Task { try await owner.read(key(), deadline: .seconds(5)) { await gate.read(response()) } }
        try await eventually { await gate.requests == 1 }
        let second = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await owner.entries.values.first?.waiters.count == 2 }
        if expireFirst { clock.advance(by: .seconds(6)) } else { first.cancel() }
        do { _ = try await first.value; Issue.record("retired waiter returned a value") }
        catch is CancellationError { #expect(!expireFirst) }
        catch { #expect(expireFirst && (error as? URLError)?.code == .timedOut) }
        #expect(await owner.entries.values.first?.waiters.count == 1)
        second.cancel()
        do { _ = try await second.value; Issue.record("final cancelled waiter returned a value") }
        catch is CancellationError {} catch { Issue.record("\(error)") }
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

    @Test("An elapsed first caller cannot shorten a later caller's budget", arguments: [false, true], [false, true])
    func shortFirstDeadline(queued: Bool, deliverTimers: Bool) async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let gate = CloudReadResponseGate()
        if queued {
            let retired = Task { try await owner.read(key()) { await gate.read(response()) } }
            try await eventually { await gate.requests == 1 }
            retired.cancel()
            _ = await retired.result
        }
        let shortDeadline = owner.makeDeadline(elapsed: .seconds(25))
        let short = Task { try await owner.read(key(), deadline: shortDeadline) { await gate.read(response()) } }
        try await eventually {
            let entry = await owner.entries.values.first
            return queued ? entry?.pending?.waiters.count == 1 : entry?.waiters.count == 1
        }
        clock.advance(by: .seconds(1))
        let longDeadline = owner.makeDeadline()
        let long = Task { try await owner.read(key(), deadline: longDeadline) { await gate.read(response()) } }
        try await eventually {
            let entry = await owner.entries.values.first
            return queued ? entry?.pending?.waiters.count == 2 : entry?.waiters.count == 2
        }
        clock.advance(by: .seconds(5), deliverTimers: deliverTimers)
        if deliverTimers { _ = await short.result }
        await gate.release()
        do { _ = try await short.value; Issue.record("elapsed caller exceeded its deadline") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(try await long.value.http.statusCode == 200)
        #expect(await gate.requests == (queued ? 2 : 1))
        #expect(await owner.entries.isEmpty)
    }

    @Test("Later callers cannot rejuvenate the transport beyond its fixed budget")
    func transportLifetimeCap() async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let gate = CloudReadResponseGate()
        let first = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await gate.requests == 1 }
        clock.advance(by: .seconds(29))
        let late = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await owner.entries.values.first?.waiters.count == 2 }
        #expect(await owner.noteRetryAfter(key(), seconds: 2, response: response(429)) == false)
        clock.advance(by: .seconds(2))
        for request in [first, late] {
            do { _ = try await request.value; Issue.record("shared transport exceeded its cap") }
            catch { #expect((error as? URLError)?.code == .timedOut) }
        }
        #expect(await owner.entries.values.first?.waiters.isEmpty == true)
        let replacement = Task { try await owner.read(key()) { await gate.read(response()) } }
        try await eventually { await owner.entries.values.first?.pending?.waiters.count == 1 }
        #expect(await gate.requests == 1)
        await gate.release()
        #expect(try await replacement.value.http.statusCode == 200)
        #expect(await gate.requests == 2)
    }

    @Test("Retry admission uses the latest live caller within the transport cap")
    func retryUsesRemainingCallerBudgets() async throws {
        let clock = CloudReadManualClock()
        let owner = Owner(clock: CloudRequestClock(clock))
        let gate = CloudReadResponseGate()
        let short = Task { try await owner.read(key(), deadline: .seconds(5)) { await gate.read(response(429)) } }
        try await eventually { await gate.requests == 1 }
        clock.advance(by: .seconds(1))
        let long = Task { try await owner.read(key(), deadline: .seconds(20)) { await gate.read(response(429)) } }
        try await eventually { await owner.entries.values.first?.waiters.count == 2 }
        #expect(await owner.noteRetryAfter(key(), seconds: 8, response: response(429)))
        long.cancel()
        _ = await long.result
        #expect(await owner.noteRetryAfter(key(), seconds: 8, response: response(429)) == false)
        await gate.release()
        #expect(try await short.value.http.statusCode == 429)
        #expect(try await owner.read(key()) { Issue.record("retried before the server minimum"); return response() }.http.statusCode == 429)
        clock.advance(by: .seconds(8))
        #expect(try await owner.read(key()) { response() }.http.statusCode == 200)
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
        try await eventually { await gate.requests == 1 }
        let replacement = try await owner.read(key(generation: 2)) { response(201) }
        #expect(replacement.http.statusCode == 201)
        await gate.release()
        #expect(try await first.value.http.statusCode == 200)
    }

    @Test("A mutation landing during a read shares one fresh trailing pass")
    func mutationInvalidatesRunningRead() async throws {
        let owner = Owner()
        let gate = CloudReadResponseGate()
        let list = key("/api/vm")
        let operation: @Sendable () async -> Owner.Response = {
            await gate.read(response(await gate.requests == 0 ? 200 : 201))
        }
        let first = Task { try await owner.read(list, operation: operation) }
        try await eventually { await gate.requests == 1 }
        await owner.invalidate(CloudReadMutation(method: "POST", scope: list, responseData: Data()))
        let second = Task { try await owner.read(list, operation: operation) }
        try await eventually { await owner.entries.values.first?.waiters.count == 2 }
        await gate.release()
        #expect(try await first.value.http.statusCode == 201)
        #expect(try await second.value.http.statusCode == 201)
        #expect(await gate.requests == 2)
    }

    @Test("Resize refreshes only the captured team's list and target machine")
    func mutationScopeIsolation() async throws {
        let owner = Owner()
        let scenarios: [(Owner.Key, Bool)] = [
            (key("/api/vm"), true), (key("/api/vm/target/stats"), true),
            (key("/api/vm/other/stats"), false),
            (key("/api/coderouter/vm-usage/team"), false),
            (key("/api/vm", account: "other"), false),
            (key("/api/vm", generation: 2), false),
            (key("/api/vm", team: "other"), false)
        ]
        let gates = scenarios.map { _ in CloudReadResponseGate() }
        let requests = zip(scenarios, gates).map { scenario, gate in
            Task { try await owner.read(scenario.0) {
                await gate.read(response(await gate.requests == 0 ? 200 : 201))
            } }
        }
        try await eventually { await owner.entries.count == scenarios.count }
        for gate in gates { try await eventually { await gate.requests == 1 } }
        await owner.invalidate(CloudReadMutation(method: "POST", scope: key("/api/vm/target/resize"), responseData: Data()))
        for gate in gates { await gate.release() }
        for (index, request) in requests.enumerated() {
            #expect(try await request.value.http.statusCode == (scenarios[index].1 ? 201 : 200))
            #expect(await gates[index].requests == (scenarios[index].1 ? 2 : 1))
        }
    }

    @Test("Unrelated mutations do not restart machine reads", arguments: [
        "/api/vm/tunnel", "/api/vm/publications", "/api/billing/checkout",
        "/api/vm/target/snapshot", "/api/vm/target/files"
    ])
    func unrelatedMutation(path: String) async throws {
        let owner = Owner()
        let gate = CloudReadResponseGate()
        let request = Task { try await owner.read(key("/api/vm")) { await gate.read(response()) } }
        try await eventually { await gate.requests == 1 }
        await owner.invalidate(CloudReadMutation(method: "POST", scope: key(path), responseData: Data()))
        await gate.release()
        #expect(try await request.value.http.statusCode == 200)
        #expect(await gate.requests == 1)
    }

    @Test("Cooldown capacity retains bounded compact errors and every server minimum")
    func boundedCooldowns() throws {
        var store = CloudReadCooldownStore(capacity: 8)
        store.activateSession(for: key())
        let largeResponse = Owner.Response(data: Data(repeating: 65, count: 1_000_000), http: response(429).http)
        for index in 0..<1000 {
            store.record(key("vm-\(index)"), until: 60, now: 0, response: largeResponse)
        }
        #expect(store.retainedCount == 8)
        let cachedResponses = (0..<1000).compactMap { store.response(for: key("vm-\($0)"), now: 59) }
        #expect(cachedResponses.count == 8)
        for cached in cachedResponses {
            #expect(cached.http.statusCode == 429)
            #expect(cached.data == Data(#"{"error":"rate_limited"}"#.utf8))
            #expect(cached.http.allHeaderFields.isEmpty)
        }
        // An evicted key and an unrelated path must not inherit another
        // machine's Retry-After minimum.
        #expect(store.response(for: key("unseen"), now: 59) == nil)
        let expiredResponse = store.response(for: key("vm-999"), now: 60)
        #expect(expiredResponse == nil)
        #expect(store.retainedCount == 0)
    }

    @Test("A key keeps its longest cooldown without leaking to other paths")
    func cooldownKeepsLongestMinimumPerKey() {
        var store = CloudReadCooldownStore(capacity: 1)
        store.activateSession(for: key())
        store.record(key("first"), until: 10, now: 0, response: response(429))
        store.record(key("first"), until: 100, now: 0, response: response(429))
        store.record(key("first"), until: 20, now: 0, response: response(429))
        let throttledResponse = store.response(for: key("first"), now: 99)
        #expect(throttledResponse?.http.statusCode == 429)
        #expect(store.retainedCount == 1)
        #expect(store.response(for: key("other"), now: 99) == nil)
        let expiredResponse = store.response(for: key("first"), now: 100)
        #expect(expiredResponse == nil)
    }

    @Test("Session replacement discards old cooldowns and late completions cannot revive them")
    func retiredSessionCooldowns() {
        var store = CloudReadCooldownStore(capacity: 8)
        let old = key()
        for generation in 1...1000 {
            let current = key(account: "account-\(generation)", generation: UInt64(generation))
            store.activateSession(for: current)
            store.record(current, until: .infinity, now: 0, response: response(429))
            #expect(store.retainedCount == 1)
        }
        let current = key(account: "account-1000", generation: 1000)
        store.activateSession(for: old)
        store.record(old, until: .infinity, now: 0, response: response(429))
        let oldResponse = store.response(for: old, now: 0)
        #expect(oldResponse == nil)
        let currentResponse = store.response(for: current, now: 0)
        #expect(currentResponse?.http.statusCode == 429)
        #expect(store.retainedCount == 1)
        let replacement = key(account: "replacement", generation: 1001)
        store.activateSession(for: replacement)
        store.record(current, until: .infinity, now: 0, response: response(429))
        let replacementResponse = store.response(for: replacement, now: 0)
        #expect(replacementResponse == nil)
        #expect(store.retainedCount == 0)
    }

    private func eventually(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition(), "Fixture did not reach its expected actor state")
    }
}

@Suite("Cloud machines offline empty state")
struct CloudMachinesOfflineStateTests {
    @Test("Offline before the first list load exposes retry state")
    @MainActor
    func offlineBeforeFirstLoadIsVisible() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        await fixture.readRequests.networkChanged(isOnline: false)
        for _ in 0..<10 { await Task.yield() }
        #expect(model.hasLoadedOnce)
        #expect(model.listProblem == .unreachable)
        #expect(model.lastErrorDescription != nil)
        model.stopPolling()
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
