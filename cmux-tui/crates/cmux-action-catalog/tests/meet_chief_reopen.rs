//! Meet Chief stays reachable after its first run: the palette shows it again on the Chief chat.
use cmux_action_catalog::{Decision, PALETTE, find};

#[test]
fn meet_chief_can_be_reopened_from_the_palette() {
    let action = find("home.meetChief").expect("the Meet Chief action");
    assert_eq!(action.surfaces & PALETTE, PALETTE);
    assert_eq!(action.surface_plan.palette, Decision::Offered);
    assert!(action.requires.is_empty(), "Meet Chief must not require a first run");
    assert!(action.focuses, "Meet Chief brings the Chief chat forward");
    assert!(action.keywords.contains(&"onboarding"), "the palette finds it by onboarding");
}
