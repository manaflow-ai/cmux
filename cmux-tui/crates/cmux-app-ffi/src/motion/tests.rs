use super::*;

fn base(token: u8) -> Option<CmuxMotionSpring> {
    let mut out = CmuxMotionSpring { response: 0., damping_fraction: 0. };
    // SAFETY: `out` is a valid, writable `CmuxMotionSpring`.
    unsafe { cmux_motion_spring_base(token, &mut out) }.then_some(out)
}

/// A change of screen has no animation (Lawrence 2026-11-10): the table has no `screen`
/// spring. 12 tokens; `track` follows `scroll`.
#[test]
fn the_spring_table_has_no_screen_token() {
    assert_eq!(base(4), Some(MotionSpring::Scroll.base().into()));
    assert_eq!(base(5), Some(MotionSpring::Track.base().into()), "token 5 is not track");
    assert_eq!(base(11), Some(MotionSpring::TabOpen.base().into()), "token 11 is not tabOpen");
    assert_eq!(base(12), None, "the table has a 13th spring token");
}

/// No bounce in any motion (Lawrence 2026-11-10): no token of the table is under-damped.
#[test]
fn no_spring_token_is_under_damped() {
    for token in 0..=u8::MAX {
        if let Some(spring) = base(token) {
            assert!(
                spring.damping_fraction >= 1.,
                "spring token {token} has damping fraction {}",
                spring.damping_fraction
            );
        }
    }
}
