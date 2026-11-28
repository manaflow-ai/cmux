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
    // A chat's inline Connect card for a cmux connection other than GitHub (webviews
    // githubConnect.ts `SERVICE_CONNECT_ACTION`): Settings > Integrations > Connections' own flow
    // for the one service the card names. Only from the card, on the person's tap.
    Action {
        id: "connections.connect",
        group: GROUP,
        title: t("AccountsActions", "action.connections.connect", "Connect a Service"),
        keywords: &["connection", "integration", "sign in", "linear", "sentry", "notion"],
        category: "cloud",
        symbol: "link",
        surface_plan: SurfacePlan { palette: Decision::Exempt("paletteInternal"), cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), mcp_exemption: Some("credentials"), ..SurfacePlan::DEFAULT },
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
    Action {
        id: "accounts.connect",
        group: GROUP,
        title: t("AccountsActions", "action.accounts.connect", "Connect Account to CodeRouter…"),
        keywords: &["coderouter", "link", "share", "agents", "cloud"],
        category: "cloud",
        symbol: "link",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("credentials"), ..SurfacePlan::DEFAULT },
        requires: &["signedIn"],
        arguments: &[args::PROVIDER_2],
        cli_name: "accounts connect",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "accounts.remove",
        group: GROUP,
        title: t("AccountsActions", "action.accounts.remove", "Remove Account from CodeRouter"),
        keywords: &["coderouter", "unlink", "delete"],
        category: "cloud",
        symbol: "link.badge.plus",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("credentials"), ..SurfacePlan::DEFAULT },
        requires: &["signedIn"],
        arguments: &[args::ACCOUNT_2, args::CONFIRM.optional()],
        cli_name: "accounts remove",
        is_destructive: true,
        waits_for_result: true,
        ..Action::DEFAULT
    },
];
