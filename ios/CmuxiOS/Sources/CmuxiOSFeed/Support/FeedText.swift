import CmuxiOSFeatureKit
import CmuxiOSFeedModel
import Foundation

/// Every user-facing string of the Feed tab (en and ja in the catalog).
enum FeedText {
    static func l(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { l("feed.title", "Feed") }

    // Filters and grouping
    static func filter(_ filter: FeedFilter) -> String {
        switch filter {
        case .needsInput: l("feed.filter.needsInput", "Needs Input")
        case .unread: l("feed.filter.unread", "Unread")
        case .all: l("feed.filter.all", "All")
        }
    }
    static var groupBy: String { l("feed.menu.groupBy", "Group By") }
    static func grouping(_ grouping: FeedGrouping) -> String {
        switch grouping {
        case .none: l("feed.grouping.none", "None")
        case .workspace: l("feed.grouping.workspace", "Workspace")
        case .agent: l("feed.grouping.agent", "Agent")
        }
    }
    static var markAllRead: String { l("feed.menu.markAllRead", "Mark All as Read") }
    static var moreMenu: String { l("feed.menu.more", "Feed Options") }

    // Sections
    static func section(_ kind: FeedSectionKind) -> String {
        switch kind {
        case .needsInput: return l("feed.section.needsInput", "Needs Input")
        case .earlier: return l("feed.section.earlier", "Earlier")
        case .workspace(_, let label): return label ?? l("feed.section.noWorkspace", "No Workspace")
        case .agent(let agent): return agent.map(agentName) ?? l("feed.section.otherPosters", "Other")
        }
    }

    /// Display name of a harness id. Product names stay as they are.
    static func agentName(_ id: String) -> String {
        switch id.lowercased() {
        case "claude", "claude-code": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    // Permission
    static var allow: String { l("feed.permission.allow", "Allow") }
    static var deny: String { l("feed.permission.deny", "Deny") }
    static var allowOptions: String { l("feed.permission.allowOptions", "Allow Options") }
    static func allowScope(_ scope: FeedPermissionScope) -> String {
        switch scope {
        case .once: l("feed.permission.scope.once", "Allow Once")
        case .session: l("feed.permission.scope.session", "Allow for This Session")
        case .always: l("feed.permission.scope.always", "Always Allow")
        }
    }
    static func actionType(_ type: FeedPermission.ActionType) -> String {
        switch type {
        case .command: l("feed.permission.type.command", "Run a command")
        case .edit: l("feed.permission.type.edit", "Edit files")
        case .tool: l("feed.permission.type.tool", "Use a tool")
        case .network: l("feed.permission.type.network", "Access the network")
        case .install: l("feed.permission.type.install", "Install software")
        case .custom: l("feed.permission.type.custom", "Permission")
        }
    }

    // Question and choice
    static var reply: String { l("feed.question.reply", "Reply") }
    static var replyPlaceholder: String { l("feed.question.placeholder", "Your answer") }
    static var other: String { l("feed.choice.other", "Other") }
    static var otherPlaceholder: String { l("feed.choice.otherPlaceholder", "Your own answer") }
    static var submit: String { l("feed.choice.submit", "Submit") }
    static var multiSelect: String { l("feed.choice.multi", "Choose any") }
    static var selected: String { l("feed.choice.selected", "Selected") }

    // Plan
    static var approvePlan: String { l("feed.plan.approve", "Approve") }
    static var requestChanges: String { l("feed.plan.requestChanges", "Request Changes") }
    static var changesPlaceholder: String { l("feed.plan.changesPlaceholder", "What should change?") }

    // Confirm
    static var confirm: String { l("feed.confirm.confirm", "Confirm") }
    static var cancel: String { l("feed.confirm.cancel", "Cancel") }

    // Mac-only kinds
    static var answerOnMac: String { l("feed.unsupported.answerOnMac", "Answer on your Mac.") }
    static var openOnMac: String { l("feed.unsupported.openElsewhere", "This request can't be answered here yet.") }

    // Composer
    static var send: String { l("feed.composer.send", "Send") }
    static var composerCancel: String { l("feed.composer.cancel", "Cancel") }

    // Item actions
    static var markRead: String { l("feed.action.markRead", "Mark as Read") }
    static var archive: String { l("feed.action.archive", "Archive") }
    static var decline: String { l("feed.action.decline", "Decline") }
    static var sending: String { l("feed.status.sending", "Sending") }
    static var unread: String { l("feed.status.unread", "Unread") }

    // Resolutions
    static func resolution(_ item: FeedItem) -> String? {
        switch item.state {
        case .open: return nil
        case .expired: return l("feed.resolution.expired", "Expired")
        case .cancelled:
            switch item.cancelReason {
            case .declined: return l("feed.resolution.declined", "Declined")
            case .answeredElsewhere: return l("feed.resolution.answeredElsewhere", "Answered in the terminal")
            case .posterGone: return l("feed.resolution.posterGone", "The agent stopped")
            default: return l("feed.resolution.cancelled", "Withdrawn")
            }
        case .answered:
            let label = item.answer?.reply.map(replyLabel) ?? l("feed.resolution.answered", "Answered")
            guard let device = item.answer?.device, !device.isEmpty else { return label }
            return String(format: l("feed.resolution.onDevice", "%1$@ on %2$@"), label, device)
        }
    }

    static func replyLabel(_ reply: FeedReply) -> String {
        switch reply {
        case .permission(let allow, let scope):
            guard allow else { return l("feed.resolution.denied", "Denied") }
            switch scope {
            case .session: return l("feed.resolution.allowedSession", "Allowed for this session")
            case .always: return l("feed.resolution.allowedAlways", "Always allowed")
            case .once, nil: return l("feed.resolution.allowedOnce", "Allowed once")
            }
        case .text(let text):
            return String(format: l("feed.resolution.answeredWith", "Answered: %@"), text)
        case .choice:
            return l("feed.resolution.answered", "Answered")
        case .plan(let approved, _):
            return approved ? l("feed.resolution.planApproved", "Plan approved") : l("feed.resolution.changesRequested", "Changes requested")
        case .confirm(let confirmed):
            return confirmed ? l("feed.resolution.confirmed", "Confirmed") : l("feed.resolution.notConfirmed", "Not confirmed")
        }
    }

    // Outcomes
    static func outcome(_ outcome: FeedIntentOutcome) -> String? {
        switch outcome {
        case .committed: return nil
        case .refused(_, _, let closedElsewhere):
            return closedElsewhere
                ? l("feed.outcome.closedElsewhere", "Already answered on another device.")
                : l("feed.outcome.refused", "Not accepted. The request may have changed.")
        case .notSent(_, let offline):
            return offline
                ? l("feed.outcome.offline", "Not sent. You're offline.")
                : l("feed.outcome.unconfirmed", "Couldn't confirm. Check the feed when it reconnects.")
        }
    }

    // Connection and empty states
    static var offlineBanner: String { l("feed.offline.banner", "Offline. Answers are paused until the feed reconnects.") }
    static var connectingBanner: String { l("feed.connecting.banner", "Connecting") }
    static var offlineTitle: String { l("feed.offline.title", "Feed Offline") }
    static var offlineBody: String { l("feed.offline.body", "Requests from your agents show here when the feed reconnects.") }
    static func emptyTitle(_ filter: FeedFilter) -> String {
        switch filter {
        case .needsInput: l("feed.empty.needsInput.title", "Nothing Needs You")
        case .unread: l("feed.empty.unread.title", "All Caught Up")
        case .all: l("feed.empty.all.title", "No Activity Yet")
        }
    }
    static func emptyBody(_ filter: FeedFilter) -> String {
        switch filter {
        case .needsInput: l("feed.empty.needsInput.body", "Permission requests, questions and plans from your agents appear here.")
        case .unread: l("feed.empty.unread.body", "You've read everything in your feed.")
        case .all: l("feed.empty.all.body", "When your agents ask for something or finish a task, it shows here.")
        }
    }
    static var showAll: String { l("feed.empty.showAll", "Show All") }
    static var mockData: String { l("feed.mockData", "Mock data") }

    // Accessibility
    static var openRequest: String { l("feed.a11y.openRequest", "Needs input") }
}
