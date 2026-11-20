// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AutoArchiveActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "AutoArchiveActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "workspace.archiveIdle",
        group: GROUP,
        title: t("WorkspaceActions", "action.autoArchive.archiveIdle", "Archive Idle Workspaces"),
        keywords: &["archive", "idle", "old", "stale", "tidy", "clean up", "declutter", "workspaces", "sweep"],
        category: "workspace",
        symbol: "archivebox",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("sidebarBackground", "organize", 105).folder("group")], ..SurfacePlan::DEFAULT },
        cli_name: "workspace archive-idle",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.restoreArchived",
        group: GROUP,
        title: t("WorkspaceActions", "action.autoArchive.restoreArchived", "Restore Archived Workspace…"),
        keywords: &["archive", "archived", "restore", "unarchive", "find", "search", "workspaces", "show archived"],
        category: "workspace",
        symbol: "archivebox.circle",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("sidebarBackground", "organize", 106).folder("group")], ..SurfacePlan::DEFAULT },
        arguments: &[args::ITEM_2],
        cli_name: "workspace restore-archived",
        ..Action::DEFAULT
    },
    Action {
        id: "workspaceGroup.setAutoArchive",
        group: GROUP,
        title: t("WorkspaceActions", "action.autoArchive.setGroupRule", "Auto-Archive Group Workspaces"),
        keywords: &["group", "archive", "auto archive", "idle", "rule", "never", "days"],
        category: "workspace",
        symbol: "archivebox",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceGroup", "identity", 109).style("choices").folder("options")], ..SurfacePlan::DEFAULT },
        arguments: &[args::AFTER],
        targets: &["workspace-group"],
        cli_name: "workspace-group set-auto-archive",
        ..Action::DEFAULT
    },
    Action {
        id: "debug.autoArchive.age",
        group: GROUP,
        title: t("WorkspaceActions", "action.autoArchive.debugAge", "Age Workspaces for Auto-Archive"),
        keywords: &["archive", "idle", "debug", "age", "clock"],
        category: "workspace",
        symbol: "clock.arrow.circlepath",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("devOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::DAYS.optional()],
        cli_name: "action debug-auto-archive-age",
        is_debug_only: true,
        ..Action::DEFAULT
    },
];
