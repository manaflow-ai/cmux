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

/// The light field crosses the C ABI whole: a warm sun on a navy sky comes
/// back with its key light, and the point and rim calls take it back.
#[test]
fn light_field_round_trips() {
    let (w, h) = (32u32, 20u32);
    let mut px = Vec::new();
    for y in 0..h as i32 {
        for x in 0..w as i32 {
            let sun = (x - 25).pow(2) + (y - 4).pow(2) < 9;
            px.extend_from_slice(&if sun { [255, 200, 120, 255] } else { [12, 18, 40, 255] });
        }
    }
    let mut field = CmuxLightField::default();
    // SAFETY: `px` is `px.len()` readable bytes; `field` is writable.
    assert!(unsafe { cmux_motion_light_field(px.as_ptr(), px.len(), w, h, w * 4, &mut field) });
    assert!(field.key_x > 0.7 && field.key_y < 0.35 && field.key_strength > 0.5, "{field:?}");
    // SAFETY: a buffer one byte short is refused, never read past.
    assert!(!unsafe {
        cmux_motion_light_field(px.as_ptr(), px.len() - 1, w, h, w * 4, &mut field)
    });
    let mut xy = [0.; 2];
    // SAFETY: `field` is readable; `xy` is 2 writable doubles.
    assert!(unsafe { cmux_motion_light_point(&field, 1.6, 1600., 1000., xy.as_mut_ptr()) });
    let mut rim = CmuxLightRim::default();
    let rect = [0., 0., 400., 1000.];
    // SAFETY: every pointer is valid for its size.
    assert!(unsafe { cmux_motion_light_rim(&field, xy[0], xy[1], rect.as_ptr(), 1886., &mut rim) });
    assert!(rim.alpha > 0. && rim.center_x > 1., "the light lies right of a sidebar: {rim:?}");
}
