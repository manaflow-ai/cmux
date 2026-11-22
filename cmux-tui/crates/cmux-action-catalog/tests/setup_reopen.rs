//! Setup stays reachable after first run through the release action surfaces.
use cmux_action_catalog::{Decision, MENU, PALETTE, find};

#[test]
fn setup_can_be_reopened_from_the_palette_menu_and_cli() {
    let action = find("home.showSetup").expect("the release setup action");
    assert_eq!(action.surfaces & (PALETTE | MENU), PALETTE | MENU);
    assert_eq!(action.surface_plan.palette, Decision::Offered);
    assert_eq!(action.surface_plan.cli, Some(Decision::Offered));
    assert_eq!(action.cli_name, "home setup");
    assert_eq!(action.main_menu, find("customize.open").unwrap().main_menu);
    assert!(action.requires.is_empty(), "setup must not require first run");
    assert!(action.focuses, "setup brings Home forward");
}
