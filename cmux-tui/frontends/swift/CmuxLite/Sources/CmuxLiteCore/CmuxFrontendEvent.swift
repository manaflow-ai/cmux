import Foundation

/// A state or terminal update produced by ``CmuxFrontendSession``.
public enum CmuxFrontendEvent: Sendable, Equatable {
    /// A refreshed immutable workspace/navigation snapshot.
    case snapshot(CmuxFrontendStartup)

    /// An ordered event for the one currently attached surface.
    case terminal(CmuxAttachEvent)
}
