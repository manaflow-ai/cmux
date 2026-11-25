use super::*;

fn run(input: &ScheduleInput) -> (u32, f32) {
    match schedule(input) {
        Decision::Run { fps, interval_s, scale } => {
            assert!((interval_s - 1.0 / f64::from(fps)).abs() < 1e-12);
            (fps, scale)
        }
        d => panic!("held: {d:?}"),
    }
}

fn held(input: &ScheduleInput) -> (HoldReason, bool) {
    match schedule(input) {
        Decision::Hold { reason, draw_one, .. } => (reason, draw_one),
        d => panic!("ran: {d:?}"),
    }
}

#[test]
fn runs_by_default_at_30() {
    assert_eq!(run(&ScheduleInput::default()), (30, 1.0));
}

#[test]
fn every_hold_condition_holds_alone() {
    type Set = fn(&mut ScheduleInput);
    let cases: [(Set, HoldReason); 10] = [
        (|i| i.visible = false, HoldReason::Occluded),
        (|i| i.coverage_resting = true, HoldReason::Covered),
        (|i| i.minimized = true, HoldReason::Minimized),
        (|i| i.app_hidden = true, HoldReason::AppHidden),
        (|i| i.screens_asleep = true, HoldReason::ScreensAsleep),
        (|i| i.session_inactive = true, HoldReason::SessionInactive),
        (|i| i.low_power = true, HoldReason::LowPower),
        (|i| i.thermal_serious = true, HoldReason::Thermal),
        (|i| i.reduce_motion = true, HoldReason::ReduceMotion),
        (|i| i.animations_off = true, HoldReason::AnimationsOff),
    ];
    for (set, reason) in cases {
        let mut i = ScheduleInput::default();
        set(&mut i);
        assert_eq!(held(&i).0, reason);
        // Pointer motion never overrides a hold.
        i.seconds_since_pointer = 0.0;
        assert_eq!(held(&i).0, reason);
    }
}

#[test]
fn precedence_is_the_listed_order() {
    let all = ScheduleInput {
        visible: false,
        coverage_resting: true,
        minimized: true,
        app_hidden: true,
        screens_asleep: true,
        session_inactive: true,
        low_power: true,
        thermal_serious: true,
        reduce_motion: true,
        animations_off: true,
        seconds_since_activity: 100.0,
        gpu_strikes: 9,
        scale: 0.25,
        ..Default::default()
    };
    assert_eq!(held(&all).0, HoldReason::Occluded);
    let i = ScheduleInput {
        visible: true,
        coverage_resting: false,
        minimized: false,
        app_hidden: false,
        ..all
    };
    assert_eq!(held(&i).0, HoldReason::ScreensAsleep);
    let i = ScheduleInput {
        screens_asleep: false,
        session_inactive: false,
        low_power: false,
        thermal_serious: false,
        reduce_motion: false,
        animations_off: false,
        ..i
    };
    assert_eq!(held(&i).0, HoldReason::TooHeavy);
    let i = ScheduleInput { gpu_strikes: 0, ..i };
    assert_eq!(held(&i).0, HoldReason::Idle);
}

#[test]
fn idles_after_20_seconds_of_nothing() {
    let mut i = ScheduleInput { seconds_since_activity: 19.9, ..Default::default() };
    run(&i);
    i.seconds_since_activity = 20.0;
    assert_eq!(held(&i), (HoldReason::Idle, false));
    // Pointer motion wakes an interactive wallpaper.
    i.seconds_since_pointer = 0.5;
    run(&i);
    // But not one that is not interactive.
    i.interactive = false;
    assert_eq!(held(&i).0, HoldReason::Idle);
    // A key press or theme change wakes either.
    i.seconds_since_activity = 0.0;
    run(&i);
    // A NaN clock is no activity.
    i.seconds_since_activity = f64::NAN;
    assert_eq!(held(&i).0, HoldReason::Idle);
}

#[test]
fn a_manifest_idle_after_holds_sooner() {
    // The dot field: idle_after 2, so it holds 2 s after the last move.
    let mut i = ScheduleInput {
        seconds_since_activity: 60.0,
        seconds_since_pointer: 1.9,
        idle_after_s: 2.0,
        ..Default::default()
    };
    run(&i);
    i.seconds_since_pointer = 2.0;
    assert_eq!(held(&i).0, HoldReason::Idle);
    // A key press wakes it for the same 2 s.
    i.seconds_since_activity = 1.0;
    run(&i);
    i.seconds_since_activity = 2.5;
    assert_eq!(held(&i).0, HoldReason::Idle);
    // 0, a negative or NaN time is the default 20 s; a longer one is cut to 20 s.
    for (idle, quiet, want_held) in [
        (0.0, 19.0, false),
        (-3.0, 19.0, false),
        (f64::NAN, 19.0, false),
        (0.0, 20.0, true),
        (60.0, 20.0, true),
        (f64::INFINITY, 20.0, true),
    ] {
        let i = ScheduleInput {
            seconds_since_activity: quiet,
            idle_after_s: idle,
            ..Default::default()
        };
        assert_eq!(matches!(schedule(&i), Decision::Hold { .. }), want_held, "{idle} {quiet}");
    }
    assert_eq!(idle_after(2.0), 2.0);
    assert_eq!(idle_after(0.0), IDLE_AFTER_S);
}

