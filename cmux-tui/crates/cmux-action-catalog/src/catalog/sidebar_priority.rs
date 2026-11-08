// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `SidebarPriorityActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "SidebarPriorityActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "sidebar.priorityView.toggle",
        group: GROUP,
        title: t("SidebarSectionActions", "action.sidebar.priorityView.toggle", "Toggle Priority View"),
        keywords: &["sidebar", "priority", "activity", "attention", "agents", "chats", "needs you", "bell"],
        default_shortcut: Some(Shortcut { key: "k", modifiers: OPT | CMD }),
        category: "sidebar",
        symbol: "bell",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        cli_name: "action sidebar-priority-view-toggle",
        ..Action::DEFAULT
    },
    Action {
        id: "sidebar.priority.markRead",
        group: GROUP,
        title: t("SidebarSectionActions", "action.sidebar.priority.markRead", "Mark Chat as Read…"),
        keywords: &["sidebar", "priority", "chat", "agent", "read", "seen", "done", "clear"],
        category: "sidebar",
        symbol: "checkmark.circle",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("priorityRow", "identity", 0).label(t("SidebarSectionActions", "menu.sidebar.priority.markRead", "Mark as Read"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::CHAT],
        targets: &["agent-chat"],
        cli_name: "action sidebar-priority-mark-read",
        ..Action::DEFAULT
    },
    Action {
        id: "sidebar.priority.togglePin",
        group: GROUP,
        title: t("SidebarSectionActions", "action.sidebar.priority.togglePin", "Pin/Unpin Chat in Priority…"),
        keywords: &["sidebar", "priority", "chat", "agent", "pin", "unpin", "keep", "top"],
        category: "sidebar",
        symbol: "pin",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("priorityRow", "identity", 10)], ..SurfacePlan::DEFAULT },
        arguments: &[args::CHAT],
        targets: &["agent-chat"],
        cli_name: "action sidebar-priority-toggle-pin",
        ..Action::DEFAULT
    },
    Action {
        id: "sidebar.priority.snooze",
        group: GROUP,
        title: t("SidebarSectionActions", "action.sidebar.priority.snooze", "Snooze Chat for 1 Hour…"),
        keywords: &["sidebar", "priority", "chat", "agent", "snooze", "later", "hide", "mute"],
        category: "sidebar",
        symbol: "moon.zzz",
        surfaces: PALETTE | KEYBOARD | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("priorityRow", "identity", 20).label(t("SidebarSectionActions", "menu.sidebar.priority.snooze", "Snooze for 1 Hour"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::CHAT],
        targets: &["agent-chat"],
        cli_name: "action sidebar-priority-snooze",
        ..Action::DEFAULT
    },
    Action {
        id: "sidebar.priority.moveEarlier",
        group: GROUP,
        title: t("SidebarSectionActions", "action.sidebar.priority.moveEarlier", "Move Chat Earlier in Priority…"),
        keywords: &["sidebar", "priority", "chat", "agent", "move", "earlier", "up", "reorder"],
        category: "sidebar",
        symbol: "arrow.up",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("stepAdjust"), ..SurfacePlan::DEFAULT },
        arguments: &[args::CHAT],
        targets: &["agent-chat"],
        cli_name: "action sidebar-priority-move-earlier",
        ..Action::DEFAULT
    },
    Action {
        id: "sidebar.priority.moveLater",
        group: GROUP,
        title: t("SidebarSectionActions", "action.sidebar.priority.moveLater", "Move Chat Later in Priority…"),
        keywords: &["sidebar", "priority", "chat", "agent", "move", "later", "down", "reorder"],
        category: "sidebar",
        symbol: "arrow.down",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("stepAdjust"), ..SurfacePlan::DEFAULT },
        arguments: &[args::CHAT],
        targets: &["agent-chat"],
        cli_name: "action sidebar-priority-move-later",
        ..Action::DEFAULT
    },
];
