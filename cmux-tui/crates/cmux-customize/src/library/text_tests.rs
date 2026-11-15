use super::*;

#[test]
fn colors_are_hex_runs_of_three_or_six() {
    assert_eq!(colors("a #1E1E2E b #fff #12345 #abcdefg c#00ff00"), ["#1e1e2e", "#fff", "#00ff00"]);
}

#[test]
fn a_slug_is_a_profile_name() {
    assert_eq!(slug("Make the sidebar compact!"), "make-the-sidebar-compact");
    assert_eq!(slug("profile tiling-look"), "tiling-look");
    assert_eq!(slug("…"), "change");
    assert!(valid_name(&slug(&"word ".repeat(40))));
}
