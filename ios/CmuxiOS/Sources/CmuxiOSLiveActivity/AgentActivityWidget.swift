public import SwiftUI
import WidgetKit
import ActivityKit
import CmuxFeedPushCore

/// The Live Activity widget for running agents: lock screen, banner and
/// Dynamic Island. The AgentActivityWidget extension's bundle lists it.
public struct AgentActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreenView(attributes: context.attributes, state: context.state)
                .widgetURL(context.attributes.link(for: context.state))
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.agent).lineLimit(1)
                    } icon: {
                        Image(systemName: context.state.phase.symbol).foregroundStyle(context.state.phase.tint)
                    }
                    .font(.subheadline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AgentActivityElapsed(state: context.state)
                        .font(.subheadline)
                        .frame(maxWidth: 72, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.subheadline).lineLimit(2)
                        Text(context.state.phase.label).font(.caption).foregroundStyle(context.state.phase.tint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol).foregroundStyle(context.state.phase.tint)
            } compactTrailing: {
                AgentActivityElapsed(state: context.state)
                    .frame(maxWidth: 52)
                    .font(.caption2)
            } minimal: {
                Image(systemName: context.state.phase.symbol).foregroundStyle(context.state.phase.tint)
            }
            .widgetURL(context.attributes.link(for: context.state))
            .keylineTint(context.state.phase.tint)
        }
    }
}
