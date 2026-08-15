import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-policy tests for `RendererRealizationPlanner`, the decision for which
/// offscreen terminal surfaces release their GPU renderer (Metal swap chain /
/// IOSurface) while keeping their PTY alive.
struct RendererRealizationPlannerTests {
    @Test func catalogDefaultsMatchRuntimeReclamationPolicy() {
        let terminal = SettingCatalog().terminal

        #expect(
            terminal.rendererRealizationIdleSeconds.defaultValue
                == RendererRealizationSettings.defaultIdleSeconds
        )
        #expect(
            terminal.rendererRealizationMaxWarmRenderers.defaultValue
                == RendererRealizationSettings.defaultMaxWarmRenderers
        )
    }

    private func input(
        _ id: UUID,
        visible: Bool = false,
        realized: Bool = true,
        lastVisibleAt: TimeInterval
    ) -> RendererRealizationPlannerInput {
        RendererRealizationPlannerInput(
            surfaceId: id,
            isVisible: visible,
            isRealized: realized,
            lastVisibleAt: lastVisibleAt
        )
    }

    private func settings(
        enabled: Bool = true,
        idle: TimeInterval = 30,
        warm: Int = 12
    ) -> RendererRealizationSettings.Values {
        .init(enabled: enabled, idleSeconds: idle, maxWarmRenderers: warm)
    }

    @Test func disabledSelectsNothing() {
        let now: TimeInterval = 1000
        let inputs = [input(UUID(), lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(enabled: false), now: now
        )
        #expect(selected.isEmpty)
    }

    @Test func neverSelectsVisibleSurface() {
        let now: TimeInterval = 1000
        let visible = UUID()
        // Visible and very idle and warm cap 0: must still never be selected.
        let inputs = [input(visible, visible: true, lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 0), now: now
        )
        #expect(!selected.contains(visible))
    }

    @Test func respectsIdleThreshold() {
        let now: TimeInterval = 1000
        let recent = UUID() // idle 2s < 5s
        let old = UUID()    // idle 100s
        let inputs = [
            input(recent, lastVisibleAt: now - 2),
            input(old, lastVisibleAt: now - 100),
        ]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 0), now: now
        )
        #expect(!selected.contains(recent))
        #expect(selected.contains(old))
    }

    @Test func keepsWarmCapMostRecent() {
        let now: TimeInterval = 1000
        var ids: [UUID] = []
        var inputs: [RendererRealizationPlannerInput] = []
        for i in 0..<5 {
            let id = UUID()
            ids.append(id)
            // i = 0 is most recently visible; all are idle past the threshold.
            inputs.append(input(id, lastVisibleAt: now - TimeInterval(100 + i)))
        }
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 2), now: now
        )
        #expect(selected.count == 3)
        #expect(!selected.contains(ids[0])) // 2 most-recent kept warm
        #expect(!selected.contains(ids[1]))
        #expect(selected.contains(ids[2]))
        #expect(selected.contains(ids[4])) // oldest released
    }

    @Test func defaultFiveTabBaselineReclaimsFourHiddenRenderers() throws {
        let suiteName = "RendererRealizationPlannerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now: TimeInterval = 1000
        let visible = UUID()
        let hidden = (0..<4).map { _ in UUID() }
        let settings = RendererRealizationSettings.values(defaults: defaults)
        let inputs = [
            input(visible, visible: true, lastVisibleAt: now),
        ] + hidden.map {
            input(
                $0,
                lastVisibleAt: now - settings.idleSeconds
            )
        }
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs,
            settings: settings,
            now: now
        )

        #expect(selected == Set(hidden))
    }

    @Test func defaultFiveTabBaselineSchedulesTheIdleDeadline() throws {
        let suiteName = "RendererRealizationPlannerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now: TimeInterval = 1000
        let visible = UUID()
        let hidden = (0..<4).map { _ in UUID() }
        let settings = RendererRealizationSettings.values(defaults: defaults)
        let inputs = [
            input(visible, visible: true, lastVisibleAt: now),
        ] + hidden.map {
            input($0, lastVisibleAt: now)
        }

        let deadline = RendererRealizationController.nextScheduledReclaimDeadline(
            inputs: inputs,
            settings: settings,
            now: now
        )

        #expect(deadline == now + settings.idleSeconds)
    }

    @Test func deadlineSchedulerIgnoresAlreadyEligibleWarmRenderer() {
        let now: TimeInterval = 1000
        let deadline = RendererRealizationController.nextScheduledReclaimDeadline(
            inputs: [input(UUID(), lastVisibleAt: now - 100)],
            settings: settings(idle: 5, warm: 1),
            now: now
        )

        #expect(deadline == nil)
    }

    @Test func deadlineSchedulerIgnoresVisibleAndReleasedRenderers() {
        let now: TimeInterval = 1000
        let deadline = RendererRealizationController.nextScheduledReclaimDeadline(
            inputs: [
                input(UUID(), visible: true, lastVisibleAt: now),
                input(UUID(), realized: false, lastVisibleAt: now),
            ],
            settings: settings(idle: 5, warm: 1),
            now: now
        )

        #expect(deadline == nil)
    }

    @Test @MainActor
    func visibilityBurstRunsOneSnapshotAndReclaimsFourAtFiveSeconds() async {
        let harness = RendererRealizationSchedulerHarness(surfaceCount: 5)
        harness.controller.start()
        defer { harness.controller.stop() }

        let hiddenSurfaces = Array(harness.surfaces.dropFirst())
        harness.hide(hiddenSurfaces[0])
        harness.postVisibilityChange(for: hiddenSurfaces[0])
        await harness.sleeper.waitUntilSleeping(for: 0.016)
        for surface in hiddenSurfaces.dropFirst() {
            await harness.advance(by: 0.004)
            harness.hide(surface)
            harness.postVisibilityChange(for: surface)
        }

        await harness.advance(by: 0.004)
        await harness.evaluations.wait(until: 2)
        await harness.sleeper.waitUntilAnySleep()

        // One initial pass plus one coalesced pass for all four notifications.
        #expect(harness.snapshotCount == 2)
        #expect(harness.surfaces.reduce(0) { $0 + $1.releaseCount } == 0)

        // The four hide timestamps span 12 ms. Their idle deadlines remain one
        // reclaim batch, so the earliest timestamp cannot fan back out into an
        // app-wide evaluation before the batch's latest timestamp is eligible.
        await harness.advance(by: 4.984)
        #expect(await harness.sleeper.isSleeping(for: 0.012))
        #expect(harness.surfaces.reduce(0) { $0 + $1.releaseCount } == 0)

        await harness.advance(by: 0.012)
        await harness.evaluations.wait(until: 3)

        #expect(harness.surfaces.dropFirst().allSatisfy { $0.releaseCount == 1 })
        #expect(harness.surfaces.first?.releaseCount == 0)
    }

    @Test @MainActor
    func revealCancelsPendingRendererReclaimDeadline() async {
        let harness = RendererRealizationSchedulerHarness(surfaceCount: 2)
        harness.controller.start()
        defer { harness.controller.stop() }
        let hidden = harness.surfaces[1]

        harness.hide(hidden)
        harness.postVisibilityChange(for: hidden)
        await harness.sleeper.waitUntilSleeping(for: 0.016)
        await harness.advance(by: 0.016)
        await harness.evaluations.wait(until: 2)
        await harness.sleeper.waitUntilAnySleep()

        harness.reveal(hidden)
        harness.postVisibilityChange(for: hidden)
        await harness.sleeper.waitUntilSleeping(for: 0.016)
        await harness.advance(by: 0.016)
        await harness.evaluations.wait(until: 3)
        await harness.sleeper.waitUntilIdle()

        await harness.advance(by: 10)
        #expect(hidden.releaseCount == 0)
    }

    @Test @MainActor
    func stopCancelsPendingRendererReclaimDeadline() async {
        let harness = RendererRealizationSchedulerHarness(surfaceCount: 2)
        harness.controller.start()
        let hidden = harness.surfaces[1]

        harness.hide(hidden)
        harness.postVisibilityChange(for: hidden)
        await harness.sleeper.waitUntilSleeping(for: 0.016)
        await harness.advance(by: 0.016)
        await harness.evaluations.wait(until: 2)
        await harness.sleeper.waitUntilAnySleep()

        harness.controller.stop()
        await harness.sleeper.waitUntilIdle()
        await harness.advance(by: 10)
        #expect(hidden.releaseCount == 0)
    }

    @Test func onlyRealizedSurfacesAreConsidered() {
        let now: TimeInterval = 1000
        let unrealized = UUID()
        let inputs = [input(unrealized, realized: false, lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 0), now: now
        )
        #expect(selected.isEmpty)
    }

    @Test func visibleSurfaceOccupiesWarmSlotButIsNeverSelected() {
        let now: TimeInterval = 1000
        let visible = UUID()
        let off1 = UUID()
        let off2 = UUID()
        let off3 = UUID()
        let inputs = [
            input(visible, visible: true, lastVisibleAt: now), // rank 1 (warm)
            input(off1, lastVisibleAt: now - 10),              // rank 2 (warm)
            input(off2, lastVisibleAt: now - 20),              // rank 3 (release)
            input(off3, lastVisibleAt: now - 30),              // rank 4 (release)
        ]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 2), now: now
        )
        #expect(!selected.contains(visible))
        #expect(!selected.contains(off1))
        #expect(selected.contains(off2))
        #expect(selected.contains(off3))
    }

    @Test func deterministicTieBreakById() {
        let now: TimeInterval = 1000
        // Two surfaces with identical timestamps, warm cap 1: the tie-break
        // sorts by ascending uuidString, so the lower id is kept warm and the
        // higher id is released. Deterministic regardless of input order.
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let inputs = [
            input(a, lastVisibleAt: now - 100),
            input(b, lastVisibleAt: now - 100),
        ]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 1), now: now
        )
        #expect(selected.count == 1)
        #expect(selected.contains(b))
        #expect(!selected.contains(a))
    }

    @Test func systemMemoryPressureReclaimsAllHiddenRealizedRenderers() {
        let now: TimeInterval = 1000
        let visible = UUID()
        let recentHidden = UUID()
        let oldHidden = UUID()
        let alreadyReleased = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [
                input(visible, visible: true, lastVisibleAt: now),
                input(recentHidden, lastVisibleAt: now - 1),
                input(oldHidden, lastVisibleAt: now - 100),
                input(alreadyReleased, realized: false, lastVisibleAt: now - 100),
            ],
            settings: settings(idle: 600, warm: 12),
            now: now,
            trigger: .systemMemoryPressure
        )

        #expect(!selected.contains(visible))
        #expect(selected.contains(recentHidden))
        #expect(selected.contains(oldHidden))
        #expect(!selected.contains(alreadyReleased))
    }

    @Test func systemMemoryPressureRespectsDisabledSetting() {
        let now: TimeInterval = 1000
        let hidden = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [input(hidden, lastVisibleAt: now - 1)],
            settings: settings(enabled: false, idle: 600, warm: 12),
            now: now,
            trigger: .systemMemoryPressure
        )

        #expect(selected.isEmpty)
    }
}

