import UserNotifications

enum NotificationCategories {
    static let surfaceCategory = "CMUX_SURFACE"
    static let stuckCategory = "CMUX_STUCK"
    static let openAction = "CMUX_OPEN"
    static let markReadAction = "CMUX_MARK_READ"
    static let dismissAction = "CMUX_DISMISS"
    static let replyAction = "CMUX_REPLY"
    static let snoozeAction = "CMUX_SNOOZE"
    static let killAction = "CMUX_KILL"

    static func installAll() {
        let open = UNNotificationAction(
            identifier: openAction,
            title: L10n.string("notification.action.open_in_cmux", defaultValue: "Open in cmux"),
            options: [.foreground]
        )
        let markRead = UNNotificationAction(
            identifier: markReadAction,
            title: L10n.string("notification.action.mark_read", defaultValue: "Mark read"),
            options: [.authenticationRequired]
        )
        let dismiss = UNNotificationAction(
            identifier: dismissAction,
            title: L10n.string("notification.action.dismiss", defaultValue: "Dismiss"),
            options: [.destructive, .authenticationRequired]
        )
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: L10n.string("notification.action.reply", defaultValue: "Reply"),
            options: [.authenticationRequired],
            textInputButtonTitle: L10n.string("common.send", defaultValue: "Send"),
            textInputPlaceholder: L10n.string("notification.reply.placeholder", defaultValue: "Reply text...")
        )
        let category = UNNotificationCategory(
            identifier: surfaceCategory,
            actions: [open, reply, markRead, dismiss],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: L10n.string("notifications.agent_waiting", defaultValue: "Agent is waiting"),
            options: [.customDismissAction]
        )

        let snooze = UNNotificationAction(
            identifier: snoozeAction,
            title: L10n.string("notification.action.snooze", defaultValue: "Snooze"),
            options: [.authenticationRequired]
        )
        let kill = UNNotificationAction(
            identifier: killAction,
            title: L10n.string("notification.action.send_ctrl_c", defaultValue: "Send Ctrl-C"),
            options: [.destructive, .authenticationRequired]
        )
        let stuckCategoryDef = UNNotificationCategory(
            identifier: stuckCategory,
            actions: [open, snooze, kill],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: L10n.string(
                "notification.stuck.hidden_preview",
                defaultValue: "Agent appears stuck"
            ),
            options: [.customDismissAction]
        )

        // Merge with any existing categories (e.g. agent-decision
        // templates registered before a kill) so we don't blow them
        // away on relaunch — that would leave undelivered Lock Screen
        // notifications without their action buttons.
        Task {
            let existing = await UNUserNotificationCenter.current().notificationCategories()
            let next: Set<UNNotificationCategory> = existing
                .union([category, stuckCategoryDef])
            UNUserNotificationCenter.current().setNotificationCategories(next)
        }
    }
}
