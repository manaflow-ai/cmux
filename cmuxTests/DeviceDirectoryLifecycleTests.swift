import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Devices: presence lifecycle", .timeLimit(.minutes(5)))
struct DeviceDirectoryLifecycleTests {
    @Test("A missing service URL retries and subscribes when configuration becomes available")
    func unavailableServiceRecovers() async throws {
        let suite = "DeviceDirectoryLifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sleeps = AsyncStream<Void>.makeStream()
        let subscriptions = AsyncStream<URL>.makeStream()
        defer { sleeps.continuation.finish(); subscriptions.continuation.finish() }
        let clock = SidebarTestManualClock(beforeRegisteringSleeper: {
            sleeps.continuation.yield(())
        })
        let expectedURL = try #require(URL(string: "https://presence.cmux.test"))
        var configuredURL: URL?
        let directory = makeDirectory(
            defaults: defaults,
            clock: clock,
            serviceURL: { configuredURL },
            makeSubscriber: { url, _ in
                subscriptions.continuation.yield(url)
                // Exercise resubscription without dialing or accessing credentials.
                return DevicePresenceSubscriber(serviceBaseURL: URL(fileURLWithPath: "/"), credentials: { nil })
            }
        )
        defer { directory.stop() }
        directory.start()
        var sleepEvents = sleeps.stream.makeAsyncIterator()
        try #require(await sleepEvents.next() != nil, "presence must schedule recovery after a missing URL")
        #expect(directory.presenceState == .retrying(attempt: 1, error: "presence unreachable"))
        configuredURL = expectedURL
        clock.advance(by: .seconds(30))
        var subscriptionEvents = subscriptions.stream.makeAsyncIterator()
        #expect(await subscriptionEvents.next() == expectedURL)
        directory.stop()
        await clock.waitUntilIdle()
        #expect(!directory.isRunning)
    }

    @Test("Stopping during missing-URL backoff cancels the retry")
    func stopCancelsUnavailableServiceRetry() async throws {
        let suite = "DeviceDirectoryStop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sleeps = AsyncStream<Void>.makeStream()
        defer { sleeps.continuation.finish() }
        let clock = SidebarTestManualClock(beforeRegisteringSleeper: { sleeps.continuation.yield(()) })
        var resolutions = 0
        let directory = makeDirectory(defaults: defaults, clock: clock, serviceURL: {
            resolutions += 1
            return nil
        })
        defer { directory.stop() }
        directory.start()
        var events = sleeps.stream.makeAsyncIterator()
        try #require(await events.next() != nil)
        directory.stop()
        clock.advance(by: .seconds(60))
        await clock.waitUntilIdle()
        #expect(resolutions == 1)
        #expect(directory.presenceState == .stopped)
        #expect(!directory.isRunning)
    }