@MainActor
private final class RendererRealizationSchedulerHarness {
    let notificationCenter = NotificationCenter()
    let sleeper = RendererRealizationManualSleeper()
    let evaluations = RendererRealizationEvaluationProbe()
    let surfaces: [RendererRealizationTestSurface]
    var now: TimeInterval = 1_000
    var snapshotCount = 0

    lazy var controller = RendererRealizationController(
        notificationCenter: notificationCenter,
        surfaceProvider: { [unowned self] in
            snapshotCount += 1
            return surfaces.map { $0 as any RendererRealizationSurface }
        },
        surfaceLookup: { [unowned self] id in
            surfaces.first { $0.id == id }
        },
        settingsProvider: {
            .init(enabled: true, idleSeconds: 5, maxWarmRenderers: 1)
        },
        nowProvider: { [unowned self] in
            Date(timeIntervalSince1970: now)
        },
        sleepFor: { [sleeper] duration in
            try await sleeper.sleep(for: duration)
        },
        onEvaluationCompleted: { [evaluations] in
            evaluations.record()
        }
    )

    init(surfaceCount: Int) {
        self.surfaces = (0..<surfaceCount).map { _ in
            RendererRealizationTestSurface(now: { 1_000 })
        }
        for surface in surfaces {
            surface.now = { [weak self] in self?.now ?? 1_000 }
        }
    }

