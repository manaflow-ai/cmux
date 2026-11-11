// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `NotificationActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "NotificationActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    // The Feed page's native UI ops (feed-page.md 2): the page passes an item id; the item itself is read
    // from the daemon's feed client, never taken from the caller. Open Feed Item without an item does nothing (the Inbox page is gone).
    Action {
        id: "feed.openItem",
        group: GROUP,
        title: t("ActionCatalog", "action.feed.openItem", "Open Feed Item"),
        keywords: &["feed", "inbox", "open", "item"],
        category: "notifications",
        symbol: "arrow.up.forward.square",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("liveInput"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[args::FEED_ITEM.optional()],
        cli_name: "action feed-open-item",
        ..Action::DEFAULT
    },
    // Person-only: it types `gh pr review --approve` or a comment into a terminal, so only the person's own
    // click or key in the Feed page starts it, never page script.
    Action {
        id: "feed.githubAction",
        group: GROUP,
        title: t("ActionCatalog", "action.feed.githubAction", "Run a Feed Item's GitHub Action"),
        keywords: &["feed", "inbox", "github", "pull request", "review", "approve", "comment", "checkout"],
        category: "notifications",
        symbol: "arrow.triangle.pull",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("liveInput"), cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[args::FEED_ITEM, args::FEED_GITHUB_ACTION, args::FEED_COMMENT.optional()],
        cli_name: "action feed-github-action",
        is_person_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "showNotifications",
        group: GROUP,
        title: t("ActionCatalog", "action.showNotifications", "Show Notifications"),
        keywords: &["inbox", "alerts"],
        category: "notifications",
        symbol: "bell",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "notification show",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "agent.jumpToNextNeedingInput",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.jumpToNextNeedingInput", "Go to Next Agent Needing Input"),
        keywords: &["agent", "approval", "question", "needs input", "next"],
        category: "notifications",
        symbol: "exclamationmark.bubble",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        cli_name: "action agent-jump-to-next-needing-input",
        main_menu: Some("window"),
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "jumpToUnread",
        group: GROUP,
        title: t("ActionCatalog", "action.jumpToUnread", "Jump to Latest Unread"),
        keywords: &["notifications", "next"],
        default_shortcut: Some(Shortcut { key: "u", modifiers: SHIFT | CMD }),
        category: "notifications",
        symbol: "bell.badge",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        cli_name: "notification jump-to-latest-unread",
        main_menu: Some("window"),
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "attention.goTo",
        group: GROUP,
        title: t("ActionCatalog", "action.attention.goTo", "Go to What Needs Me"),
        keywords: &["needs you", "attention", "waiting", "agent", "action", "login", "approve", "tab"],
        category: "notifications",
        symbol: "hand.raised",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        cli_name: "action attention-go-to",
        main_menu: Some("window"),
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "jumpToLastPrompt",
        group: GROUP,
        title: t("ActionCatalog", "action.jumpToLastPrompt", "Jump to Last Prompt"),
        keywords: &["agent", "prompt", "submitted", "back"],
        default_shortcut: Some(Shortcut { key: "b", modifiers: CTRL | CMD }),
        category: "notifications",
        symbol: "arrow.uturn.backward.circle",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        cli_name: "action jump-to-last-prompt",
        main_menu: Some("window"),
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "toggleUnread",
        group: GROUP,
        title: t("ActionCatalog", "action.toggleUnread", "Mark Tab Read/Unread"),
        keywords: &["notifications", "read"],
        default_shortcut: Some(Shortcut { key: "u", modifiers: OPT | CMD }),
        category: "notifications",
        symbol: "envelope.badge",
        surfaces: PALETTE | KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menu_exemption: Some("liveInput"), ..SurfacePlan::DEFAULT },
        cli_name: "notification toggle-unread",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "markOldestUnreadAndJumpNext",
        group: GROUP,
        title: t("ActionCatalog", "action.markOldestUnreadAndJumpNext", "Mark Oldest Unread and Jump Next"),
        keywords: &["notifications", "triage"],
        default_shortcut: Some(Shortcut { key: "u", modifiers: CTRL | CMD }),
        category: "notifications",
        symbol: "bell.and.waves.left.and.right",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menu_exemption: Some("focusMove"), ..SurfacePlan::DEFAULT },
        cli_name: "notification mark-oldest-unread-and-jump-next",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "markAllNotificationsRead",
        group: GROUP,
        title: t("ActionCatalog", "action.markAllNotificationsRead", "Mark All Notifications as Read"),
        keywords: &["notifications", "read"],
        category: "notifications",
        symbol: "checkmark.circle",
        surfaces: KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "notification mark-all-as-read",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "clearAllNotifications",
        group: GROUP,
        title: t("ActionCatalog", "action.clearAllNotifications", "Clear All Notifications"),
        keywords: &["notifications", "dismiss"],
        category: "notifications",
        symbol: "bell.slash",
        surfaces: KEYBOARD | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "notification clear-all",
        main_menu: Some("window"),
        ..Action::DEFAULT
    },
    Action {
        id: "notificationOpen",
        group: GROUP,
        title: t("ActionCatalog", "action.notificationOpen", "Open Notification"),
        keywords: &["notifications"],
        category: "notifications",
        symbol: "bell.circle",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("focusMove")), context_menus: &[Placement::at("notification", "navigate", 0)], ..SurfacePlan::DEFAULT },
        cli_name: "notification open",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "notificationCopy",
        group: GROUP,
        title: t("ActionCatalog", "action.notificationCopy", "Copy Notification Text"),
        keywords: &["notifications", "clipboard"],
        category: "notifications",
        symbol: "doc.on.doc",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menus: &[Placement::at("notification", "inspect", 0)], ..SurfacePlan::DEFAULT },
        cli_name: "notification copy",
        ..Action::DEFAULT
    },
    Action {
        id: "notificationToggleRead",
        group: GROUP,
        title: t("ActionCatalog", "action.notificationToggleRead", "Mark Notification Read/Unread"),
        keywords: &["notifications"],
        category: "notifications",
        symbol: "envelope",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menus: &[Placement::at("notification", "identity", 0)], ..SurfacePlan::DEFAULT },
        cli_name: "notification mark-read-unread",
        ..Action::DEFAULT
    },
    Action {
        id: "notificationDismiss",
        group: GROUP,
        title: t("ActionCatalog", "action.notificationDismiss", "Dismiss Notification"),
        keywords: &["notifications"],
        category: "notifications",
        symbol: "xmark.circle",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("liveInput")), context_menus: &[Placement::at("notification", "close", 0)], ..SurfacePlan::DEFAULT },
        cli_name: "notification dismiss",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.toggleWorkspaceMute",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.toggleWorkspaceMute", "Mute/Unmute Workspace Notifications"),
        keywords: &["mute", "silence", "quiet", "notifications", "workspace"],
        category: "notifications",
        symbol: "bell.slash.circle",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "identity", 113).folder("options").label(t("Localizable", "menu.workspace.toggleNotificationMute", "Mute/Unmute Notifications"))], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "notification toggle-workspace-mute",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.dismissHighlight",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.dismissHighlight", "Dismiss Highlight"),
        keywords: &["highlight", "ring", "attention", "notifications", "workspace", "dismiss"],
        category: "notifications",
        symbol: "circle.dashed",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("workspaceRow", "identity", 111).folder("options")], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "action notifications-dismiss-highlight",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.toggleBanners",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.toggleBanners", "Notification Banners"),
        keywords: &["banner", "desktop", "system", "macos", "notifications"],
        category: "notifications",
        symbol: "rectangle.stack.badge.minus",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "notification toggle-banners",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.dismissal.keystroke",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.dismissal.keystroke", "Clear Notifications When Typing"),
        keywords: &["dismiss", "clear", "keystroke", "typing", "notifications"],
        category: "notifications",
        symbol: "keyboard",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "notification clear-when-typing",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.dismissal.focus",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.dismissal.focus", "Clear Notifications on Focus"),
        keywords: &["dismiss", "clear", "focus", "notifications"],
        category: "notifications",
        symbol: "scope",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "notification clear-on-focus",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.dismissal.click",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.dismissal.click", "Clear Notifications on Click"),
        keywords: &["dismiss", "clear", "click", "notifications"],
        category: "notifications",
        symbol: "cursorarrow.click",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "notification clear-on-click",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.dismissal.explicit",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.dismissal.explicit", "Clear Notifications Only When Opened"),
        keywords: &["dismiss", "clear", "open", "explicit", "notifications"],
        category: "notifications",
        symbol: "envelope.open",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "notification clear-when-opened",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.dismissal.timeout",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.dismissal.timeout", "Clear Notifications After a Timeout"),
        keywords: &["dismiss", "clear", "timeout", "timer", "notifications"],
        category: "notifications",
        symbol: "timer",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "notification clear-after-timeout",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.dismissal.never",
        group: GROUP,
        title: t("ActionCatalog", "action.notifications.dismissal.never", "Never Clear Notifications Automatically"),
        keywords: &["dismiss", "clear", "never", "manual", "notifications"],
        category: "notifications",
        symbol: "pin",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "notification never-clear-automatically",
        ..Action::DEFAULT
    },
];
