public import CmuxFeedPushCore
public import SwiftUI

extension AgentActivityPhase {
    /// The phase as one short word.
    public var label: String {
        switch self {
        case .running: String(localized: "activity.phase.running", defaultValue: "Running", bundle: .module)
        case .needsInput: String(localized: "activity.phase.needsInput", defaultValue: "Needs input", bundle: .module)
        case .done: String(localized: "activity.phase.done", defaultValue: "Done", bundle: .module)
        case .failed: String(localized: "activity.phase.failed", defaultValue: "Failed", bundle: .module)
        }
    }

    public var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .needsInput: "exclamationmark.bubble.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .running: .accentColor
        case .needsInput: .orange
        case .done: .green
        case .failed: .red
        }
    }
}
