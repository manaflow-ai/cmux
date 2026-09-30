import AppKit
import CmuxTerminalCore
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
    private static let automaticTitleScalarBound = AutomaticTerminalTitle.maximumScalars

    @Test
    func multilineAutomaticTitleIsBoundedBeforeManyWorkspaceSnapshotEncoding() async throws {
        let suiteName = "AutomaticTerminalTitleBounds.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let coalescerScheduler = ManualTitleCoalescerScheduler()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: coalescerScheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        for index in 0..<63 {
            _ = manager.addWorkspaceIfActive(
                title: "Synthetic workspace \(index)",
                titleSource: .auto,
                select: false,
                autoWelcomeIfNeeded: false,
                autoRefreshMetadata: false,
                applyCreationTitleAsCustomTitle: false
            )
        }

        let targetWorkspaces = Array(manager.tabs.prefix(2))
        let rawTitle = Self.syntheticMultilineTitle(lineCount: 3_000)
        for workspace in targetWorkspaces {
            let panelId = try #require(workspace.focusedPanelId)
            let sourceSurface = try #require(workspace.terminalPanel(for: panelId)?.surface)
            let titleScheduler = TitleScheduleRecorder()
            let ingress = GhosttyTitleUpdateIngress(
                schedule: titleScheduler.schedule(_:action:)
            )

            #expect(ingress.submit(
                tabId: workspace.id,
                surfaceId: panelId,
                sourceSurfaceIdentifier: ObjectIdentifier(sourceSurface),
                terminalLifecycleID: sourceSurface.terminalLifecycleId,
                title: rawTitle
            ))
            await titleScheduler.awaitFirstSchedule()
            await titleScheduler.fire()
            await drainMainQueue()
        }

        manager.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
        let boundedSnapshot = manager.sessionSnapshot(includeScrollback: false)
        let boundedData = try JSONEncoder().encode(boundedSnapshot)

        var legacySnapshot = boundedSnapshot
        let targetIDs = Set(targetWorkspaces.map(\.id))
        for index in legacySnapshot.workspaces.indices
            where targetIDs.contains(legacySnapshot.workspaces[index].workspaceId ?? UUID()) {
            legacySnapshot.workspaces[index].processTitle = rawTitle
            for panelIndex in legacySnapshot.workspaces[index].panels.indices {
                legacySnapshot.workspaces[index].panels[panelIndex].title = rawTitle
                legacySnapshot.workspaces[index].panels[panelIndex].customTitle = nil
            }
        }
        let legacyData = try JSONEncoder().encode(legacySnapshot)

        let boundedEncodeMilliseconds = Self.medianEncodeMilliseconds(for: boundedSnapshot)
        let legacyEncodeMilliseconds = Self.medianEncodeMilliseconds(for: legacySnapshot)
        print(
            "AUTOMATIC_TITLE_BOUND fixtureWorkspaces=\(boundedSnapshot.workspaces.count) " +
                "rawTitleBytes=\(rawTitle.utf8.count) legacySnapshotBytes=\(legacyData.count) " +
                "boundedSnapshotBytes=\(boundedData.count) legacyEncodeMs=\(legacyEncodeMilliseconds) " +
                "boundedEncodeMs=\(boundedEncodeMilliseconds)"
        )

        for workspace in targetWorkspaces {
            let panelId = try #require(workspace.focusedPanelId)
            let processTitle = workspace.processTitle
            let panelTitle = try #require(workspace.panelTitles[panelId])
            #expect(processTitle.unicodeScalars.count <= Self.automaticTitleScalarBound)
            #expect(panelTitle.unicodeScalars.count <= Self.automaticTitleScalarBound)
            #expect(!processTitle.contains("\n"))
            #expect(!panelTitle.contains("\n"))
            #expect(processTitle == panelTitle)
        }
        #expect(boundedData.count < rawTitle.utf8.count)
        #expect(legacyData.count > boundedData.count * 5)

        let ordinaryTitle = "ordinary short OSC title"
        let workspace = try #require(targetWorkspaces.first)
        let panelId = try #require(workspace.focusedPanelId)
        let sourceSurface = try #require(workspace.terminalPanel(for: panelId)?.surface)
        let titleScheduler = TitleScheduleRecorder()
        let ingress = GhosttyTitleUpdateIngress(schedule: titleScheduler.schedule(_:action:))
        #expect(ingress.submit(
            tabId: workspace.id,
            surfaceId: panelId,
            sourceSurfaceIdentifier: ObjectIdentifier(sourceSurface),
            terminalLifecycleID: sourceSurface.terminalLifecycleId,
            title: ordinaryTitle
        ))
        await titleScheduler.awaitFirstSchedule()
        await titleScheduler.fire()
        await drainMainQueue()
        manager.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
        #expect(workspace.processTitle == ordinaryTitle)
        #expect(workspace.panelTitles[panelId] == ordinaryTitle)
    }

    @Test
    func restoringOversizedAutomaticTitlesBoundsWorkspaceAndPanelState() throws {
        let rawTitle = Self.syntheticMultilineTitle(lineCount: 3_000)
        let source = Workspace()
        var persisted = source.sessionSnapshot(includeScrollback: false)
        persisted.processTitle = rawTitle
        for index in persisted.panels.indices {
            persisted.panels[index].title = rawTitle
            persisted.panels[index].customTitle = nil
        }

        let restored = Workspace()
        _ = restored.restoreSessionSnapshot(persisted)
        let restoredSnapshot = restored.sessionSnapshot(includeScrollback: false)

        #expect(restored.processTitle.unicodeScalars.count <= Self.automaticTitleScalarBound)
        for panel in restoredSnapshot.panels {
            #expect(panel.title?.unicodeScalars.count ?? 0 <= Self.automaticTitleScalarBound)
            #expect(!(panel.title ?? "").contains("\n"))
        }
        #expect(restoredSnapshot.processTitle.unicodeScalars.count <= Self.automaticTitleScalarBound)

        var customPersisted = persisted
        customPersisted.customTitle = "Authored custom title"
        let customRestored = Workspace()
        _ = customRestored.restoreSessionSnapshot(customPersisted)
        #expect(customRestored.customTitle == "Authored custom title")
        #expect(customRestored.title == "Authored custom title")
    }

    @Test
    func explicitWorkspaceCreationTitleKeepsItsExistingTabSemantics() throws {
        let authoredTitle = "Authored workspace name\n" + String(repeating: "x", count: 300)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.addWorkspaceIfActive(
            title: authoredTitle,
            titleSource: .user,
            select: false,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false
        ))
        let panelId = try #require(workspace.focusedPanelId)
        let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.customTitle == authoredTitle)
        #expect(workspace.bonsplitController.tab(surfaceId)?.title == authoredTitle)
    }

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

    private static func syntheticMultilineTitle(lineCount: Int) -> String {
        (0..<lineCount)
            .map { "synthetic-title-line-\($0): generated fixture text\n" }
            .joined()
    }

    private static func medianEncodeMilliseconds(
        for snapshot: SessionTabManagerSnapshot
    ) -> Double {
        _ = try? JSONEncoder().encode(snapshot)
        let measurements = (0..<10).map { _ in
            let startedAt = DispatchTime.now().uptimeNanoseconds
            _ = try? JSONEncoder().encode(snapshot)
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
            return Double(elapsedNanoseconds) / 1_000_000
        }
        return measurements.sorted()[measurements.count / 2]
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
