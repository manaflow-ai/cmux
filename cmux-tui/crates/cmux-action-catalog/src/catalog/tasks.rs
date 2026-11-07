// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `TasksActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "TasksActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "tasks.show",
        group: GROUP,
        title: t("TasksActions", "action.tasks.show", "Open Tasks"),
        keywords: &["tasks", "issues", "todo", "inbox", "board", "backlog", "agents"],
        category: "agents",
        symbol: "checklist",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "task open",
        ..Action::DEFAULT
    },
    Action {
        id: "tasks.new",
        group: GROUP,
        title: t("TasksActions", "action.tasks.new", "New Task"),
        keywords: &["tasks", "new", "create", "add", "issue", "todo"],
        category: "agents",
        symbol: "plus.circle",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action tasks-new",
        ..Action::DEFAULT
    },
    Action {
        id: "tasks.showMine",
        group: GROUP,
        title: t("TasksActions", "action.tasks.showMine", "My Tasks"),
        keywords: &["tasks", "mine", "assigned", "issues", "todo"],
        category: "agents",
        symbol: "person.crop.circle.badge.checkmark",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "task mine",
        ..Action::DEFAULT
    },
];
