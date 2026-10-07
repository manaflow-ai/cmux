import CmuxFeedPushCore
import SwiftUI

/// The elapsed time since the agent started, counting while it runs or
/// waits. A final phase has no end time in its state, so it shows the phase.
struct AgentActivityElapsed: View {
    let state: AgentActivityState

    var body: some View {
        if state.phase.isFinal {
            Text(state.phase.label)
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        }
    }
}
