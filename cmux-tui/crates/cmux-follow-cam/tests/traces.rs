//! The follow camera on signal traces (tests/traces): the dead zone holds,
//! a cut snaps, a pan is smooth with bounded speed and acceleration, the
//! person's manual crop holds until a tap hands it back.

use cmux_follow_cam::{Camera, Config, Event, Mode, Rect, STEP_US, Signal, path, read_trace};

const SCREEN: (f64, f64) = (2560.0, 1440.0);

fn trace(name: &str) -> Vec<Event> {
    let text = match name {
        "terminal_typing" => include_str!("traces/terminal_typing.jsonl"),
        "window_switch" => include_str!("traces/window_switch.jsonl"),
        "far_jump" => include_str!("traces/far_jump.jsonl"),
        "damage_only" => include_str!("traces/damage_only.jsonl"),
        _ => panic!("no trace {name}"),
    };
    read_trace(text).expect("trace parses")
}

/// The crop at every motion step from 0 to `end_us`, events pushed on time.
fn run(camera: &mut Camera, events: &[Event], end_us: u64) -> Vec<(u64, Rect)> {
    let mut out = Vec::new();
    let mut next = events.iter().peekable();
    let mut t = 0;
    while t <= end_us {
        while let Some(event) = next.next_if(|e| e.t_us <= t) {
            camera.push(*event);
        }
        out.push((t, camera.advance(t)));
        t += STEP_US;
    }
    out
}

fn center_x(r: &Rect) -> f64 {
    r.x + r.w / 2.0
}

/// Speed and acceleration bounds of a path along x, in pixels.
fn assert_smooth(frames: &[(u64, Rect)], config: &Config) {
    let w = frames[0].1.w;
    let dt = STEP_US as f64 / 1e6;
    let vmax = config.max_speed * w;
    let amax = config.max_accel * w;
    for pair in frames.windows(2) {
        let v = (pair[1].1.x - pair[0].1.x) / dt;
        assert!(v.abs() <= vmax * 1.0001, "speed {v} over {vmax} at {}", pair[1].0);
    }
    for triple in frames.windows(3) {
        let a = (triple[2].1.x - 2.0 * triple[1].1.x + triple[0].1.x) / (dt * dt);
        // One step's settle-to-goal may stop a crawl of under SETTLE_PX.
        assert!(
            a.abs() <= amax * 1.0001 + 1.0 / (dt * dt),
            "acceleration {a} over {amax} at {}",
            triple[2].0
        );
    }
}

#[test]
fn dead_zone_holds_while_typing_on_a_line() {
    let config = Config::default();
    let mut camera = Camera::new(config, SCREEN.0, SCREEN.1);
    let events = trace("terminal_typing");
    let frames = run(&mut camera, &events, 3_200_000);
    // The first caret (t = 50 ms) lands in the opening shot.
    let settled = frames.iter().find(|(t, _)| *t >= 60_000).unwrap().1;
    assert!((center_x(&settled) - 1004.5).abs() < 0.01, "opens on the caret: {settled:?}");
    for (t, rect) in frames.iter().filter(|(t, _)| *t >= 60_000) {
        assert_eq!(
            rect.x, settled.x,
            "camera moved at {t} while the caret stayed in the dead zone"
        );
        assert_eq!(rect.y, 0.0);
    }
}

#[test]
fn a_window_switch_cuts_to_the_new_caret_with_no_pan_between() {
    let config = Config::default();
    let mut camera = Camera::new(config, SCREEN.0, SCREEN.1);
    let events = trace("window_switch");
    let frames = run(&mut camera, &events, 2_000_000);
    let old = 604.5;
    let new = 1904.5;
    let before = frames.iter().rev().find(|(t, _)| *t < 1_000_000).unwrap().1;
    assert!((center_x(&before) - old).abs() < 1.0, "before the switch: {before:?}");
    // From the caret of window 2 on, the crop is on it at once.
    let at = frames.iter().find(|(t, _)| *t >= 1_060_000).unwrap().1;
    assert!((center_x(&at) - new).abs() < 0.01, "the caret of window 2: {at:?}");
    // No frame shows a pan between the two shots: only the old shot, the
    // new window's middle (the 60 ms before its caret) and the new caret.
    let window_middle = 1600.0 + 900.0 / 2.0;
    for (t, rect) in &frames {
        let cx = center_x(rect);
        let known = [old, window_middle, new].iter().any(|shot| (cx - shot).abs() < 20.0);
        assert!(known, "frame at {t} sits between shots: {cx}");
    }
    assert_eq!(camera.mode(), Mode::Follow);
}

