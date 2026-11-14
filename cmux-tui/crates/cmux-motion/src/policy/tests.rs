use super::*;

/// A tab close slides on the `tabs` category alone: `ui.animations.newTab` off stops only a new
/// tab's growth, not the close (close case A follow-up, PR #37401).
#[test]
fn new_tab_off_stops_only_the_tab_open_tween() {
    let policy = MotionPolicy::default()
        .with_animations(AnimationSwitches::DEFAULT.with(MotionKind::NewTab, false));
    assert_eq!(policy.tween(MotionTween::TabOpen), 0.);
    assert!(
        policy.tween(MotionTween::TabClose) > 0.,
        "the close tween follows ui.animations.newTab"
    );
    assert!(policy.tween(MotionTween::TabMove) > 0.);
}

/// No bounce in any motion (Lawrence 2026-11-10;
/// plans/cmux-next/motion-first-principles-DESIGN.md, principle 5: position never passes
/// its target). Every spring token, at every speed, is critically damped or more, and no
/// frame of a 200 pt move on it is past the target (by more than 1e-6 of the travel).
#[test]
fn no_spring_token_passes_its_target() {
    for token in MotionSpring::ALL {
        for speed in [MotionSpeed::Fast, MotionSpeed::Normal, MotionSpeed::Off] {
            let spring = MotionPolicy::new(speed, false).spring(token);
            assert!(
                spring.damping_fraction >= 1.,
                "{token:?} at speed {speed:?} has damping fraction {}: it passes its target",
                spring.damping_fraction
            );
            for hz in [60., 120.] {
                let mut value = crate::SpringValue::new(0.);
                value.target = 200.;
                for frame in 0..(3. * hz) as usize {
                    let moving = value.advance(1. / hz, spring, crate::GEOMETRY_EPSILON);
                    assert!(
                        value.value <= 200.0002,
                        "{token:?} at speed {speed:?}, {hz} Hz, frame {frame}: {} is past 200",
                        value.value
                    );
                    if !moving {
                        break;
                    }
                }
            }
        }
    }
}
