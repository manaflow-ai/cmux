import Foundation

/// Retains one ordered terminal byte chunk and any replay-specific delivery metadata.
public struct CmuxTerminalChunk: Sendable, Equatable {
    /// Bytes delivered by this chunk.
    public let bytes: Data

    /// The exact authoritative grid for replay bytes, or `nil` for live output.
    public let replayGrid: CmuxSurfaceSize?

    /// Whether this replay should be followed by a local pane-size claim.
    public let claimAfterReplay: Bool

    /// Whether Ghostty must finish parsing this output before it can be presented.
    public let waitsForIngestion: Bool

    private init(
        bytes: Data,
        replayGrid: CmuxSurfaceSize?,
        claimAfterReplay: Bool,
        waitsForIngestion: Bool
    ) {
        self.bytes = bytes
        self.replayGrid = replayGrid
        self.claimAfterReplay = claimAfterReplay
        self.waitsForIngestion = waitsForIngestion
    }

    /// Creates replay delivery that sizes the mirror before bytes and reconciles it afterward.
    /// - Parameters:
    ///   - bytes: The authoritative VT replay bytes.
    ///   - grid: The exact grid at which the server captured the replay.
    ///   - claimAfterReplay: Whether to claim the local pane grid after delivery.
    /// - Returns: A replay chunk that preserves its sizing and ordering contract.
    public static func replay(
        bytes: Data,
        grid: CmuxSurfaceSize,
        claimAfterReplay: Bool
    ) -> CmuxTerminalChunk {
        CmuxTerminalChunk(
            bytes: bytes,
            replayGrid: grid,
            claimAfterReplay: claimAfterReplay,
            waitsForIngestion: true
        )
    }

    /// Creates live output delivery at the mirror's current grid.
    /// - Parameters:
    ///   - bytes: Ordered PTY output bytes.
    ///   - waitForIngestion: Whether presentation must wait for Ghostty to finish parsing.
    /// - Returns: A chunk with no replay sizing operation.
    public static func output(
        bytes: Data,
        waitForIngestion: Bool = false
    ) -> CmuxTerminalChunk {
        CmuxTerminalChunk(
            bytes: bytes,
            replayGrid: nil,
            claimAfterReplay: false,
            waitsForIngestion: waitForIngestion
        )
    }

    /// The operations required to ingest this chunk without violating replay sizing order.
    public var ingestionSteps: [CmuxTerminalIngestionStep] {
        guard let replayGrid else {
            var steps: [CmuxTerminalIngestionStep] = [.receive(bytes)]
            if waitsForIngestion {
                steps.append(.awaitReceivedBytes)
            }
            return steps
        }

        var steps: [CmuxTerminalIngestionStep] = [
            .awaitCurrentBytes,
            .sizeForReplay(replayGrid),
            .receive(bytes),
            .awaitReceivedBytes,
            .fitToView,
        ]
        if claimAfterReplay {
            steps.append(.claimLocalGrid)
        }
        return steps
    }
}
