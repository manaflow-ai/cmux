//! A sidebar machine header's right-click menu has the header's screen control: Share This Mac
//! and View Screen, both in the Connection group of the `machineSection` menu (Leo 2026-11-14:
//! "ok but in screen sharing we also want the interaction pathways better"). The app shows at
//! most one of them, by the header button's own rule.
use cmux_action_catalog::{CONTEXT_MENU, Decision, find};

fn header_placement(id: &str) -> cmux_action_catalog::Placement {
    let action = find(id).unwrap_or_else(|| panic!("{id}"));
    assert_ne!(action.surfaces & CONTEXT_MENU, 0, "{id} is not on a right-click menu");
    *action
        .surface_plan
        .context_menus
        .iter()
        .find(|p| p.context == "machineSection")
        .unwrap_or_else(|| panic!("{id} is not on the machine header menu"))
}

#[test]
fn the_machine_header_menu_has_share_and_view_screen() {
    let share = header_placement("macScreen.shareThisMac");
    let view = header_placement("machine.viewScreen");
    for placement in [share, view] {
        assert_eq!(placement.group, "connection");
        assert!(placement.folder.is_none() && placement.parent.is_none(), "a top-level row");
    }
    assert!(share.rank < view.rank);
    // Share This Mac keeps its palette row and CLI decision.
    let share = find("macScreen.shareThisMac").unwrap();
    assert_eq!(share.surface_plan.palette, Decision::Offered);
    assert_eq!(share.surface_plan.cli, Some(Decision::Exempt("ownerVerb")));
    let view = find("machine.viewScreen").unwrap();
    assert_eq!(view.targets, ["machine"]);
    assert_eq!(view.title.en, "View Screen");
}
