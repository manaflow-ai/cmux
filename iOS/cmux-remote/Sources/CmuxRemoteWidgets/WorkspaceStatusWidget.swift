public import WidgetKit
import SwiftUI
import AppIntents
public import CmuxKit

extension CmuxWidgetEntry: @retroactive TimelineEntry {}

/// Home Screen widget that surfaces the most-recent unread workspace.
///
/// Data is read from an App Group plist that the main app keeps up to date
/// on every snapshot. The widget itself never opens an SSH session.
struct WorkspaceStatusWidget: Widget {
    let kind = "WorkspaceStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            WorkspaceStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("cmux Workspace")
        .description("Latest unread workspace and pending count.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> CmuxWidgetEntry {
            CmuxWidgetEntry(
                date: .now,
                workspaceTitle: WidgetL10n.string("live_activity.workspace.generic", defaultValue: "cmux workspace"),
                branch: nil,
                unread: 3,
                host: WidgetL10n.string("widget.host.generic", defaultValue: "cmux")
            )
        }
        func getSnapshot(in context: Context, completion: @escaping (CmuxWidgetEntry) -> Void) {
            completion(WidgetState.load() ?? placeholder(in: context))
        }
        func getTimeline(in context: Context, completion: @escaping (Timeline<CmuxWidgetEntry>) -> Void) {
            let entry = WidgetState.load() ?? placeholder(in: context)
            let next = Date().addingTimeInterval(60 * 15)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct WorkspaceStatusView: View {
    let entry: CmuxWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                Circle().stroke(.tint, lineWidth: 3)
                if entry.unread > 0 {
                    Text("\(entry.unread)").font(.system(.title3, design: .rounded, weight: .bold))
                } else {
                    Image(systemName: "terminal")
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label(entry.workspaceTitle, systemImage: "terminal").font(.headline)
                if entry.unread > 0 {
                    Label(
                        WidgetL10n.format(
                            "widget.pending_count",
                            defaultValue: "%lld waiting",
                            Int64(entry.unread)
                        ),
                        systemImage: "bell.badge"
                    )
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label(entry.workspaceTitle, systemImage: "terminal")
                    .font(.headline)
                if let branch = entry.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if entry.unread > 0 {
                    Label(
                        WidgetL10n.format(
                            "widget.pending_count",
                            defaultValue: "%lld waiting",
                            Int64(entry.unread)
                        ),
                        systemImage: "bell.badge.fill"
                    )
                        .foregroundStyle(.red)
                        .font(.subheadline.bold())
                } else {
                    Text(entry.host).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct NotificationCountWidget: Widget {
    let kind = "NotificationCountWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorkspaceStatusWidget.Provider()) { entry in
            VStack {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(entry.unread > 0 ? .red : .secondary)
                Text("\(entry.unread)")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text(WidgetL10n.string("widget.waiting", defaultValue: "waiting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("cmux Pending")
        .description("How many agents need your attention.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
