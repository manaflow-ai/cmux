import Foundation

/// The resize operation selected for a laid-out terminal container.
public enum CmuxResizeAction: Sendable, Equatable {
    /// The measured state does not require a protocol resize.
    case none

    /// The measured grid should be sent after debounce.
    case resize(CmuxSurfaceSize)
}