#[test]
fn agent_output_wakes_only_a_wallpaper_that_reads_it() {
    let mut i = ScheduleInput {
        seconds_since_activity: 60.0,
        seconds_since_agent_event: 1.0,
        ..Default::default()
    };
    // A wallpaper without `agents` stays idle while agents write.
    assert_eq!(held(&i).0, HoldReason::Idle);
    i.agents = true;
    run(&i);
    i.seconds_since_agent_event = 20.0;
    assert_eq!(held(&i).0, HoldReason::Idle);
    // Agent output never overrides a hold such as occlusion.
    i.seconds_since_agent_event = 0.0;
    i.visible = false;
    assert_eq!(held(&i).0, HoldReason::Occluded);
}

#[test]
fn the_cap_is_the_lower_of_manifest_and_settings() {
    for (manifest, settings, want) in [
        (30, 30, 30),
        (60, 30, 30),
        (24, 60, 24),
        (60, 60, 60),
        (60, 15, 15),
        (12, 0, 12),
        (60, 0, 30),
        (0, 30, 1),
        (90, 120, 60),
    ] {
        let i = ScheduleInput {
            manifest_fps: manifest,
            settings_fps_cap: settings,
            ..Default::default()
        };
        assert_eq!(run(&i).0, want, "{manifest} {settings}");
    }
}

#[test]
fn the_cap_applies_while_the_pointer_moves() {
    let i = ScheduleInput {
        manifest_fps: 60,
        settings_fps_cap: 15,
        seconds_since_pointer: 0.0,
        ..Default::default()
    };
    assert_eq!(run(&i).0, 15);
}

#[test]
fn strikes_count_frames_over_4ms_in_a_row() {
    assert_eq!(gpu_strikes(0, 4.1), 1);
    assert_eq!(gpu_strikes(2, 9.0), 3);
    assert_eq!(gpu_strikes(2, 4.0), 0);
    assert_eq!(gpu_strikes(2, 1.0), 0);
    assert_eq!(gpu_strikes(2, f32::NAN), 2);
    assert_eq!(gpu_strikes(2, -1.0), 2);
    assert_eq!(gpu_strikes(u32::MAX, 9.0), u32::MAX);
}

#[test]
fn three_strikes_halve_the_scale_down_to_a_quarter_then_too_heavy() {
    let mut i = ScheduleInput { scale: 1.0, gpu_strikes: 2, ..Default::default() };
    assert_eq!(run(&i).1, 1.0);
    i.gpu_strikes = 3;
    assert_eq!(run(&i).1, 0.5);
    i.scale = 0.5;
    assert_eq!(run(&i).1, 0.25);
    i.scale = 0.4;
    assert_eq!(run(&i).1, 0.25);
    i.scale = 0.25;
    assert_eq!(held(&i), (HoldReason::TooHeavy, false));
    if let Decision::Hold { scale, .. } = schedule(&i) {
        assert_eq!(scale, 0.25);
    }
    i.gpu_strikes = 0;
    assert_eq!(run(&i).1, 0.25);
}

#[test]
fn scale_is_clamped() {
    assert_eq!(run(&ScheduleInput { scale: 4.0, ..Default::default() }).1, 1.0);
    assert_eq!(run(&ScheduleInput { scale: 0.0, ..Default::default() }).1, 0.25);
    assert_eq!(run(&ScheduleInput { scale: f32::NAN, ..Default::default() }).1, 1.0);
}

#[test]
fn a_window_opening_while_held_draws_one_frame() {
    let i = ScheduleInput { low_power: true, has_frame: false, ..Default::default() };
    assert_eq!(held(&i), (HoldReason::LowPower, true));
    let i = ScheduleInput { seconds_since_activity: 30.0, has_frame: false, ..Default::default() };
    assert_eq!(held(&i), (HoldReason::Idle, true));
    // Nothing to draw for while it cannot be seen.
    let i = ScheduleInput { minimized: true, has_frame: false, ..Default::default() };
    assert_eq!(held(&i), (HoldReason::Minimized, false));
    let i = ScheduleInput { low_power: true, has_frame: true, ..Default::default() };
    assert_eq!(held(&i), (HoldReason::LowPower, false));
}

#[test]
fn reason_names_are_unique() {
    let all = [
        HoldReason::Occluded,
        HoldReason::Covered,
        HoldReason::Minimized,
        HoldReason::AppHidden,
        HoldReason::ScreensAsleep,
        HoldReason::SessionInactive,
        HoldReason::LowPower,
        HoldReason::Thermal,
        HoldReason::ReduceMotion,
        HoldReason::AnimationsOff,
        HoldReason::TooHeavy,
        HoldReason::Idle,
    ];
    let names: std::collections::HashSet<_> = all.iter().map(|r| r.name()).collect();
    assert_eq!(names.len(), all.len());
    for (n, r) in all.iter().enumerate() {
        assert_eq!(*r as usize, n + 1);
    }
}
