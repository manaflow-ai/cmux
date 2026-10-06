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
    private final class ManualScheduler {
        var delays: [TimeInterval] = []
        var pending: [@MainActor @Sendable () -> Void] = []

        func schedule(_ delay: TimeInterval, _ block: @escaping @MainActor @Sendable () -> Void) {
            delays.append(delay)
            pending.append(block)
        }

        func tick() {
            let callbacks = pending
            pending.removeAll()
            callbacks.forEach { $0() }
        }
    }

    @MainActor
    private final class StatusProvider {
        var result: Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure> = .success(.denied)
        var reads = 0
        var onRead: (() -> Void)?

        func read() -> Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure> {
            reads += 1
            onRead?()
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
        scheduler: ManualScheduler,
        provider: StatusProvider,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> TerminalNotificationStore {
        TerminalNotificationStore(
            userNotificationCenter: UserNotificationCenterService(center: UNUserNotificationCenter.current()),
            initialAuthorizationScheduler: { scheduler.schedule($0, $1) },
            authorizationStatusProvider: { provider.read() },
            authorizationNotificationCenter: notificationCenter
        )
    }

    private func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test
    func initialRefreshWaitsForScheduledTick() async {
        let scheduler = ManualScheduler()
        let provider = StatusProvider()
        let store = makeStore(scheduler: scheduler, provider: provider)

        #expect(provider.reads == 0)
        #expect(store.authorizationState == .unknown)
        #expect(scheduler.delays == [0.2])
        #expect(scheduler.pending.count == 1)

        await withCheckedContinuation { continuation in
            provider.onRead = { continuation.resume() }
            scheduler.tick()
        }
        provider.onRead = nil
        #expect(provider.reads == 1)
        #expect(store.authorizationState == .denied)
        #expect(scheduler.pending.isEmpty)
    }

    @Test
    func activationBeforeWindowSetupDoesNotPublish() async {
        let scheduler = ManualScheduler()
        let provider = StatusProvider()
        provider.result = .success(.notDetermined)
        let notificationCenter = NotificationCenter()
        let store = makeStore(scheduler: scheduler, provider: provider, notificationCenter: notificationCenter)
        let recorder = PublicationRecorder()
        let subscription = store.objectWillChange.sink { recorder.recordChange() }
        let observer = notificationCenter.addObserver(
            forName: TerminalNotificationStore.authorizationStatusDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordPost() }
        defer {
            subscription.cancel()
            notificationCenter.removeObserver(observer)
        }

        #expect(scheduler.pending.count == 1)
        store.handleApplicationDidBecomeActive()
        await drainMainActor()
        #expect(store.authorizationState == .unknown)
        #expect(recorder.changes == 0)
        #expect(recorder.posts == 0)
    }

    @Test
    func unchangedRefreshDoesNotPublishAndChangedRefreshStillPublishes() async {
        let scheduler = ManualScheduler()
        let provider = StatusProvider()
        let notificationCenter = NotificationCenter()
        let store = makeStore(scheduler: scheduler, provider: provider, notificationCenter: notificationCenter)
        let recorder = PublicationRecorder()
        let subscription = store.objectWillChange.sink { recorder.recordChange() }
        let observer = notificationCenter.addObserver(
            forName: TerminalNotificationStore.authorizationStatusDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordPost() }
        defer {
            subscription.cancel()
            notificationCenter.removeObserver(observer)
        }

        await store.refreshAuthorizationStatus().value
        await store.refreshAuthorizationStatus().value
        #expect(provider.reads == 2)
        #expect(store.authorizationState == .denied)
        #expect(recorder.changes == 1)
        #expect(recorder.posts == 1)

        provider.result = .success(.notDetermined)
        await store.refreshAuthorizationStatus().value
        #expect(store.authorizationState == .notDetermined)
        #expect(recorder.changes == 2)
        #expect(recorder.posts == 2)

        provider.result = .failure(.timedOut)
        await store.refreshAuthorizationStatus().value
        await store.refreshAuthorizationStatus().value
        #expect(store.authorizationState == .unknown)
        #expect(recorder.changes == 3)
        #expect(recorder.posts == 3)
    }

    @Test
    func initialUnknownRefreshDoesNotPublish() async {
        let scheduler = ManualScheduler()
        let provider = StatusProvider()
        let store = makeStore(scheduler: scheduler, provider: provider)
        let recorder = PublicationRecorder()
        let subscription = store.objectWillChange.sink { recorder.recordChange() }
        defer { subscription.cancel() }

        provider.result = .success(.unknown(-1))
        await store.refreshAuthorizationStatus().value
        provider.result = .failure(.timedOut)
        await store.refreshAuthorizationStatus().value
        #expect(store.authorizationState == .unknown)
        #expect(recorder.changes == 0)
    }
}