    @Test("An empty presence snapshot still publishes the live transition")
    func emptySnapshotPublishesLiveState() throws {
        let suite = "DeviceDirectoryLive-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = makeDirectory(defaults: defaults, clock: SidebarTestManualClock(), serviceURL: { nil })
        let recorded = PresenceRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: DeviceDirectory.didChangeNotification, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard notification.object as? DeviceDirectory === directory else { return }
                recorded.states.append(directory.presenceState)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer); directory.stop() }
        directory.apply(.snapshot(devices: []))
        #expect(directory.records.isEmpty)
        #expect(recorded.states == [.live])
    }

    private final class PresenceRecorder {
        var states: [DeviceDirectory.PresenceState] = []
    }

    @Test("A cancelled registry read cannot publish over its replacement", .timeLimit(.minutes(5)))
    func cancelledRegistryReadCannotPublish() async throws {
        let suite = "DeviceDirectoryRegistry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = AsyncStream<CheckedContinuation<AuthenticatedSessionSnapshot, any Error>>.makeStream()
        defer { requests.continuation.finish() }
        let client = DeviceRegistryDirectoryClient(session: {
            try await withCheckedThrowingContinuation { requests.continuation.yield($0) }
        }, teamID: nil)
        let directory = makeDirectory(
            defaults: defaults, clock: SidebarTestManualClock(), registryClient: client, serviceURL: { nil }
        )
        defer { directory.stop() }
        var calls = requests.stream.makeAsyncIterator()
        let oldTask = directory.refreshRegistry()
        let oldRequest = try #require(await calls.next())
        directory.stop()
        let newTask = directory.refreshRegistry()
        let newRequest = try #require(await calls.next())
        oldRequest.resume(throwing: DeviceRegistryDirectoryClient.ListError.notSignedIn)
        await oldTask.value
        #expect(directory.isRefreshingRegistry)
        #expect(!directory.hasLoadedRegistry)
        #expect(directory.registryError == nil)
        newRequest.resume(throwing: DeviceRegistryDirectoryClient.ListError.notSignedIn)
        await newTask.value
        #expect(!directory.isRefreshingRegistry)
        #expect(directory.hasLoadedRegistry)
    }

    @Test("Cancelling the current registry refresh releases its busy state", .timeLimit(.minutes(5)))
    func cancelledCurrentRegistryReadCanRetry() async throws {
        let suite = "DeviceDirectoryCancel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = AsyncStream<CheckedContinuation<AuthenticatedSessionSnapshot, any Error>>.makeStream()
        defer { requests.continuation.finish() }
        let client = DeviceRegistryDirectoryClient(session: {
            try await withCheckedThrowingContinuation { requests.continuation.yield($0) }
        }, teamID: nil)
        let directory = makeDirectory(
            defaults: defaults, clock: SidebarTestManualClock(), registryClient: client, serviceURL: { nil }
        )
        defer { directory.stop() }
        var calls = requests.stream.makeAsyncIterator()
        let task = directory.refreshRegistry()
        let request = try #require(await calls.next())
        task.cancel()
        request.resume(throwing: CancellationError())
        await task.value
        #expect(!directory.isRefreshingRegistry)
        #expect(!directory.hasLoadedRegistry)
        let retry = directory.refreshRegistry()
        let retriedRequest = try #require(await calls.next())
        retriedRequest.resume(throwing: DeviceRegistryDirectoryClient.ListError.notSignedIn)
        await retry.value
        #expect(directory.hasLoadedRegistry)
        #expect(!directory.isRefreshingRegistry)
    }

    @Test("A reconnect discards interrupted owner pages and commits only the new snapshot", arguments: [false, true])
    func reconnectReplacesIncompleteOwnershipSnapshot(includeNewOwner: Bool) throws {
        let suite = "DeviceDirectoryReconnect-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = makeDirectory(
            defaults: defaults, clock: SidebarTestManualClock(), teamID: "shared-team", serviceURL: { nil }
        )
        defer { directory.stop() }
        let staleID = "11111111-1111-4111-8111-111111111111"
        let currentID = "22222222-2222-4222-8222-222222222222"
        let devices = [staleID, currentID].map { id in
            DevicePresenceDevice(deviceId: id, instances: [
                DevicePresenceInstance(deviceId: id, tag: "default", online: true, lastSeenAt: 1)
            ])
        }
        let staleOwner = DeviceSyncRecord(
            id: staleID, deleted: false,
            device: DeviceSyncDeviceRecord(deviceId: staleID, ownerUserId: "test")
        )
        directory.apply(.snapshot(devices: devices))
        directory.apply(.syncSnapshot(records: [staleOwner], complete: false))
        #expect(directory.records.allSatisfy { $0.accountTrust == .unknown })

        // Every new socket starts with presence's snapshot, even when the
        // previous socket closed halfway through the ownership page set.
        directory.apply(.snapshot(devices: devices))
        if includeNewOwner {
            directory.apply(.syncSnapshot(records: [DeviceSyncRecord(
                id: currentID, deleted: false,
                device: DeviceSyncDeviceRecord(deviceId: currentID, ownerUserId: "test")
            )], complete: false))
            #expect(directory.records.allSatisfy { $0.accountTrust == .unknown })
        }
        directory.apply(.syncSnapshot(records: [], complete: true))

        let stale = try #require(directory.records.first { $0.instance.deviceID == staleID })
        #expect(stale.ownerUserID == nil)
        #expect(stale.accountTrust == .unknown)
        #expect(!stale.isDialable)
        let current = try #require(directory.records.first { $0.instance.deviceID == currentID })
        #expect(current.ownerUserID == (includeNewOwner ? "test" : nil))
        #expect(current.accountTrust == (includeNewOwner ? .sameAccount : .unknown))
    }

    private func makeDirectory(
        defaults: UserDefaults,
        clock: SidebarTestManualClock,
        teamID: String? = nil,
        registryClient: DeviceRegistryDirectoryClient? = nil,
        serviceURL: @escaping @MainActor @Sendable () -> URL?,
        makeSubscriber: @escaping @Sendable (URL, @escaping @Sendable () async throws -> DevicePresenceSubscriber.Credentials?) -> DevicePresenceSubscriber = {
            DevicePresenceSubscriber(serviceBaseURL: $0, credentials: $1)
        }
    ) -> DeviceDirectory {
        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: "test", publishableClientKey: "test"),
            magicLinkCallbackURL: "http://127.0.0.1:1/auth/callback",
            apiBaseURL: "http://127.0.0.1:1"
        )
        let auth = AuthCoordinator(
            client: StackAuthClient(config: config, tokenStore: .memory, noAutomaticPrefetch: true),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: AuthPresentationContextProvider(), config: config,
            launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false, environment: [:], includesDevAuth: false)
        )
        return DeviceDirectory(
            auth: auth, identity: AuthenticatedSessionIdentity(generation: 0, accountID: "test"),
            teamID: teamID, pairing: UnpairedDevices(),
            registryClient: registryClient ?? DeviceRegistryDirectoryClient(session: { throw DeviceRegistryDirectoryClient.ListError.notSignedIn }, teamID: nil),
            serviceURL: serviceURL, makeSubscriber: makeSubscriber,
            selfInstance: SurfaceDeviceInstanceID(deviceID: "self", tag: "test"), clock: clock
        )
    }

    private final class UnpairedDevices: DeviceLinkAuthorizationSource {
        var pairedDevices: [DevicePairedDevice] { [] }
        let authorizationDidChangeNotification = Notification.Name("DeviceDirectoryLifecycle-\(UUID().uuidString)")
        func authorization(for instance: SurfaceDeviceInstanceID, route: CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence? { nil }
    }
}
