use super::*;
use serde_json::json;

fn badge() -> WorldSpec {
    parse(
        &json!({
            "gravity": [0, 2.4],
            "bodies": [{ "id": "card", "at": [0.5, 0.6], "size": [0.2, 0.28], "mass": 1, "draggable": true, "damping": 0.6 }],
            "ropes": [{ "id": "strap", "anchor": [0.5, -0.02], "to": "card", "toAt": [0, -0.5], "length": 0.45, "segments": 7, "width": 0.012, "color": "accent" }]
        }),
        "/physics",
    )
    .unwrap()
}

const W: f32 = 1600.0;
const H: f32 = 1000.0;
const OFF: [f32; 2] = [-1.0e4, -1.0e4];

/// Runs frames at 60 Hz from `t0` for `secs`; returns the end time.
fn run(w: &mut World, t0: f64, secs: f64, pointer: [f32; 2], button: bool) -> f64 {
    let frames = (secs * 60.0).round() as u32;
    let mut t = t0;
    for _ in 0..frames {
        t += STEP_S;
        w.advance(t, W, H, pointer, button);
    }
    t
}

fn settled() -> (World, f64) {
    let mut w = World::new(&badge());
    w.advance(0.0, W, H, OFF, false);
    let mut t = 0.0;
    for _ in 0..(20 * 60) {
        t += STEP_S;
        w.advance(t, W, H, OFF, false);
        if w.asleep() {
            break;
        }
    }
    assert!(w.asleep(), "did not sleep in 20 s");
    (w, t)
}

fn pointer_of(e: crate::manifest::ManifestError) -> String {
    e.pointer
}

#[test]
fn parse_errors_name_their_pointer() {
    let cases = [
        (json!({ "nope": 1 }), "/physics/nope"),
        (json!({ "gravity": [0] }), "/physics/gravity"),
        (json!({ "bodies": [{ "id": "a", "at": [0.5, 0.5] }] }), "/physics/bodies/0"),
        (
            json!({ "bodies": [{ "id": "a", "at": [0.5, 0.5], "size": [0.1, 9] }] }),
            "/physics/bodies/0/size/1",
        ),
        (
            json!({ "bodies": [{ "id": "a", "at": [0, 0], "size": [0.1, 0.1] }, { "id": "a", "at": [0, 0], "size": [0.1, 0.1] }] }),
            "/physics/bodies/1/id",
        ),
        (
            json!({ "bodies": [{ "id": "a", "at": [0, 0], "size": [0.1, 0.1] }], "ropes": [{ "id": "r", "anchor": [0, 0], "length": 0.3, "to": "b" }] }),
            "/physics/ropes/0/to",
        ),
        (
            json!({ "ropes": [{ "id": "r", "anchor": [0, 0], "length": 0.3, "segments": 8 }] }),
            "/physics/ropes/0/segments",
        ),
        (
            json!({ "ropes": [{ "id": "r", "anchor": [0, 0], "length": 0.3, "segments": 0 }] }),
            "/physics/ropes/0/segments",
        ),
        (
            json!({ "ropes": [{ "id": "r", "anchor": [0, 0], "length": 0.3, "color": "blue" }] }),
            "/physics/ropes/0/color",
        ),
        (
            json!({ "ropes": [{ "id": "r", "anchor": [0, 0], "length": 0.3, "toAt": [0, 0], "x": 1 }] }),
            "/physics/ropes/0/x",
        ),
        (
            json!({ "ropes": [{ "id": "r", "anchor": [0, 0], "length": 0.3 }, { "id": "s", "anchor": [0, 0], "length": 0.3 }, { "id": "t", "anchor": [0, 0], "length": 0.3 }] }),
            "/physics/ropes",
        ),
        (
            json!({ "bodies": [{ "id": "a", "at": [0, 0], "size": [0.1, 0.1], "draggable": 1 }] }),
            "/physics/bodies/0/draggable",
        ),
    ];
    for (v, want) in cases {
        let got = pointer_of(parse(&v, "/physics").unwrap_err());
        assert_eq!(got, want, "for {v}");
    }
    let spec = badge();
    assert_eq!(spec.ropes[0].to, Some(0));
    assert_eq!(spec.ropes[0].segments, 7);
    assert!(spec.bodies[0].draggable);
}

#[test]
fn a_hanging_card_settles_and_sleeps() {
    let (w, t) = settled();
    assert!(t < 12.0, "slept only at {t} s");
    let p = w.pose(0);
    // Hangs under its anchor, upright and facing.
    assert!((p.x - 0.5 * W).abs() < 2.0, "x {}", p.x);
    assert!(p.rotation.abs() < 0.01, "rotation {}", p.rotation);
    assert!((p.squash - 1.0).abs() < 1e-3);
    let mut pts = Vec::new();
    w.rope_points(0, &mut pts);
    assert_eq!(pts.len(), 8);
    assert!((pts[0][0] - 0.5 * W).abs() < 1e-3 && (pts[0][1] + 0.02 * H).abs() < 1e-3);
    // The last point is on the card's top edge.
    assert!((pts[7][1] - (p.y - p.half_h)).abs() < 1.0);
}

#[test]
fn asleep_advance_does_no_work_and_does_not_pop() {
    let (mut w, t) = settled();
    let before = w.pose(0);
    let steps = w.steps;
    run(&mut w, t, 2.0, OFF, false);
    assert_eq!(w.steps, steps);
    assert!(w.asleep());
    assert_eq!(w.pose(0), before);
    // A press beside the card does not wake it; a press on it does.
    let far = [0.1 * W, 0.9 * H];
    w.advance(t + 3.0, W, H, far, true);
    assert!(w.asleep());
    w.advance(t + 3.1, W, H, far, false);
    let on = [before.x, before.y];
    w.advance(t + 3.2, W, H, on, true);
    assert!(!w.asleep());
    // Woken, it does not dump a backlog.
    w.advance(t + 3.2 + STEP_S * 2.5, W, H, on, true);
    assert_eq!(w.steps, steps + 2);
}

