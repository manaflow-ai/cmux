// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `KeyModeActionCatalog` actions: user key modes (design/key-modes.md). Entering a mode
//! sets the `keyMode` context key to its name, so bindings under `keyMode == 'name'` may use
//! bare keys until the mode exits (Escape, `keyMode.exit`, or entering another mode).

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "KeyModeActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "keyMode.enter",
        group: GROUP,
        title: t("ActionCatalog", "action.keyMode.enter", "Enter Key Mode…"),
        keywords: &["key mode", "mode", "modal", "layer", "keys", "keyboard", "vim", "resize"],
        category: "window",
        symbol: "keyboard",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::NAME],
        cli_name: "app key-mode-enter",
        ..Action::DEFAULT
    },
    Action {
        id: "keyMode.exit",
        group: GROUP,
        title: t("ActionCatalog", "action.keyMode.exit", "Exit Key Mode"),
        keywords: &["key mode", "mode", "modal", "layer", "keys", "keyboard", "leave", "escape"],
        category: "window",
        symbol: "keyboard.chevron.compact.down",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "app key-mode-exit",
        ..Action::DEFAULT
    },
];
