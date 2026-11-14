// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `ImportActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "ImportActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "import.list",
        group: GROUP,
        title: t("ImportActions", "action.import.list", "List Import Suggestions"),
        keywords: &["import", "browser", "chrome", "safari", "arc", "claude", "codex", "iterm", "ghostty", "classic"],
        category: "settings",
        symbol: "square.and.arrow.down",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("noObject"), cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "import list",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "import.card",
        group: GROUP,
        title: t("ImportActions", "action.import.card", "Press an Import Card's Button"),
        keywords: &["import", "card", "dismiss", "resume"],
        category: "settings",
        symbol: "square.and.arrow.down",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("noObject"), cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::ID_4, args::ACTION],
        cli_name: "import card",
        ..Action::DEFAULT
    },
    Action {
        id: "import.suggest",
        group: GROUP,
        title: t("ImportActions", "action.import.suggest", "Suggest Importing a Site's Cookies"),
        keywords: &["import", "cookies", "sign in", "login", "suggest", "chief"],
        category: "settings",
        symbol: "key",
        surfaces: KEYBOARD,
        surface_plan: SurfacePlan { palette: Decision::Exempt("noObject"), cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::BROWSER_2, args::SITE, args::REASON_2.optional()],
        cli_name: "import suggest",
        ..Action::DEFAULT
    },
    Action {
        id: "import.open",
        group: GROUP,
        title: t("ImportActions", "action.import.open", "Import from Other Apps…"),
        keywords: &["import", "browser", "chrome", "safari", "arc", "claude", "codex", "iterm", "ghostty", "classic", "migrate"],
        category: "settings",
        symbol: "square.and.arrow.down",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "import open",
        ..Action::DEFAULT
    },
];
