import Foundation

/// Reports a scrollback-count reconciliation and whether cached indexes were invalidated.
public struct CmuxScrollbackReconciliation: Sendable, Equatable {
    /// The reconciled bounded window.
    public let window: CmuxScrollbackWindow

    /// Whether resize or shrink invalidated every cached absolute index.
    public let invalidated: Bool

    /// Creates a reconciliation result.
    public init(window: CmuxScrollbackWindow, invalidated: Bool) {
        self.window = window
        self.invalidated = invalidated
    }
}
