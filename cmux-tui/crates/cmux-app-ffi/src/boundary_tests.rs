//! Every motion export runs in cmux-ffi-guard's boundary or names why it
//! cannot panic; a guarded panic answers "no animation".

use crate::motion::*;
use cmux_ffi_guard::testing::{panic_through, unguarded_exports};

#[test]
fn every_export_is_guarded() {
    assert_eq!(unguarded_exports(include_str!("motion.rs")), Vec::<String>::new());
}

#[test]
fn a_guarded_panic_answers_no_animation() {
    let spring = CmuxMotionSpring { response: 0.3, damping_fraction: 0.8 };
    let policy = CmuxMotionPolicy {
        speed: 0,
        reduce_motion: false,
        bounce: 0,
        pane_animations: true,
        new_tab: true,
        new_workspace: true,
    };
    let mut state = CmuxMotionState { value: 0.0, velocity: 0.0, target: 1.0 };
    // SAFETY: a valid, writable state.
    let (moving, name) =
        panic_through(|| unsafe { cmux_motion_step(&mut state, 0.016, spring, 0.001) });
    assert_eq!((moving, name.as_deref()), (false, Some("cmux_motion_step")));
    assert_eq!(state.value, 0.0, "the panicked step wrote nothing");

    let (resolved, name) = panic_through(|| cmux_motion_resolve(spring, true, policy));
    assert_eq!((resolved, name.as_deref()), (spring, Some("cmux_motion_resolve")));
    let (seconds, name) = panic_through(|| cmux_motion_fade_seconds(0, policy));
    assert_eq!((seconds, name.as_deref()), (0.0, Some("cmux_motion_fade_seconds")));
    let (progress, name) = panic_through(|| cmux_motion_ease(0, 0.25));
    assert_eq!((progress, name.as_deref()), (1.0, Some("cmux_motion_ease")));

    // The library still answers after the panics.
    // SAFETY: as above.
    assert!(unsafe { cmux_motion_step(&mut state, 0.016, spring, 0.001) });
    assert!(state.value > 0.0);
}
