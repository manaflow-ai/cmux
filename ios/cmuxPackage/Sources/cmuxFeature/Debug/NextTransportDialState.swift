#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import Observation
import OSLog
import Security

/// Typed session state for the dial surface. `state` (the display string)
/// is derived from this; the facade's fallback decisions consume the typed
/// value, never the string.
public enum NextTransportDialState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case degraded
    /// Session ended. `denial` is non-nil exactly when the close code was a
    /// real admission denial (`DenialCode`), nil for transport-level ends
    /// (timeouts, network loss, local closes).
    case closed(code: String, denial: DenialCode?)

    /// Short display string for the dev screen and log lines.
    public var displayDescription: String {
        switch self {
        case .idle:
            return String(localized: "nextTransport.dev.state.idle", defaultValue: "idle")
        case .connecting:
            return String(localized: "nextTransport.dev.state.connecting", defaultValue: "connecting")
        case .ready:
            return String(localized: "nextTransport.dev.state.ready", defaultValue: "ready")
        case .degraded:
            return String(localized: "nextTransport.dev.state.degraded", defaultValue: "degraded")
        case .closed(let code, _):
            return String(
                format: String(localized: "nextTransport.dev.state.closed", defaultValue: "closed (%@)"),
                code)
        }
    }
}
#endif
