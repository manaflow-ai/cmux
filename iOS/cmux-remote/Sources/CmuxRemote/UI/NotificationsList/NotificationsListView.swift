import SwiftUI
import CmuxKit

struct NotificationsListView: View {
    @EnvironmentObject var connection: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            List {
                let sorted = connection.snapshot.notifications.values
                    .sorted(by: { $0.createdAt > $1.createdAt })
                if sorted.isEmpty {
                    ContentUnavailableView(
                        L10n.string("notifications.empty.title", defaultValue: "No notifications"),
                        systemImage: "bell.slash",
                        description: Text(L10n.string(
                            "notifications.empty.description",
                            defaultValue: "Agents will appear here when they need attention."
                        ))
                    )
                }
                ForEach(sorted, id: \.id) { notification in
                    NotificationRow(notification: notification)
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task {
                                    guard let client = await connection.client(for: "open") else { return }
                                    do {
                                        try await client.openNotification(notification.id)
                                        dismiss()
                                    } catch {
                                        actionError = L10n.string(
                                            "notifications.error.action_failed",
                                            defaultValue: "Could not complete the notification action."
                                        )
                                    }
                                }
                            } label: { Label(L10n.string("notifications.action.open", defaultValue: "Open"), systemImage: "arrow.up.right.square") }
                            Button(role: .destructive) {
                                Task {
                                    guard let client = await connection.client(for: "dismiss") else { return }
                                    try? await client.dismiss(notificationID: notification.id)
                                }
                            } label: { Label(L10n.string("notifications.action.dismiss", defaultValue: "Dismiss"), systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task {
                                    guard let client = await connection.client(for: "mark-read") else { return }
                                    try? await client.markRead(notificationID: notification.id)
                                }
                            } label: { Label(L10n.string("notifications.action.read", defaultValue: "Read"), systemImage: "checkmark") }
                            .tint(.green)
                        }
                }
            }
            .navigationTitle(L10n.string("notifications.title", defaultValue: "Notifications"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(L10n.string("notifications.action.jump_to_unread", defaultValue: "Jump to unread")) {
                        Task {
                            guard let client = await connection.client(for: "jump-to-unread") else { return }
                            do {
                                try await client.jumpToUnread()
                                dismiss()
                            } catch {
                                actionError = L10n.string(
                                    "notifications.error.action_failed",
                                    defaultValue: "Could not complete the notification action."
                                )
                            }
                        }
                    }
                    Menu {
                        Button(L10n.string("notifications.action.mark_all_read", defaultValue: "Mark all read"), systemImage: "checkmark.circle") {
                            Task {
                                guard let client = await connection.client(for: "mark-all-read") else { return }
                                try? await client.markAllRead()
                            }
                        }
                        Button(L10n.string("notifications.action.clear_read", defaultValue: "Clear read"), systemImage: "trash") {
                            Task {
                                guard let client = await connection.client(for: "clear-read") else { return }
                                try? await client.clearReadNotifications()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("common.done", defaultValue: "Done")) { dismiss() }
                }
            }
            .alert(
                L10n.string("notifications.error.title", defaultValue: "Notification action failed"),
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                )
            ) {
                Button(L10n.string("common.ok", defaultValue: "OK"), role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }
}

private struct NotificationRow: View {
    let notification: CmuxNotification

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(notification.isRead ? Color.gray.opacity(0.3) : Color.blue)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title ?? notification.tabTitle ?? L10n.string("app.short_name", defaultValue: "cmux"))
                    .font(.headline)
                if let subtitle = notification.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if let body = notification.body {
                    Text(body).font(.body).foregroundStyle(.primary).lineLimit(3)
                }
                Text(notification.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