#[test]
fn a_pointer_move_over_the_card_leaves_it_asleep_and_a_press_wakes_it() {
    let (mut w, t) = settled();
    let p = w.pose(0);
    let steps = w.steps;
    w.advance(t + 1.0, W, H, [0.1 * W, 0.9 * H], false);
    w.advance(t + 1.1, W, H, [p.x + 5.0, p.y], false);
    w.advance(t + 1.2, W, H, [p.x - 5.0, p.y + 5.0], false);
    assert!(w.asleep());
    assert_eq!(w.steps, steps);
    w.advance(t + 1.3, W, H, [p.x - 5.0, p.y + 5.0], true);
    assert!(!w.asleep());
}

#[test]
fn frames_blend_between_the_last_two_steps() {
    let mut w = World::new(&badge());
    w.advance(0.0, W, H, OFF, false);
    let t = run(&mut w, 0.0, 0.5, OFF, false);
    w.advance(t + STEP_S * 1.5, W, H, OFF, false);
    assert!((w.alpha - 0.5).abs() < 1e-3, "alpha {}", w.alpha);
    let b = &w.bodies[0];
    let s = W.min(H);
    let p = w.pose(0);
    assert!((p.x - mix(b.prev.p[0], b.p[0], 0.5) * s).abs() < 1e-3);
    assert!((p.y - mix(b.prev.p[1], b.p[1], 0.5) * s).abs() < 1e-3);
    assert!((p.rotation - mix(b.prev.angle, b.angle, 0.5)).abs() < 1e-6);
    assert_ne!(b.prev.p, b.p, "the card should still be moving");
}

#[test]
fn drag_pulls_the_card_and_release_lets_it_swing() {
    let (mut w, t) = settled();
    let p = w.pose(0);
    let grab = [p.x, p.y];
    let t = run(&mut w, t, 0.1, grab, true);
    assert!(w.held.is_some());
    let target = [p.x + 0.15 * H, p.y - 0.05 * H];
    let t = run(&mut w, t, 1.5, target, true);
    let q = w.pose(0);
    assert!((q.x - target[0]).abs() < 0.03 * H, "x {} vs {}", q.x, target[0]);
    assert!(!w.asleep(), "holding keeps it awake");
    // Released, it swings back past its rest place.
    let mut min_x = f32::MAX;
    let mut t = t;
    for _ in 0..120 {
        t += STEP_S;
        w.advance(t, W, H, target, false);
        min_x = min_x.min(w.pose(0).x);
    }
    assert!(w.held.is_none());
    assert!(min_x < p.x - 5.0, "did not swing: min x {min_x}, rest {}", p.x);
    // And it settles again.
    run(&mut w, t, 20.0, OFF, false);
    assert!(w.asleep());
}

#[test]
fn a_resize_keeps_the_anchor_at_its_fraction() {
    let (mut w, t) = settled();
    let (w2, h2) = (900.0, 1400.0);
    w.advance(t + 1.0, w2, h2, OFF, false);
    assert!(!w.asleep(), "a resize wakes it");
    w.advance(t + 1.0 + STEP_S, w2, h2, OFF, false);
    let mut pts = Vec::new();
    w.rope_points(0, &mut pts);
    assert!((pts[0][0] - 0.5 * w2).abs() < 1e-2, "{:?}", pts[0]);
    assert!((pts[0][1] + 0.02 * h2).abs() < 1e-2, "{:?}", pts[0]);
}

#[test]
fn nan_inputs_never_make_nan_poses() {
    let mut w = World::new(&badge());
    let mut t = 0.0;
    for i in 0..300 {
        t += STEP_S;
        let now = if i % 7 == 0 { f64::NAN } else { t };
        let size = if i % 11 == 0 { f32::NAN } else { W };
        let ptr = if i % 3 == 0 { [f32::NAN, f32::INFINITY] } else { [0.5 * W, 0.6 * H] };
        w.advance(now, size, H, ptr, i % 5 != 0);
        let p = w.pose(0);
        for v in [p.x, p.y, p.rotation, p.squash, p.half_w, p.half_h] {
            assert!(v.is_finite(), "frame {i}: {p:?}");
        }
        let mut pts = Vec::new();
        w.rope_points(0, &mut pts);
        assert!(pts.iter().all(|p| finite2(*p)));
    }
}

#[test]
fn a_long_gap_steps_at_most_the_clamp() {
    let mut w = World::new(&badge());
    w.advance(0.0, W, H, OFF, false);
    w.advance(STEP_S, W, H, OFF, false);
    let steps = w.steps;
    w.advance(10.0, W, H, OFF, false);
    assert_eq!(w.steps - steps, u64::from(MAX_CATCH_UP));
    assert!(w.acc < STEP_S);
    // A clock that goes back steps nothing.
    let steps = w.steps;
    w.advance(5.0, W, H, OFF, false);
    assert_eq!(w.steps, steps);
}

#[test]
fn a_free_body_does_not_fall_forever() {
    let spec = parse(
        &json!({ "bodies": [{ "id": "a", "at": [0.5, 0.5], "size": [0.1, 0.1] }] }),
        "/physics",
    )
    .unwrap();
    let mut w = World::new(&spec);
    w.advance(0.0, W, H, OFF, false);
    run(&mut w, 0.0, 10.0, OFF, false);
    assert!(w.asleep());
}
