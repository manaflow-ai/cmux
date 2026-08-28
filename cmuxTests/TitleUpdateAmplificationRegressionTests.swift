import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the title-update amplification chain in #10507.
///
/// These tests intentionally exercise the model and AppKit seams rather than
/// attempting to reproduce WindowServer or a native full-screen Space in CI.
@MainActor
@Suite("Title update amplification", .serialized)
struct TitleUpdateAmplificationRegressionTests {
    @Test
    func titleBurstUsesTheSafetyCoalescingWindowByDefault() async throws {
        let suiteName = "TitleUpdateAmplification.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let scheduler = ManualTitleCoalescerScheduler()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let sourceSurface = try #require(workspace.terminalPanel(for: panelId)?.surface)
        let window = CountingTitleWindow()
        manager.window = window
        manager.updateWindowTitleForSelectedTab()
        await drainMainQueue()
        let baselineWindowWriteCount = window.titleWriteCount
        var workspacePublishCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .workspaceTitleDidChange,
            object: manager,
            queue: nil
        ) { _ in
            workspacePublishCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for sequence in 0..<100 {
            NotificationCenter.default.post(
                name: .ghosttyDidSetTitle,
                object: sourceSurface,
                userInfo: [
                    GhosttyNotificationKey.tabId: workspace.id,
                    GhosttyNotificationKey.surfaceId: panelId,
                    GhosttyNotificationKey.title: "Agent frame \(sequence)"
                ]
            )
        }
        await drainMainQueue()

        // A burst must stay behind the long safety window before it reaches
        // Workspace/SwiftUI state.
        #expect(scheduler.delays == [1.0])
        #expect(workspacePublishCount == 0)
        #expect(window.titleWriteCount == baselineWindowWriteCount)
        scheduler.fire(at: 0)

        #expect(workspacePublishCount == 1)
        #expect(workspace.title == "Agent frame 99")
        #expect(window.titleWriteCount == baselineWindowWriteCount + 1)
        #expect(window.title == "Agent frame 99")
    }

    @Test
    func repeatedWindowTitleRefreshesSkipNoopAppKitWrites() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let window = CountingTitleWindow()
        window.titleWriteCount = 0
        manager.window = window

        manager.updateWindowTitleForSelectedTab()
        let firstWriteCount = window.titleWriteCount
        #expect(firstWriteCount > 0)

        for _ in 0..<100 {
            manager.updateWindowTitleForSelectedTab()
        }

        // NSWindow.title is a WindowServer-facing mutation. Reassigning the
        // same value still emits the Dock/Spaces work that this regression is
        // about, so no-op writes must be skipped at the source.
        #expect(window.titleWriteCount == firstWriteCount)

        window.title = "External title"
        let externalMutationCount = window.titleWriteCount
        manager.updateWindowTitleForSelectedTab()
        #expect(window.titleWriteCount == externalMutationCount + 1)
    }

    @Test
    func titleIngressUsesAWindowServerSafePublicationInterval() async {
        let intervalRecorder = IntervalRecorder()
        let dispatcher = GhosttyTitleUpdateDispatcher(
            schedule: { interval, _ in
                intervalRecorder.record(interval)
                return {}
            },
            publish: { _ in }
        )
        let source = NSObject()

        await dispatcher.receive(GhosttyTitleUpdate(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "agent frame",
            sourceSurfaceIdentifier: ObjectIdentifier(source),
            terminalLifecycleID: UUID()
        ))

        // The previous 50 ms interval still lets five busy surfaces deliver
        // roughly one hundred main-actor notifications per second. The safety
        // interval is deliberately much longer and is asserted here before
        // the implementation changes.
        #expect(intervalRecorder.value == .milliseconds(1_000))
    }

    @Test
    func productionTitleDeadlineDeliversThroughItsCallbackSignal() async {
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let deadline = GhosttyTitleUpdateDeadline(interval: .milliseconds(1)) {
            continuation.yield(())
            continuation.finish()
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        let didFire = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(didFire)
    }

    @Test
    func staleDeadlineCannotFlushAReplacementTitleWindow() async {
        let scheduler = DeadlineRaceScheduler()
        var published: [String] = []
        let dispatcher = GhosttyTitleUpdateDispatcher(
            schedule: scheduler.schedule(interval:action:),
            publish: { updates in
                published.append(contentsOf: updates.map(\.title))
            }
        )
        let source = NSObject()
        let first = GhosttyTitleUpdate(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "first",
            sourceSurfaceIdentifier: ObjectIdentifier(source),
            terminalLifecycleID: UUID()
        )
        let second = GhosttyTitleUpdate(
            tabId: first.tabId,
            surfaceId: first.surfaceId,
            title: "second",
            sourceSurfaceIdentifier: first.sourceSurfaceIdentifier,
            terminalLifecycleID: first.terminalLifecycleID
        )

        await dispatcher.receive(first)
        await dispatcher.flushNow()
        await dispatcher.receive(second)

        await scheduler.fire(index: 0)
        #expect(published == ["first"])
        await scheduler.fire(index: 1)
        #expect(published == ["first", "second"])
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private final class CountingTitleWindow: NSWindow {
        var titleWriteCount = 0

        override var title: String {
            didSet { titleWriteCount += 1 }
        }
    }

    // SAFETY: the lock guards the single recorded value across the scheduler
    // callback and the main-actor assertion.
    private final class IntervalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedInterval: Duration?

        var value: Duration? {
            lock.lock()
            defer { lock.unlock() }
            return recordedInterval
        }

        func record(_ interval: Duration) {
            lock.lock()
            recordedInterval = interval
            lock.unlock()
        }
    }

    private final class ManualTitleCoalescerScheduler {
        private struct PendingFlush {
            var isCancelled = false
            let action: @MainActor () -> Void
        }

        private var pendingFlushes: [PendingFlush] = []
        private(set) var delays: [TimeInterval] = []

        @MainActor
        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> NotificationBurstCoalescer.Cancellation {
            let index = pendingFlushes.count
            delays.append(delay)
            pendingFlushes.append(PendingFlush(action: action))
            return { [weak self] in
                self?.pendingFlushes[index].isCancelled = true
            }
        }

        @MainActor
        func fire(at index: Int) {
            guard pendingFlushes.indices.contains(index), !pendingFlushes[index].isCancelled else {
                return
            }
            pendingFlushes[index].action()
        }
    }

    // SAFETY: the lock protects the callback array while a canceled deadline
    // is deliberately fired by the race test.
    private final class DeadlineRaceScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [(@Sendable () async -> Void)?] = []

        func schedule(
            interval _: Duration,
            action: @escaping @Sendable () async -> Void
        ) -> GhosttyTitleUpdateDispatcher.Cancellation {
            lock.lock()
            let index = actions.count
            actions.append(action)
            lock.unlock()
            return {}
        }

        func fire(index: Int) async {
            lock.lock()
            let action = actions.indices.contains(index) ? actions[index] : nil
            lock.unlock()
            await action?()
        }
    }
}
