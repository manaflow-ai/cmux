// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AccountActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "AccountActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "accounts.githubConnect",
        group: GROUP,
        title: t("AccountsActions", "action.accounts.githubConnect", "Connect GitHub"),
        keywords: &["github", "repositories", "integration"],
        category: "cloud",
        symbol: "link",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("credentials"), ..SurfacePlan::DEFAULT },
        cli_name: "accounts github-connect",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "accounts.show",
        group: GROUP,
        title: t("AccountsActions", "action.accounts.show", "Accounts…"),
        keywords: &["coderouter", "codex", "chatgpt", "claude", "anthropic", "openai", "api key", "login"],
        category: "cloud",
        symbol: "person.crop.circle",
        surfaces: PALETTE | MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "accounts show",
        ..Action::DEFAULT
    },
    Action {
        id: "accounts.refresh",
        group: GROUP,
        title: t("AccountsActions", "action.accounts.refresh", "Refresh Accounts"),
        keywords: &["coderouter", "detect", "sign-in"],
        category: "cloud",
        symbol: "arrow.clockwise",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "accounts refresh",
        ..Action::DEFAULT
    },
    Action {
        id: "accounts.reauthenticate",
        group: GROUP,
        title: t("AccountsActions", "action.accounts.reauthenticate", "Re-authenticate Provider…"),
        keywords: &["coderouter", "login", "codex login", "claude login", "sign in"],
        category: "cloud",
        symbol: "person.badge.key",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("credentials"), ..SurfacePlan::DEFAULT },
        arguments: &[args::PROVIDER],
        cli_name: "accounts reauth",
        waits_for_result: true,
        ..Action::DEFAULT
    },
];
