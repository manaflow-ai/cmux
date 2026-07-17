import Foundation

/// A resolved keyboard ratio adjustment ready for `set-ratio`.
public struct CmuxRatioNudge: Sendable, Equatable {
    /// The split addressed by the adjustment.
    public let target: CmuxSplitTarget

    /// The next clamped ratio.
    public let ratio: Double

    /// Creates a resolved ratio adjustment.
    /// - Parameters:
    ///   - target: The split to update.
    ///   - ratio: The clamped replacement ratio.
    public init(target: CmuxSplitTarget, ratio: Double) {
        self.target = target
        self.ratio = ratio
    }
}
