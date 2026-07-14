@testable import CmuxLiteCore
import Foundation
import Testing

@Suite
struct CmuxTerminalChunkTests {
    @Test
    func deferredInitialReplayRetainsGridAndOrdersBytesBeforeClaim() {
        let bytes = Data([0x1B, 0x5B, 0x32, 0x4A])
        let grid = CmuxSurfaceSize(cols: 101, rows: 37)
        let chunk = CmuxTerminalChunk.replay(
            bytes: bytes,
            grid: grid,
            claimAfterReplay: true
        )

        #expect(chunk.replayGrid == grid)
        #expect(chunk.ingestionSteps == [
            .awaitCurrentBytes,
            .sizeForReplay(grid),
            .receive(bytes),
            .awaitReceivedBytes,
            .fitToView,
            .claimLocalGrid,
        ])
    }

    @Test
    func deferredResizedReplayRetainsItsOwnGrid() {
        let bytes = Data([0x1B, 0x5B, 0x48])
        let grid = CmuxSurfaceSize(cols: 73, rows: 21)
        let chunk = CmuxTerminalChunk.replay(
            bytes: bytes,
            grid: grid,
            claimAfterReplay: false
        )

        #expect(chunk.replayGrid == grid)
        #expect(chunk.ingestionSteps == [
            .awaitCurrentBytes,
            .sizeForReplay(grid),
            .receive(bytes),
            .awaitReceivedBytes,
            .fitToView,
        ])
    }

    @Test
    func liveOutputDoesNotResizeTheMirror() {
        let bytes = Data("next output".utf8)
        let chunk = CmuxTerminalChunk.output(bytes: bytes)

        #expect(chunk.replayGrid == nil)
        #expect(chunk.ingestionSteps == [.receive(bytes)])
    }

    @Test
    func initialLiveOutputWaitsForParsingWithoutResizing() {
        let bytes = Data("first prompt".utf8)
        let chunk = CmuxTerminalChunk.output(
            bytes: bytes,
            waitForIngestion: true
        )

        #expect(chunk.replayGrid == nil)
        #expect(chunk.ingestionSteps == [
            .receive(bytes),
            .awaitReceivedBytes,
        ])
    }

    @Test
    func pendingDrainPreservesEachReplayGridAndStreamOrder() {
        let initialBytes = Data("initial".utf8)
        let outputBytes = Data("output".utf8)
        let resizedBytes = Data("resized".utf8)
        let initialGrid = CmuxSurfaceSize(cols: 101, rows: 37)
        let resizedGrid = CmuxSurfaceSize(cols: 73, rows: 21)
        let chunks = [
            CmuxTerminalChunk.replay(
                bytes: initialBytes,
                grid: initialGrid,
                claimAfterReplay: true
            ),
            CmuxTerminalChunk.output(bytes: outputBytes),
            CmuxTerminalChunk.replay(
                bytes: resizedBytes,
                grid: resizedGrid,
                claimAfterReplay: false
            ),
        ]

        #expect(chunks.flatMap(\.ingestionSteps) == [
            .awaitCurrentBytes,
            .sizeForReplay(initialGrid),
            .receive(initialBytes),
            .awaitReceivedBytes,
            .fitToView,
            .claimLocalGrid,
            .receive(outputBytes),
            .awaitCurrentBytes,
            .sizeForReplay(resizedGrid),
            .receive(resizedBytes),
            .awaitReceivedBytes,
            .fitToView,
        ])
    }
}
