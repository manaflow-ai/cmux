import CMUXMobileCore
import CmuxTerminalCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MobileHostTerminalThemeTests {
    @Test func hostStatusPreservesCellRelativeColorSemantics() throws {
        var config = GhosttyConfig()
        config.parse("""
        cursor-color = cell-foreground
        cursor-text = cell-background
        selection-background = cell-foreground
        selection-foreground = cell-background
        """)

        let theme = TerminalTheme(ghosttyConfig: config)
        let data = try JSONSerialization.data(withJSONObject: theme.mobileHostJSONObject)
        let decoded = try JSONDecoder().decode(TerminalTheme.self, from: data)

        #expect(decoded.cursorColorSemantic == .foreground)
        #expect(decoded.cursorTextSemantic == .background)
        #expect(decoded.selectionBackgroundSemantic == .foreground)
        #expect(decoded.selectionForegroundSemantic == .background)
    }

    @Test func surfaceEffectiveColorsOverrideCachedConfigTheme() throws {
        var base = TerminalTheme.monokai
        base.cursorColorSemantic = .background
        base.cursorText = "#abcdef"
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface-theme",
            stateSeq: 1,
            columns: 2,
            rows: 1,
            rowSpans: [],
            terminalForeground: "#112233",
            terminalBackground: "#f0ead6",
            terminalCursorColor: "#445566"
        )

        let resolved = base.applyingSurfaceColors(from: frame)

        #expect(resolved.background == "#f0ead6")
        #expect(resolved.foreground == "#112233")
        #expect(resolved.cursor == "#445566")
        #expect(resolved.cursorColorSemantic == nil)
        #expect(resolved.cursorText == "#abcdef")
        #expect(resolved.palette == base.palette)
    }

    @Test func rendererEffectiveThemeWinsOverRawOSCOverrides() throws {
        var effective = TerminalTheme.monokai
        effective.background = "#eeeeee"
        effective.foreground = "#111111"
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface-reverse-theme",
            stateSeq: 1,
            columns: 2,
            rows: 1,
            rowSpans: [],
            terminalForeground: "#eeeeee",
            terminalBackground: "#111111",
            terminalTheme: effective
        )

        let resolved = TerminalTheme.monokai.applyingSurfaceColors(from: frame)

        #expect(resolved == effective)
    }

    @Test func reverseModeMakesRawV1DefaultsEffectiveForChrome() throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface-reverse-theme",
            stateSeq: 1,
            columns: 2,
            rows: 1,
            rowSpans: [],
            modes: [.init(code: 5, ansi: false, on: true)],
            terminalForeground: "#111111",
            terminalBackground: "#eeeeee"
        )

        let resolved = TerminalTheme.monokai.applyingSurfaceColors(from: frame)

        #expect(resolved.background == "#111111")
        #expect(resolved.foreground == "#eeeeee")
    }

    @MainActor
    @Test func producerThemeInvalidationsCoalesceToLatestSurfaceBatch() async {
        let first = UUID()
        let second = UUID()
        let clock = ThemeInvalidationTestClock()
        let batches = AsyncStream<Set<UUID>>.makeStream()
        defer { batches.continuation.finish() }
        let scheduler = MobileTerminalThemeInvalidationScheduler(
            delay: .milliseconds(100),
            clock: clock
        ) {
            batches.continuation.yield($0)
        }

        scheduler.schedule(surfaceID: first)
        scheduler.schedule(surfaceID: first)
        scheduler.schedule(surfaceID: second)
        await clock.waitUntilSleeping()
        clock.advance(by: .milliseconds(100))
        var iterator = batches.stream.makeAsyncIterator()
        let batch = await iterator.next()

        #expect(batch == Set([first, second]))
    }

    @MainActor
    @Test func cancellingProducerThemeInvalidationDropsPendingBatch() async {
        let clock = ThemeInvalidationTestClock()
        var batches: [Set<UUID>] = []
        let scheduler = MobileTerminalThemeInvalidationScheduler(
            delay: .milliseconds(100),
            clock: clock
        ) {
            batches.append($0)
        }

        scheduler.schedule(surfaceID: UUID())
        await clock.waitUntilSleeping()
        scheduler.cancel()
        await clock.waitUntilIdle()

        #expect(batches.isEmpty)
    }

    @Test func ordinaryTicksDeferChangedThemeUntilProducerBatch() {
        var cached = TerminalTheme.monokai
        cached.background = "#101522"
        var candidate = TerminalTheme.monokai
        candidate.background = "#f4f0df"

        let ordinaryTick = MobileTerminalThemeEmissionDecision.resolve(
            candidate: candidate,
            cached: cached,
            forceCandidate: false
        )
        let invalidationBatch = MobileTerminalThemeEmissionDecision.resolve(
            candidate: candidate,
            cached: cached,
            forceCandidate: true
        )

        #expect(ordinaryTick.theme == cached)
        #expect(ordinaryTick.shouldScheduleCandidate)
        #expect(invalidationBatch.theme == candidate)
        #expect(!invalidationBatch.shouldScheduleCandidate)
    }

    @Test func themeElidedSnapshotRetainsRawConfigTheme() {
        var cached = TerminalTheme.monokai
        cached.background = "#f4f0df"

        let retained = MobileTerminalThemeEmissionDecision.resolveConfigTheme(
            candidate: nil,
            cached: cached
        )
        let replaced = MobileTerminalThemeEmissionDecision.resolveConfigTheme(
            candidate: .monokai,
            cached: cached
        )

        #expect(retained == cached)
        #expect(replaced == .monokai)
    }

    @Test func rendererConfigThemeInheritsBoldColorForLiveAndReplayFrames() {
        var candidate = TerminalTheme.monokai
        candidate.boldColor = nil

        let resolved = MobileTerminalThemeEmissionDecision.resolveConfigTheme(
            candidate: candidate,
            cached: nil,
            fallbackBoldColor: "#4e2a84"
        )

        #expect(resolved?.boldColor == "#4e2a84")
    }
}

private final class ThemeInvalidationTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentInstant
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledSleeperIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= currentInstant {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                let waiters = sleepWaiters
                sleepWaiters.removeAll()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil { cancelledSleeperIDs.insert(id) }
            let waiters = sleepers.isEmpty ? idleWaiters : []
            if sleepers.isEmpty { idleWaiters.removeAll() }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilSleeping() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if sleepers.isEmpty {
                sleepWaiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        var due: [Sleeper] = []
        for (id, sleeper) in sleepers where sleeper.deadline <= currentInstant {
            sleepers[id] = nil
            due.append(sleeper)
        }
        let waiters = sleepers.isEmpty ? idleWaiters : []
        if sleepers.isEmpty { idleWaiters.removeAll() }
        lock.unlock()
        for sleeper in due { sleeper.continuation.resume() }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if sleepers.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
