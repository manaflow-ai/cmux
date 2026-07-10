import CmuxTerminal
import CoreGraphics
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private actor TerminalInlineImageThumbnailDecodeProbe {
    private let result: TerminalInlineImageThumbnail?
    private var startedCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var isOpen = false
    private var blockedDecodes: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(result: TerminalInlineImageThumbnail? = nil) {
        self.result = result
    }

    func decode(path _: String) async -> TerminalInlineImageThumbnail? {
        startedCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        resumeSatisfiedStartWaiters()
        if !isOpen {
            await withCheckedContinuation { continuation in
                blockedDecodes.append(continuation)
            }
        }
        activeCount -= 1
        return result
    }

    func waitUntilStarted(_ count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func open() {
        isOpen = true
        let continuations = blockedDecodes
        blockedDecodes.removeAll()
        continuations.forEach { $0.resume() }
    }

    func snapshot() -> (started: Int, maximumActive: Int) {
        (startedCount, maximumActiveCount)
    }

    private func resumeSatisfiedStartWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in startWaiters {
            if startedCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        startWaiters = pending
    }
}

@Suite
struct TerminalInlineImagePipelineTests {
    @Test
    func renderedFrameGateIgnoresPaintOnlyFramesAndCoalescesMutations() {
        var gate = TerminalInlineImageRenderedFrameGate()

        let initialFrame = gate.consumeRenderedFrame()
        #expect(!initialFrame)
        gate.noteGridMutation()
        gate.noteGridMutation()
        let mutationFrame = gate.consumeRenderedFrame()
        #expect(mutationFrame)
        let followingPaintFrame = gate.consumeRenderedFrame()
        #expect(!followingPaintFrame)

        gate.noteGridMutation()
        gate.reset()
        let frameAfterReset = gate.consumeRenderedFrame()
        #expect(!frameAfterReset)
    }

    @Test
    func scanGateRunsOneSnapshotAndCoalescesABurstIntoOneFollowUp() throws {
        var gate = TerminalInlineImageScanGate()

        let maybeFirst = gate.requestScan()
        let first = try #require(maybeFirst)
        #expect(gate.requestScan() == nil)
        #expect(gate.requestScan() == nil)
        #expect(gate.hasPendingScan)

        let maybeFollowUp = gate.completeScan(first)
        let followUp = try #require(maybeFollowUp)
        #expect(!gate.hasPendingScan)
        #expect(gate.completeScan(followUp) == nil)
        #expect(gate.isIdle)
    }

    @Test
    func scanGateDropsPendingWorkWhenTheSurfaceSessionEnds() throws {
        var gate = TerminalInlineImageScanGate()

        let maybeInFlight = gate.requestScan()
        let inFlight = try #require(maybeInFlight)
        #expect(gate.requestScan() == nil)
        gate.discardPendingScan()
        gate.cancelScan(inFlight)

        #expect(gate.completeScan(inFlight) == nil)
        #expect(gate.isIdle)
    }

    @MainActor
    @Test
    func outputServiceIgnoresSurfacesWithoutDemand() {
        let center = NotificationCenter()
        let scheduledTickCount = OSAllocatedUnfairLock(initialState: 0)
        let deliveredCount = OSAllocatedUnfairLock(initialState: 0)
        let tickDemand = RenderDemandCounter()
        let service = TerminalInlineImageOutputService(
            notificationCenter: center,
            scheduleTick: {
                scheduledTickCount.withLock { $0 += 1 }
            },
            retainTickDemand: {
                tickDemand.retain()
            }
        )
        let demandedSurfaceID = UUID()
        let ignoredSurfaceID = UUID()
        let observer = center.addObserver(
            forName: service.notificationName(for: demandedSurfaceID),
            object: nil,
            queue: nil
        ) { _ in
            deliveredCount.withLock { $0 += 1 }
        }
        defer { center.removeObserver(observer) }

        let release = service.retainNotifications(for: demandedSurfaceID)
        service.noteSurfaceOutput(surfaceID: ignoredSurfaceID)
        #expect(scheduledTickCount.withLock { $0 } == 0)

        service.noteSurfaceOutput(surfaceID: demandedSurfaceID)
        #expect(scheduledTickCount.withLock { $0 } == 1)
        center.post(name: .ghosttyDidTick, object: nil)
        #expect(deliveredCount.withLock { $0 } == 1)

        release()
        service.noteSurfaceOutput(surfaceID: demandedSurfaceID)
        #expect(scheduledTickCount.withLock { $0 } == 1)
    }

    @Test
    func thumbnailCacheDeduplicatesConcurrentRequestsForOneFileVersion() async {
        let probe = TerminalInlineImageThumbnailDecodeProbe()
        let cache = TerminalInlineImageThumbnailCache(
            maximumConcurrentDecodes: 2,
            maximumPendingDecodes: 16,
            metadataKeyProvider: { "\($0)|version-1" },
            decode: { path in await probe.decode(path: path) }
        )

        let first = Task { await cache.thumbnail(for: "/tmp/shared.png") }
        let second = Task { await cache.thumbnail(for: "/tmp/shared.png") }
        await probe.waitUntilStarted(1)
        await probe.open()
        _ = await (first.value, second.value)

        let snapshot = await probe.snapshot()
        #expect(snapshot.started == 1)
    }

    @Test
    func thumbnailCacheBoundsConcurrentDecodeWork() async {
        let probe = TerminalInlineImageThumbnailDecodeProbe()
        let cache = TerminalInlineImageThumbnailCache(
            maximumConcurrentDecodes: 2,
            maximumPendingDecodes: 16,
            metadataKeyProvider: { "\($0)|version-1" },
            decode: { path in await probe.decode(path: path) }
        )
        let tasks = (0..<6).map { index in
            Task { await cache.thumbnail(for: "/tmp/\(index).png") }
        }

        await probe.waitUntilStarted(2)
        await probe.open()
        for task in tasks {
            _ = await task.value
        }

        let snapshot = await probe.snapshot()
        #expect(snapshot.started == 6)
        #expect(snapshot.maximumActive == 2)
    }

    @Test
    func clearingThumbnailCacheInvalidatesInFlightDecodeResults() async throws {
        let thumbnail = try makeThumbnail()
        let probe = TerminalInlineImageThumbnailDecodeProbe(result: thumbnail)
        let cache = TerminalInlineImageThumbnailCache(
            maximumConcurrentDecodes: 1,
            maximumPendingDecodes: 4,
            metadataKeyProvider: { "\($0)|version-1" },
            decode: { path in await probe.decode(path: path) }
        )

        let staleRequest = Task { await cache.thumbnail(for: "/tmp/stale.png") }
        await probe.waitUntilStarted(1)
        await cache.removeAll()
        #expect(await staleRequest.value == nil)

        let currentRequest = Task { await cache.thumbnail(for: "/tmp/stale.png") }
        await probe.open()
        #expect(await currentRequest.value != nil)
        let snapshot = await probe.snapshot()
        #expect(snapshot.started == 2)
    }

    @Test
    func replacementRequestDoesNotJoinCanceledDecode() async throws {
        let probe = TerminalInlineImageThumbnailDecodeProbe(result: try makeThumbnail())
        let cache = TerminalInlineImageThumbnailCache(
            maximumConcurrentDecodes: 1,
            maximumPendingDecodes: 4,
            metadataKeyProvider: { "\($0)|version-1" },
            decode: { path in await probe.decode(path: path) }
        )

        let canceledRequest = Task { await cache.thumbnail(for: "/tmp/replaced.png") }
        await probe.waitUntilStarted(1)
        canceledRequest.cancel()
        #expect(await canceledRequest.value == nil)

        let replacementRequest = Task { await cache.thumbnail(for: "/tmp/replaced.png") }
        await probe.open()
        #expect(await replacementRequest.value != nil)
        let snapshot = await probe.snapshot()
        #expect(snapshot.started == 2)
    }

    private func makeThumbnail() throws -> TerminalInlineImageThumbnail {
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        return TerminalInlineImageThumbnail(
            cgImage: image,
            pixelSize: CGSize(width: 1, height: 1),
            cost: 4
        )
    }
}