#[test]
fn a_far_caret_jump_pans_smoothly_and_stops_on_it() {
    let config = Config::default();
    let mut camera = Camera::new(config, SCREEN.0, SCREEN.1);
    let events = trace("far_jump");
    let frames = run(&mut camera, &events, 2_200_000);
    let pan: Vec<_> = frames.iter().copied().filter(|(t, _)| *t >= 900_000).collect();
    assert_smooth(&pan, &config);
    // It is a pan, not a cut: the step right after the jump barely moves.
    let jump = pan.iter().position(|(t, _)| *t > 1_000_000).unwrap();
    assert!((pan[jump].1.x - pan[jump - 1].1.x).abs() < 5.0, "snapped instead of panning");
    // It ends centred on the far caret and never runs past it.
    let goal_x = 2004.5 - pan[0].1.w / 2.0;
    let overshoot = pan.iter().map(|(_, r)| r.x - goal_x).fold(f64::MIN, f64::max);
    assert!(overshoot <= 1.0, "ran {overshoot} px past the goal");
    let arrived = pan.iter().find(|(_, r)| (r.x - goal_x).abs() < 0.5).expect("arrives");
    // 1500 px with 9720 px/s^2 and 2430 px/s: under 0.9 s.
    assert!(arrived.0 < 1_900_000, "arrived only at {}", arrived.0);
    assert!(
        pan.iter().filter(|(t, _)| *t > arrived.0).all(|(_, r)| r.x == arrived.1.x),
        "moved after arriving"
    );
}

#[test]
fn damage_draws_the_camera_when_nothing_else_does() {
    let config = Config::default();
    let mut camera = Camera::new(config, SCREEN.0, SCREEN.1);
    let events = trace("damage_only");
    let frames = run(&mut camera, &events, 3_000_000);
    let opening = frames.iter().find(|(t, _)| *t >= 10_000).unwrap().1;
    assert!((center_x(&opening) - 1280.0).abs() < 0.01, "opens on the window: {opening:?}");
    let end = frames.last().unwrap().1;
    assert!((center_x(&end) - 1850.0).abs() < 1.0, "ends on the damage: {end:?}");
    // The full-screen redraw at 400 ms says nothing; the pan is smooth.
    let pan: Vec<_> = frames.iter().copied().filter(|(t, _)| *t >= 250_000).collect();
    assert_smooth(&pan, &config);
}

#[test]
fn manual_holds_and_a_tap_pans_back_to_the_focus() {
    let config = Config::default();
    let mut camera = Camera::new(config, SCREEN.0, SCREEN.1);
    let events = trace("terminal_typing");
    let (early, late): (Vec<Event>, Vec<Event>) = events.iter().partition(|e| e.t_us < 1_000_000);
    run(&mut camera, &early, 999_000);
    // A pinch: a tighter crop at the left edge.
    let pinched = Rect::new(0.0, 200.0, 405.0, 720.0);
    camera.manual(pinched);
    assert_eq!(camera.mode(), Mode::Manual);
    for event in &late {
        camera.push(*event);
        assert_eq!(camera.advance(event.t_us), pinched, "manual crop moved at {}", event.t_us);
    }
    // A tap: back to the caret (x 1225), keeping the pinched size, smoothly.
    camera.resume();
    let start = camera.advance(3_100_000).x;
    let mut frames = Vec::new();
    let mut t = 3_100_000;
    while t <= 4_500_000 {
        frames.push((t, camera.advance(t)));
        t += STEP_US;
    }
    assert!((frames[1].1.x - start).abs() < 5.0, "resume snapped");
    assert_smooth(&frames, &Config { ..config });
    let end = frames.last().unwrap().1;
    assert_eq!((end.w, end.h), (405.0, 720.0), "kept the pinched size");
    assert!((center_x(&end) - 1229.5).abs() < 1.0, "back on the caret: {end:?}");
}

#[test]
fn the_crop_never_leaves_the_screen() {
    let mut camera = Camera::new(Config { zoom: 2.0, ..Config::default() }, SCREEN.0, SCREEN.1);
    camera.push(Event {
        t_us: 0,
        signal: Signal::Window { id: 1, x: 0.0, y: 0.0, w: 2560.0, h: 1440.0 },
    });
    camera
        .push(Event { t_us: 10_000, signal: Signal::Caret { x: 2.0, y: 1430.0, w: 9.0, h: 18.0 } });
    let r = camera.advance(20_000);
    assert_eq!((r.x, r.y + r.h), (0.0, 1440.0), "clamped to the bottom left: {r:?}");
}

#[test]
fn a_moving_pointer_takes_over_from_an_older_caret() {
    let mut camera = Camera::new(Config::default(), SCREEN.0, SCREEN.1);
    camera.push(Event {
        t_us: 0,
        signal: Signal::Window { id: 1, x: 0.0, y: 0.0, w: 2560.0, h: 1440.0 },
    });
    camera.push(Event {
        t_us: 10_000,
        signal: Signal::Caret { x: 400.0, y: 700.0, w: 9.0, h: 18.0 },
    });
    camera.push(Event { t_us: 500_000, signal: Signal::Pointer { x: 2200.0, y: 700.0 } });
    let end = camera.advance(2_000_000);
    assert!((center_x(&end) - 2200.0).abs() < 1.0, "follows the pointer: {end:?}");
}

#[test]
fn the_cutter_path_matches_the_camera_at_any_frame_rate() {
    let events = trace("far_jump");
    let at30 = path(Config::default(), SCREEN.0, SCREEN.1, &events, 30.0);
    let at60 = path(Config::default(), SCREEN.0, SCREEN.1, &events, 60.0);
    assert_eq!(at30.len(), 63);
    for frame in &at30 {
        let same = at60.iter().find(|f| f.t_us == frame.t_us);
        if let Some(same) = same {
            assert!((same.rect.x - frame.rect.x).abs() < 1e-6, "paths differ at {}", frame.t_us);
        }
    }
}
