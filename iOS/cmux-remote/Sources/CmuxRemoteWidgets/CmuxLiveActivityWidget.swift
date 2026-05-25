import ActivityKit
import WidgetKit
import SwiftUI
import CmuxKit

struct CmuxLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CMUXActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.workspaceTitle, systemImage: "terminal")
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.pendingCount > 0 {
                        Label("\(context.state.pendingCount)", systemImage: "bell.badge")
                            .foregroundStyle(.red)
                            .monospacedDigit()
                    } else {
                        Label(context.state.phaseLabel, systemImage: context.state.isLive ? "circle.fill" : "circle.dotted")
                            .foregroundStyle(context.state.isLive ? .green : .secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let branch = context.state.workspaceBranch {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let body = context.state.lastNotificationBody {
                            Text(body).font(.caption).lineLimit(1).foregroundStyle(.primary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "terminal")
            } compactTrailing: {
                if context.state.pendingCount > 0 {
                    Text("\(context.state.pendingCount)").monospacedDigit().foregroundStyle(.red)
                } else {
                    Circle().fill(context.state.isLive ? Color.green : Color.gray).frame(width: 6, height: 6)
                }
            } minimal: {
                if context.state.pendingCount > 0 {
                    Image(systemName: "bell.badge.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: "terminal")
                }
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<CMUXActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(context.state.workspaceTitle, systemImage: "terminal")
                    .font(.headline)
                    .lineLimit(1)
                if let branch = context.state.workspaceBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let body = context.state.lastNotificationBody {
                    Text(body).font(.body).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing) {
                Text(context.attributes.hostLabel).font(.caption).foregroundStyle(.secondary)
                if context.state.pendingCount > 0 {
                    Label(
                        WidgetL10n.format(
                            "live_activity.pending_count",
                            defaultValue: "%lld waiting",
                            Int64(context.state.pendingCount)
                        ),
                        systemImage: "bell.badge.fill"
                    )
                        .foregroundStyle(.red)
                        .font(.subheadline.bold())
                } else {
                    Label(context.state.phaseLabel, systemImage: context.state.isLive ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(context.state.isLive ? .green : .secondary)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
