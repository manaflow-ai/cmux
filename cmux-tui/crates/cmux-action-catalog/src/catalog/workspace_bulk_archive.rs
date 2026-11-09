// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `WorkspaceBulkArchiveActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "WorkspaceBulkArchiveActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "workspace.archiveOtherWorkspaces",
        group: GROUP,
        title: t("WorkspaceActions", "action.workspace.archiveOtherWorkspaces", "Archive Other Workspaces"),
        keywords: &["archive", "others", "tidy", "declutter", "hide"],
        category: "workspace",
        symbol: "archivebox.circle",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "close", 600).folder("archive")], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "workspace archive-other",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.archiveOthersInGroup",
        group: GROUP,
        title: t("WorkspaceActions", "action.workspace.archiveOthersInGroup", "Archive Other Workspaces in Group"),
        keywords: &["archive", "others", "group", "tidy", "declutter"],
        category: "workspace",
        symbol: "square.stack.3d.down.right",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "close", 601).folder("archive")], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "workspace archive-others-in-group",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.archiveWorkspacesBelow",
        group: GROUP,
        title: t("WorkspaceActions", "action.workspace.archiveWorkspacesBelow", "Archive Workspaces Below"),
        keywords: &["archive", "below", "under", "after", "tidy", "declutter"],
        category: "workspace",
        symbol: "arrowshape.down",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "close", 602).folder("archive")], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "workspace archive-below",
        ..Action::DEFAULT
    },
    Action {
        id: "workspace.archiveWorkspacesAbove",
        group: GROUP,
        title: t("WorkspaceActions", "action.workspace.archiveWorkspacesAbove", "Archive Workspaces Above"),
        keywords: &["archive", "above", "over", "before", "tidy", "declutter"],
        category: "workspace",
        symbol: "arrowshape.up",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "close", 603).folder("archive")], ..SurfacePlan::DEFAULT },
        targets: &["workspace"],
        cli_name: "workspace archive-above",
        ..Action::DEFAULT
    },
];