    func hide(_ surface: RendererRealizationTestSurface) {
        surface.isRendererPortalVisible = false
        surface.rendererLastVisibleAt = now
    }

    func reveal(_ surface: RendererRealizationTestSurface) {
        surface.isRendererPortalVisible = true
    }

    func postVisibilityChange(for surface: RendererRealizationTestSurface) {
        notificationCenter.post(
            name: .terminalPortalVisibilityDidChange,
            object: surface
        )
    }

    func advance(by seconds: TimeInterval) async {
        now += seconds
        await sleeper.advance(by: seconds)
    }
}

@MainActor
private final class RendererRealizationEvaluationProbe {
    private var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        var completed: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            if count >= waiter.target {
                completed.append(waiter.continuation)
                return true
            }
            return false
        }
        for continuation in completed { continuation.resume() }
    }

    func wait(until target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

@MainActor
private final class RendererRealizationTestSurface: RendererRealizationSurface {
    let id = UUID()
    var hasLiveSurface = true
    var isRendererPortalVisible = true
    var isRendererRealized = true
    var isRendererPresented = true
    var rendererLastVisibleAt: TimeInterval
    var releaseCount = 0
    var now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval) {
        self.now = now
        self.rendererLastVisibleAt = now()
    }

    func noteBecameVisibleForRendererReclamation() {
        rendererLastVisibleAt = now()
    }

    func ensureRendererPresented() {
        isRendererPresented = true
        isRendererRealized = true
    }

    func releaseRenderer() -> Bool {
        guard hasLiveSurface, !isRendererPortalVisible, isRendererRealized else { return false }
        isRendererRealized = false
        isRendererPresented = false
        releaseCount += 1
        return true
    }

    func retryRendererPresentationAfterActivity() {}
}

