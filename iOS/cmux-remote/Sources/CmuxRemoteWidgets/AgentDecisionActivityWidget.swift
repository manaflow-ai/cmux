import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents
import CmuxKit

/// Live-Activity widget for a single pending agent decision. Renders one
/// `Button(_:intent:)` per choice — `ResolveDecisionIntent` is a
/// `LiveActivityIntent` so taps run in the main app process and resolve the
/// decision back through cmux without launching the foreground app.
struct AgentDecisionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentDecisionActivityAttributes.self) { context in
            DecisionLockScreen(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.agentName, systemImage: "questionmark.bubble.fill")
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.resolved {
                        Label(WidgetL10n.string("agent_decision.resolved", defaultValue: "Resolved"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "hand.tap.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.summary)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.resolved {
                        DecisionButtonRow(context: context)
                    }
                }
            } compactLeading: {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.yellow)
            } compactTrailing: {
                Text(context.attributes.agentName.prefix(8))
                    .lineLimit(1)
                    .font(.caption2)
            } minimal: {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.yellow)
            }
        }
    }
}

private struct DecisionLockScreen: View {
    let context: ActivityViewContext<AgentDecisionActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.agentName, systemImage: "terminal")
                    .font(.headline)
                Spacer()
                if context.state.resolved {
                    Label(WidgetL10n.string("agent_decision.resolved", defaultValue: "Resolved"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            Text(context.state.summary).font(.subheadline)
            if let detail = context.state.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if !context.state.resolved {
                DecisionButtonRow(context: context)
            }
        }
        .padding(14)
    }
}

private struct DecisionButtonRow: View {
    let context: ActivityViewContext<AgentDecisionActivityAttributes>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(context.state.choices, id: \.id) { choice in
                Button(
                    intent: ResolveDecisionIntent(
                        decisionID: context.attributes.decisionID,
                        itemID: context.attributes.itemID,
                        decisionKind: context.attributes.decisionKind,
                        choiceID: choice.id,
                        choiceLabel: choice.replyLabel,
                        questionSelectionsJSON: questionSelectionsJSON(choice.questionSelections),
                        agentName: context.attributes.agentName,
                        hostID: context.attributes.hostID,
                        workspaceID: context.attributes.workspaceID,
                        requiresAuth: choice.requiresAuth,
                        isDestructive: choice.isDestructive
                    )
                ) {
                    Text(choice.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(buttonTint(for: choice))
            }
        }
    }

    private func buttonTint(for choice: AgentDecisionActivityAttributes.Choice) -> Color {
        if choice.isDestructive { return .red }
        if choice.isAffirmative { return .green }
        return .accentColor
    }

    private func questionSelectionsJSON(_ selections: [AgentDecision.QuestionSelection]?) -> String? {
        guard let selections, !selections.isEmpty,
              let data = try? JSONEncoder().encode(selections) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
