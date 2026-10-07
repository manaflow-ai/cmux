import Foundation

/// The semantic voice of a toast; drives glyph, haptic and default dwell.
public enum ToastStyle: String, Sendable, CaseIterable {
    /// Ambient information ("Copied").
    case info
    case success
    /// Degraded but working.
    case warning
    case failure

    /// The default SF Symbol; nil for info (a quiet text capsule).
    public var systemImage: String? {
        switch self {
        case .info: nil
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
}
