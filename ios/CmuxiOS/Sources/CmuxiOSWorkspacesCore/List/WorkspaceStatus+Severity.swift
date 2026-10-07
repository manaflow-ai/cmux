public import CmuxiOSFeatureKit

extension WorkspaceStatus {
    /// Stacking order for roll-ups (status-indicators.md section 3):
    /// failed > waiting for input > running > idle.
    public var severity: Int {
        switch self {
        case .failed: 3
        case .waitingForInput: 2
        case .running: 1
        case .idle: 0
        }
    }

    /// The tab status of the wire (`idle | running | needs_input | error`);
    /// an unknown or absent value is idle.
    init(wire: String?) {
        switch wire {
        case "running": self = .running
        case "needs_input": self = .waitingForInput
        case "error": self = .failed
        default: self = .idle
        }
    }
}
