public import CmuxFeedPushCore
public import UserNotifications

extension FeedPushCategory {
    /// The `UNNotificationCategory` the banner uses for this feed kind.
    public var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: rawValue, actions: actions.map(\.notificationAction),
                               intentIdentifiers: [], options: [])
    }

    /// Every category the app shows, registered once at launch: the feed
    /// kinds plus the Mac relay's terminal alerts (tap only).
    public static var notificationCategories: Set<UNNotificationCategory> {
        var categories = Set(allCases.map(\.notificationCategory))
        categories.insert(UNNotificationCategory(identifier: PushTerminalCategory.terminal, actions: [],
                                                 intentIdentifiers: [], options: []))
        return categories
    }
}

extension FeedPushAction {
    var notificationAction: UNNotificationAction {
        switch style {
        case .answer(let destructive, let requiresUnlock):
            var options: UNNotificationActionOptions = []
            if destructive { options.insert(.destructive) }
            if requiresUnlock { options.insert(.authenticationRequired) }
            return UNNotificationAction(identifier: rawValue, title: title, options: options)
        case .textInput:
            return UNTextInputNotificationAction(
                identifier: rawValue, title: title, options: [.authenticationRequired],
                textInputButtonTitle: String(localized: "push.reply.send", defaultValue: "Send", bundle: .module),
                textInputPlaceholder: placeholder)
        case .openApp:
            return UNNotificationAction(identifier: rawValue, title: title, options: [.foreground])
        }
    }

    private var placeholder: String {
        switch self {
        case .requestChanges: String(localized: "push.reply.changesPlaceholder", defaultValue: "What should change?", bundle: .module)
        default: String(localized: "push.reply.placeholder", defaultValue: "Answer", bundle: .module)
        }
    }

    var title: String {
        switch self {
        case .allow: String(localized: "push.action.allow", defaultValue: "Allow", bundle: .module)
        case .allowOnce: String(localized: "push.action.allowOnce", defaultValue: "Allow Once", bundle: .module)
        case .allowForSession: String(localized: "push.action.allowSession", defaultValue: "Allow for Session", bundle: .module)
        case .deny: String(localized: "push.action.deny", defaultValue: "Deny", bundle: .module)
        case .confirm: String(localized: "push.action.confirm", defaultValue: "Confirm", bundle: .module)
        case .cancel: String(localized: "push.action.cancel", defaultValue: "Cancel", bundle: .module)
        case .reply: String(localized: "push.action.reply", defaultValue: "Reply", bundle: .module)
        case .approvePlan: String(localized: "push.action.approvePlan", defaultValue: "Approve", bundle: .module)
        case .requestChanges: String(localized: "push.action.requestChanges", defaultValue: "Request Changes", bundle: .module)
        case .markRead: String(localized: "push.action.markRead", defaultValue: "Mark Read", bundle: .module)
        case .openOnMac: String(localized: "push.action.openOnMac", defaultValue: "Open on Mac", bundle: .module)
        }
    }
}