private actor RendererRealizationManualSleeper {
    private struct PendingSleep {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct SleepWaiter {
        let duration: TimeInterval?
        let continuation: CheckedContinuation<Void, Never>
    }

    private var now: TimeInterval = 0
    private var pending: [UUID: PendingSleep] = [:]
    private var waiters: [SleepWaiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let seconds = Self.seconds(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingSleep(deadline: now + seconds, continuation: continuation)
                resumeMatchingWaiters()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitUntilSleeping(for duration: TimeInterval) async {
        if hasPendingSleep(for: duration) { return }
        await withCheckedContinuation { continuation in
            waiters.append(SleepWaiter(duration: duration, continuation: continuation))
        }
    }

    func waitUntilAnySleep() async {
        if !pending.isEmpty { return }
        await withCheckedContinuation { continuation in
            waiters.append(SleepWaiter(duration: nil, continuation: continuation))
        }
    }

    func isSleeping(for duration: TimeInterval) -> Bool {
        hasPendingSleep(for: duration)
    }

    func waitUntilIdle() async {
        if pending.isEmpty { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let dueIDs = pending.compactMap { id, sleep in
            sleep.deadline <= now + 0.000_001 ? id : nil
        }
        let due = dueIDs.compactMap { pending.removeValue(forKey: $0) }
        for sleep in due {
            sleep.continuation.resume()
        }
        resumeIdleWaitersIfNeeded()
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        resumeIdleWaitersIfNeeded()
    }

    private func hasPendingSleep(for duration: TimeInterval) -> Bool {
        pending.values.contains { abs(($0.deadline - now) - duration) < 0.000_001 }
    }

    private func resumeMatchingWaiters() {
        var matched: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            let isMatch = waiter.duration.map(hasPendingSleep(for:)) ?? !pending.isEmpty
            if isMatch { matched.append(waiter.continuation) }
            return isMatch
        }
        for continuation in matched { continuation.resume() }
    }

    private func resumeIdleWaitersIfNeeded() {
        guard pending.isEmpty else { return }
        let continuations = idleWaiters
        idleWaiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
