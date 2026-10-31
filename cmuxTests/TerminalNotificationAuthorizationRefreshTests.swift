import CmuxNotifications
import Combine
import Foundation
import os
import Testing
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalNotificationAuthorizationRefreshTests {
    @MainActor
    private final class StatusProvider {
        var result: Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure> = .success(.denied)
        var reads = 0

        func read() -> Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure> {
            reads += 1
            return result
        }
    }

    private final class PublicationRecorder: Sendable {
        private let counts = OSAllocatedUnfairLock(initialState: (changes: 0, posts: 0))

        var changes: Int { counts.withLock { $0.changes } }
        var posts: Int { counts.withLock { $0.posts } }
        func recordChange() { counts.withLock { $0.changes += 1 } }
        func recordPost() { counts.withLock { $0.posts += 1 } }
    }

    private func makeStore(
        provider: StatusProvider,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> TerminalNotificationStore {
        TerminalNotificationStore(
            userNotificationCenter: UserNotificationCenterService(center: UNUserNotificationCenter.current()),
            authorizationStatusProvider: { provider.read() },
            authorizationNotificationCenter: notificationCenter
        )
    }

    /// Records objectWillChange and authorization notification posts for `store`.
    private func observePublications(
        of store: TerminalNotificationStore,
        notificationCenter: NotificationCenter
    ) -> (PublicationRecorder, () -> Void) {
        let recorder = PublicationRecorder()
        let subscription = store.objectWillChange.sink { recorder.recordChange() }
        let observer = notificationCenter.addObserver(
            forName: TerminalNotificationStore.authorizationStatusDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordPost() }
        return (recorder, {
            subscription.cancel()
            notificationCenter.removeObserver(observer)
        })
    }

    @Test
    func initialRefreshWaitsForWindowSetup() async throws {
        let provider = StatusProvider()
        let store = makeStore(provider: provider)

        #expect(provider.reads == 0)
        #expect(store.authorizationState == .unknown)

        let initialRefresh = try #require(store.markWindowSetupComplete())
        await initialRefresh.value
        #expect(provider.reads == 1)
        #expect(store.authorizationState == .denied)

        #expect(store.markWindowSetupComplete() == nil)
        #expect(provider.reads == 1)
    }

    @Test
    func activationBeforeWindowSetupDoesNotPublish() async throws {
        let provider = StatusProvider()
        provider.result = .success(.notDetermined)
        let notificationCenter = NotificationCenter()
        let store = makeStore(provider: provider, notificationCenter: notificationCenter)
        let (recorder, stopObserving) = observePublications(of: store, notificationCenter: notificationCenter)
        defer { stopObserving() }

        let activationRefresh = try #require(store.handleApplicationDidBecomeActive())
        await activationRefresh.value
        #expect(provider.reads == 0)
        #expect(store.authorizationState == .unknown)
        #expect(recorder.changes == 0)
        #expect(recorder.posts == 0)

        // The startup and activation requests share the gate and run as one refresh.
        await store.markWindowSetupComplete()?.value
        #expect(provider.reads == 1)
        #expect(store.authorizationState == .notDetermined)
        #expect(recorder.changes == 1)
        #expect(recorder.posts == 1)
    }

    @Test
    func activationAfterWindowSetupRefreshesImmediately() async throws {
        let provider = StatusProvider()
        let notificationCenter = NotificationCenter()
        let store = makeStore(provider: provider, notificationCenter: notificationCenter)
        await store.markWindowSetupComplete()?.value
        let (recorder, stopObserving) = observePublications(of: store, notificationCenter: notificationCenter)
        defer { stopObserving() }

        // Provisional permission exercises allowed-state publication without
        // requesting a badge upgrade from the runner's real notification center.
        provider.result = .success(.provisional)
        let activationRefresh = try #require(store.handleApplicationDidBecomeActive())
        await activationRefresh.value
        #expect(provider.reads == 2)
        #expect(store.authorizationState == .provisional)
        #expect(recorder.changes == 1)
        #expect(recorder.posts == 1)
    }

    @Test
    func unchangedRefreshDoesNotPublishAndChangedRefreshStillPublishes() async {
        let provider = StatusProvider()
        let notificationCenter = NotificationCenter()
        let store = makeStore(provider: provider, notificationCenter: notificationCenter)
        await store.markWindowSetupComplete()?.value
        #expect(store.authorizationState == .denied)
        let (recorder, stopObserving) = observePublications(of: store, notificationCenter: notificationCenter)
        defer { stopObserving() }

        await store.refreshAuthorizationStatus().value
        await store.refreshAuthorizationStatus().value
        #expect(provider.reads == 3)
        #expect(store.authorizationState == .denied)
        #expect(recorder.changes == 0)
        #expect(recorder.posts == 0)

        provider.result = .success(.notDetermined)
        await store.refreshAuthorizationStatus().value
        #expect(store.authorizationState == .notDetermined)
        #expect(recorder.changes == 1)
        #expect(recorder.posts == 1)

        provider.result = .failure(.timedOut)
        await store.refreshAuthorizationStatus().value
        await store.refreshAuthorizationStatus().value
        #expect(store.authorizationState == .unknown)
        #expect(recorder.changes == 2)
        #expect(recorder.posts == 2)
    }

    @Test
    func initialUnknownRefreshDoesNotPublish() async {
        let provider = StatusProvider()
        provider.result = .success(.unknown(-1))
        let notificationCenter = NotificationCenter()
        let store = makeStore(provider: provider, notificationCenter: notificationCenter)
        let (recorder, stopObserving) = observePublications(of: store, notificationCenter: notificationCenter)
        defer { stopObserving() }

        await store.markWindowSetupComplete()?.value
        provider.result = .failure(.timedOut)
        await store.refreshAuthorizationStatus().value
        #expect(store.authorizationState == .unknown)
        #expect(recorder.changes == 0)
        #expect(recorder.posts == 0)
    }
}
