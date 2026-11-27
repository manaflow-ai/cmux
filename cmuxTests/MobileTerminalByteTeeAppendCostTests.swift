import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The byte tee's replay buffer must cost O(chunk) per appended output
/// chunk, not O(retained window). A field profile pinned multi-second
/// typing freezes to a full copy-on-write memmove of the retained window on
/// every chunk (`publishFromMain` -> `Data.append` ->
/// `ensureUniqueReference` -> memmove), which starves MainActor input
/// acceptance under agent output floods: fleet windows carrying >1MB of
/// output show keystroke-to-visible p50 ~2s and p95 ~32s, and in the rig
/// reproduction the host accepted 2 of 91 keystroke batches (after 24s and
/// 72s) during a ~MB/s stream.
///
/// Copies are observed deterministically through the buffer's backing base
/// address: a unique in-place append preserves it (up to rare capacity
/// growth and amortized compaction), while a shared-storage append
/// relocates it every single time. No wall-clock timing is involved.
@MainActor
@Suite("Byte tee append cost")
struct MobileTerminalByteTeeAppendCostTests {
    private func replayBufferAddress(
        _ tee: MobileTerminalByteTee,
        surfaceID: UUID
    ) -> UInt? {
        tee.state(for: surfaceID).replayBuffer.withUnsafeBytes { raw in
            UInt(bitPattern: raw.baseAddress)
        }
    }

    @Test func steadyStateAppendsDoNotCopyTheRetainedWindowPerChunk() {
        let tee = MobileTerminalByteTee.shared
        let surfaceID = UUID()
        defer { tee.dropSurface(surfaceID: surfaceID) }
        let chunk = Data(repeating: 0x61, count: 4_096)
        // Fill past the retention budget so every measured append runs at
        // steady state (trim active), the regime agent floods live in.
        for _ in 0..<80 {
            tee.publishFromMain(surfaceID: surfaceID, data: chunk)
        }
        var relocations = 0
        var previous = replayBufferAddress(tee, surfaceID: surfaceID)
        for _ in 0..<200 {
            tee.publishFromMain(surfaceID: surfaceID, data: chunk)
            let current = replayBufferAddress(tee, surfaceID: surfaceID)
            if current != previous { relocations += 1 }
            previous = current
        }
        // In-place appends relocate only on occasional capacity growth plus
        // amortized compaction: a handful per 800KB appended. A per-chunk
        // copy-on-write relocates on all 200.
        #expect(
            relocations <= 20,
            "replay buffer backing relocated on \(relocations)/200 appends: the retained window is being copied per chunk"
        )
    }

    @Test func replayWindowContentAndSequenceSurviveCompaction() {
        let tee = MobileTerminalByteTee.shared
        let surfaceID = UUID()
        defer { tee.dropSurface(surfaceID: surfaceID) }
        // A patterned stream long enough to cross the compaction boundary,
        // so the optimization is proven to change cost, not content.
        var stream = Data()
        var pattern: UInt8 = 0
        while stream.count < 700 * 1024 {
            let chunk = Data(repeating: pattern, count: 4_096)
            tee.publishFromMain(surfaceID: surfaceID, data: chunk)
            stream.append(chunk)
            pattern = pattern &+ 1
        }
        let handout = tee.replayState(surfaceID: surfaceID)
        #expect(handout?.seq == UInt64(stream.count))
        #expect(handout?.data.count == 256 * 1024)
        #expect(handout?.data == stream.suffix(256 * 1024))
    }

    @Test func replayHandoutDoesNotTaxSubsequentAppends() {
        let tee = MobileTerminalByteTee.shared
        let surfaceID = UUID()
        defer { tee.dropSurface(surfaceID: surfaceID) }
        let chunk = Data(repeating: 0x62, count: 4_096)
        for _ in 0..<8 {
            tee.publishFromMain(surfaceID: surfaceID, data: chunk)
        }
        // Warm probe so a possible exact-capacity growth happens before the
        // measurement, then hold a cold-attach handout across an append.
        tee.publishFromMain(surfaceID: surfaceID, data: Data(repeating: 0x63, count: 64))
        let handout = tee.replayState(surfaceID: surfaceID)
        #expect(handout != nil)
        let before = replayBufferAddress(tee, surfaceID: surfaceID)
        tee.publishFromMain(surfaceID: surfaceID, data: Data(repeating: 0x64, count: 64))
        let after = replayBufferAddress(tee, surfaceID: surfaceID)
        withExtendedLifetime(handout) {}
        #expect(
            before == after,
            "an append while a cold-attach replay handout is held copied the live buffer: the handout shares the retained window's storage"
        )
    }
}
