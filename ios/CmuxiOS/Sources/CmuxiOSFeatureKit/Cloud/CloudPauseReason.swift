import Foundation

/// Why cmux paused a machine by itself (absent after a person's pause or a start).
public enum CloudPauseReason: String, Hashable, Sendable {
    /// Its reports showed it idle past its idle policy.
    case idle
    /// No report from the VM for 24 h after its last start or bind (cost backstop).
    case noReport = "no_report"
    case providerStopped = "provider_stopped"
    case providerPaused = "provider_paused"
}
