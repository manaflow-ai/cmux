import CmuxFeedPushCore
import SwiftUI
import WidgetKit

/// The lock screen and banner presentation: agent, phase, elapsed time, and
/// in needs-input the request that waits.
struct AgentActivityLockScreenView: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.phase.symbol)
                .font(.title2)
                .foregroundStyle(state.phase.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(attributes.agent).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    AgentActivityElapsed(state: state)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(state.title)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(state.phase.label).foregroundStyle(state.phase.tint)
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Text(attributes.place).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.caption)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}
