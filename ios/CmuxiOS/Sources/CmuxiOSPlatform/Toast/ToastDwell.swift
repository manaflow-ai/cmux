import Foundation

/// How long a toast stays before it dismisses itself.
public enum ToastDwell: Hashable, Sendable {
    case after(Duration)
    /// Until the user or the code dismisses it; only for states the user
    /// must acknowledge.
    case never

    /// Quiet confirmations leave quickly; problems and actionable toasts
    /// stay long enough to read and act on.
    public static func standard(for style: ToastStyle, hasAction: Bool) -> ToastDwell {
        if hasAction { return .after(.seconds(6)) }
        switch style {
        case .info, .success: return .after(.milliseconds(3_500))
        case .warning, .failure: return .after(.seconds(6))
        }
    }
}
