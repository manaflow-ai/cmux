import AppKit
import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The machine-list status across sleep, return, retry, and account changes
/// (https://github.com/manaflow-ai/cmux/issues/14483). These share the
/// serialized suite because `CloudRefreshURLProtocol` state is process-wide.
@MainActor
extension VMClientReadCoalescingTests {
    @Test("Returning online with an interrupted read reconnects without a hard failure")
    func returnAfterSleepReconnects() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        defer { model.stopPolling() }
        model.startPolling()
        try await listEventually { model.machines.count == 1 && !model.isLoading }
        // Sleep lands while a poll is in flight: the coordinator expires it.
        await CloudRefreshURLProtocol.holdResponses()
        model.refresh()
        try await listEventually { await Self.listRequests() == 2 }
        let generation = model.refreshGeneration
        await fixture.readRequests.networkChanged(isOnline: false)
        try await listEventually { model.refreshGeneration != generation }
        #expect(model.listStatus == .waitingForNetwork)
        await fixture.readRequests.networkChanged(isOnline: true)
        try await listEventually { await Self.listRequests() == 3 }
        #expect(model.isLoading)
        #expect(model.listStatus == nil || model.listStatus == .reconnecting, "Got \(String(describing: model.listStatus))")
        await CloudRefreshURLProtocol.releaseResponses()
        try await listEventually { !model.isLoading }
        #expect(model.listStatus == nil)
        #expect(model.machines.count == 1)
    }

    @Test("A transient failure shows reconnecting during the recovery read, then clears")
    func transientFailureThenSuccess() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.listUnavailable)
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        defer { model.stopPolling() }
        model.refresh()
        try await listEventually { model.hasLoadedOnce && !model.isLoading }
        #expect(model.listStatus == .failed(.unreachable))
        await CloudRefreshURLProtocol.configure(.normal)
        await CloudRefreshURLProtocol.holdResponses()
        model.recoverList()
        try await listEventually { await Self.listRequests() == 2 }
        #expect(model.listStatus == .reconnecting)
        await CloudRefreshURLProtocol.releaseResponses()
        try await listEventually { !model.isLoading }
        #expect(model.listStatus == nil)
        #expect(model.lastErrorDescription == nil)
        #expect(model.machines.count == 1)
    }

    @Test("A persistent failure stays visible through polls and keeps the cached fleet")
    func persistentFailureWithCachedFleet() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let clock = CloudReadManualClock()
        let model = MachinesPanelViewModel(client: fixture.client, pollingClock: clock, isCloudEnabled: { true })
        defer { model.stopPolling() }
        model.startPolling()
        try await listEventually { model.machines.count == 1 && !model.isLoading }
        await CloudRefreshURLProtocol.configure(.listUnavailable)
        model.refresh()
        try await listEventually { model.listStatus == .failed(.unreachable) && !model.isLoading }
        await CloudRefreshURLProtocol.holdResponses()
        try await listEventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: MachinesPanelViewModel.pollInterval)
        try await listEventually { await Self.listRequests() == 3 }
        // A routine poll is not a recovery attempt: the failure must not flicker.
        #expect(model.listStatus == .failed(.unreachable))
        #expect(model.machines.count == 1)
        await CloudRefreshURLProtocol.releaseResponses()
        try await listEventually { !model.isLoading }
        #expect(model.listStatus == .failed(.unreachable))
        #expect(model.machines.count == 1)
    }

    @Test("A stale failure from an older request cannot reassert an error after success")
    func staleFailureAfterSuccess() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        defer { model.stopPolling() }
        let staleGeneration = model.refreshGeneration
        model.stopPolling()
        model.startPolling()
        try await listEventually { model.machines.count == 1 && !model.isLoading }
        model.applyRefreshResult(.failure(VMClientError.httpStatus(503, "late")), generation: staleGeneration, scope: nil)
        model.applyRefreshResult(.failure(URLError(.notConnectedToInternet)), generation: staleGeneration, scope: nil)
        #expect(model.listStatus == nil)
        #expect(model.lastErrorDescription == nil)
        #expect(model.machines.count == 1)
    }

    @Test("Cancelling a read neither reports a failure nor clears a real one")
    func cancellationIsNotAFailure() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        model.startPolling()
        try await listEventually { await Self.listRequests() == 1 }
        let stopBaseline = await CloudRefreshURLProtocol.currentStopCount()
        model.stopPolling()
        await CloudRefreshURLProtocol.waitUntilStopped(after: stopBaseline)
        #expect(model.listStatus == nil)
        #expect(!model.hasLoadedOnce)
        model.applyRefreshResult(.failure(VMClientError.httpStatus(503, "down")), generation: model.refreshGeneration, scope: nil)
        model.applyRefreshResult(.failure(CancellationError()), generation: model.refreshGeneration, scope: nil)
        #expect(model.listStatus == .failed(.unreachable))
    }

    @Test("Showing a hidden panel reconnects instead of repeating the old failure")
    func hiddenThenShownPanelReconnects() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.listUnavailable)
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        defer { model.stopPolling() }
        model.startPolling()
        try await listEventually { model.hasLoadedOnce && !model.isLoading }
        #expect(model.listStatus == .failed(.unreachable))
        model.stopPolling()
        await CloudRefreshURLProtocol.configure(.normal)
        await CloudRefreshURLProtocol.holdResponses()
        model.startPolling()
        try await listEventually { await Self.listRequests() == 2 }
        #expect(model.listStatus == .reconnecting)
        await CloudRefreshURLProtocol.releaseResponses()
        try await listEventually { !model.isLoading }
        #expect(model.listStatus == nil)
        #expect(model.machines.count == 1)
    }

    @Test("Sign-in and plan failures keep their meaning during a recovery read", arguments: [401, 402])
    func gatedFailuresKeepMeaning(status: Int) async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        defer { model.stopPolling() }
        let expected: MachineListStatus = .failed(status == 401 ? .sessionRejected : .requiresPro)
        model.applyRefreshResult(.failure(VMClientError.httpStatus(status, "gated")), generation: model.refreshGeneration, scope: nil)
        #expect(model.listStatus == expected)
        model.startPolling()
        try await listEventually { await Self.listRequests() == 1 }
        #expect(model.listStatus == expected, "Only a transient failure reads as reconnecting")
        await fixture.readRequests.networkChanged(isOnline: false)
        try await listEventually { model.listStatus == .waitingForNetwork }
        await fixture.readRequests.networkChanged(isOnline: true)
        try await listEventually { await Self.listRequests() == 2 }
        #expect(model.listStatus == expected)
        await CloudRefreshURLProtocol.releaseResponses()
        try await listEventually { !model.isLoading }
        #expect(model.listStatus == nil, "A successful read clears the gate it replaced")
    }

    @Test("An account or team change carries no earlier list status")
    func accountChangeClearsListStatus() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.listUnavailable)
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        defer { model.stopPolling() }
        model.startPolling()
        try await listEventually { model.hasLoadedOnce && !model.isLoading }
        #expect(model.listStatus == .failed(.unreachable))
        let oldGeneration = model.refreshGeneration
        await CloudRefreshURLProtocol.configure(.normal)
        await CloudRefreshURLProtocol.holdResponses()
        let scopeTask = model.refreshAccountScope(refreshCatalog: { true })
        #expect(model.listStatus == nil)
        #expect(!model.hasLoadedOnce)
        model.applyRefreshResult(.failure(VMClientError.httpStatus(503, "old team")), generation: oldGeneration, scope: nil)
        #expect(model.listStatus == nil)
        try await listEventually { await Self.listRequests() == 2 }
        #expect(model.listStatus == nil, "A new scope's first read is a load, not a reconnect")
        await CloudRefreshURLProtocol.releaseResponses()
        await scopeTask.value
        try await listEventually { !model.isLoading }
        #expect(model.listStatus == nil)
        #expect(model.machines.count == 1)
    }

    @Test("Waking from sleep reconnects instead of keeping the failure of the poll that fired on wake")
    func wakeAfterFailedPollReconnects() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let clock = CloudReadManualClock()
        let wakes = NotificationCenter()
        let model = MachinesPanelViewModel(
            client: fixture.client, pollingClock: clock, wakeNotificationCenter: wakes, isCloudEnabled: { true }
        )
        defer { model.stopPolling() }
        model.startPolling()
        try await listEventually { model.machines.count == 1 && !model.isLoading }
        // The poll clock kept running through sleep, so a poll fires on wake
        // before the service answers again. A poll is not a recovery.
        await CloudRefreshURLProtocol.configure(.listUnavailable)
        try await listEventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: MachinesPanelViewModel.pollInterval)
        try await listEventually { model.listStatus == .failed(.unreachable) && !model.isLoading }
        await CloudRefreshURLProtocol.configure(.normal)
        await CloudRefreshURLProtocol.holdResponses()
        wakes.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await listEventually { await Self.listRequests() == 3 }
        #expect(model.listStatus == .reconnecting)
        await CloudRefreshURLProtocol.releaseResponses()
        try await listEventually { !model.isLoading }
        #expect(model.listStatus == nil)
        #expect(model.machines.count == 1)
    }

    @Test("Waking from sleep turns the failure of a read that spanned it into a recovery")
    func wakeDuringInterruptedReadRecovers() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let clock = CloudReadManualClock()
        let wakes = NotificationCenter()
        let model = MachinesPanelViewModel(
            client: fixture.client, pollingClock: clock, wakeNotificationCenter: wakes, isCloudEnabled: { true }
        )
        defer { model.stopPolling() }
        model.startPolling()
        try await listEventually { model.machines.count == 1 && !model.isLoading }
        // Sleep lands mid-poll; that read fails once the Mac is back.
        await CloudRefreshURLProtocol.configure(.listUnavailable)
        await CloudRefreshURLProtocol.holdResponses()
        try await listEventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: MachinesPanelViewModel.pollInterval)
        try await listEventually { await Self.listRequests() == 2 }
        wakes.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await listEventually { model.isRecoveringList }
        await CloudRefreshURLProtocol.configure(.normal)
        await CloudRefreshURLProtocol.releasePendingResponses()
        // The read that spanned the sleep failed; the wake's read is still out.
        try await listEventually { await Self.listRequests() == 3 }
        #expect(model.listStatus == .reconnecting)
        await CloudRefreshURLProtocol.releaseResponses()
        try await listEventually { !model.isLoading }
        #expect(model.listStatus == nil)
        #expect(model.lastErrorDescription == nil)
        #expect(model.machines.count == 1)
    }

    @Test("A wake while the panel is hidden starts no read")
    func wakeWhileHiddenStartsNoRead() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let wakes = NotificationCenter()
        let model = MachinesPanelViewModel(client: fixture.client, wakeNotificationCenter: wakes, isCloudEnabled: { true })
        model.startPolling()
        try await listEventually { model.machines.count == 1 && !model.isLoading }
        model.stopPolling()
        wakes.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!model.isLoading)
        #expect(!model.isRecoveringList)
        #expect(await Self.listRequests() == 1)
    }

    private static func listRequests() async -> Int {
        await CloudRefreshURLProtocol.requestCounts()["/api/vm"] ?? 0
    }

    private func listEventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition())
    }
}
