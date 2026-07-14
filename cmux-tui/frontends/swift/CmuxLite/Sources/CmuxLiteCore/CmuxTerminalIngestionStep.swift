import Foundation

/// One ordered operation needed to deliver terminal bytes to a Ghostty mirror.
public enum CmuxTerminalIngestionStep: Sendable, Equatable {
    /// Wait for previously delivered live output to finish parsing before changing grids.
    case awaitCurrentBytes

    /// Size the mirror to an authoritative replay grid before delivering its bytes.
    case sizeForReplay(CmuxSurfaceSize)

    /// Deliver one ordered byte chunk to the mirror.
    case receive(Data)

    /// Wait until Ghostty has parsed the bytes delivered by the preceding step.
    case awaitReceivedBytes

    /// Reconcile Ghostty with the current view after replay delivery.
    case fitToView

    /// Claim the local pane grid after the initial replay has been delivered.
    case claimLocalGrid
}
