// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `GitActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "GitActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "git.worktree.create",
        group: GROUP,
        title: t("ActionCatalog", "action.git.worktree.create", "New Git Worktree"),
        keywords: &["git", "worktree", "branch", "checkout", "new", "create", "isolate"],
        category: "tab",
        symbol: "arrow.triangle.branch",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[args::WORKTREE_NAME.asked_in_palette(), args::WORKTREE_BASE.asked_in_palette()],
        targets: &["tab"],
        cli_name: "action git-worktree-create",
        ..Action::DEFAULT
    },
    Action {
        id: "git.worktree.apply",
        group: GROUP,
        title: t("ActionCatalog", "action.git.worktree.apply", "Apply Worktree to Main Checkout"),
        keywords: &["git", "worktree", "apply", "merge", "bring back", "main", "checkout"],
        category: "tab",
        symbol: "arrow.down.to.line",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "action git-worktree-apply",
        ..Action::DEFAULT
    },
    Action {
        id: "git.worktree.remove",
        group: GROUP,
        title: t("ActionCatalog", "action.git.worktree.remove", "Remove Git Worktree"),
        keywords: &["git", "worktree", "remove", "delete", "clean up", "branch"],
        category: "tab",
        symbol: "trash",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[args::WORKTREE_DISCARD.asked_in_palette(), args::CONFIRM.optional()],
        targets: &["tab"],
        cli_name: "action git-worktree-remove",
        is_destructive: true,
        ..Action::DEFAULT
    },
    Action {
        id: "git.checkpoint.create",
        group: GROUP,
        title: t("ActionCatalog", "action.git.checkpoint.create", "Create Git Checkpoint"),
        keywords: &["git", "checkpoint", "snapshot", "save", "capture", "stash"],
        category: "tab",
        symbol: "camera",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "action git-checkpoint-create",
        ..Action::DEFAULT
    },
];
