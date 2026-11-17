//! The camera framing a picture: `Signal::Salient` ranks between the window
//! and damage and its goal is `fit::place`'s crop; `Camera::set_viewport`
//! resizes the crop live without a frame jumping; a `dwell` tour pans slowly
//! and smoothly between regions.

use cmux_follow_cam::fit::Salient;
use cmux_follow_cam::{Camera, Config, Event, Rect, STEP_US, Signal, Size, dwell, fit, place};

const ART: (f64, f64) = (1600.0, 1000.0);

fn salient(t_us: u64, r: Salient) -> Event {
    Event { t_us, signal: Signal::Salient { x: r.x, y: r.y, w: r.w, h: r.h, weight: r.weight } }
}

fn contains(outer: Rect, r: Salient) -> bool {
    r.x >= outer.x - 1e-6
        && r.y >= outer.y - 1e-6
        && r.x + r.w <= outer.x + outer.w + 1e-6
        && r.y + r.h <= outer.y + outer.h + 1e-6
}

/// Within the salient dead zone (2% of the crop) of `want`, same size.
fn near(a: Rect, want: Rect) -> bool {
    (a.x - want.x).abs() <= want.w * 0.02 + 1e-6
        && (a.y - want.y).abs() <= want.h * 0.02 + 1e-6
        && (a.w - want.w).abs() < 1e-6
        && (a.h - want.h).abs() < 1e-6
}

/// The figure on the right of a backdrop (a painting on the right, a blurred
/// fill on the left).
const FIGURE: Salient = Salient { x: 1180.0, y: 200.0, w: 200.0, h: 520.0, weight: 0.7 };
const SKY: Salient = Salient { x: 900.0, y: 0.0, w: 600.0, h: 150.0, weight: 0.3 };

#[test]
fn salient_set_frames_fit_crop() {
    for aspect in [21.0 / 9.0, 16.0 / 10.0, 9.0 / 19.5, 1.0] {
        let config = Config { aspect, ..Config::default() };
        let mut camera = Camera::new(config, ART.0, ART.1);
        camera.push(salient(0, FIGURE));
        camera.push(salient(0, SKY));
        let rect = camera.advance(5_000_000);
        let want = fit(Size::new(ART.0, ART.1), aspect, &[FIGURE, SKY]);
        assert!(near(rect, want), "{aspect}: {rect:?} != {want:?}");
        // The figure (the heavier region) stays at least 90% in frame; at
        // 21:9 the crop is too short for figure and sky both and gives up a
        // little of the figure's feet for the sky.
        let kept_w = (rect.x + rect.w).min(FIGURE.x + FIGURE.w) - rect.x.max(FIGURE.x);
        let kept_h = (rect.y + rect.h).min(FIGURE.y + FIGURE.h) - rect.y.max(FIGURE.y);
        let kept = kept_w.max(0.0) * kept_h.max(0.0) / (FIGURE.w * FIGURE.h);
        assert!(kept >= 0.9, "{aspect}: {rect:?} keeps {kept}");
        if FIGURE.h + 200.0 <= rect.h && FIGURE.w <= rect.w {
            assert!(contains(rect, FIGURE), "{aspect}: {rect:?}");
        }
    }
}

#[test]
fn salient_ranks_between_window_and_damage() {
    let config = Config { aspect: 9.0 / 19.5, ..Config::default() };
    let mut camera = Camera::new(config, ART.0, ART.1);
    camera.push(Event {
        t_us: 0,
        signal: Signal::Window { id: 1, x: 0.0, y: 0.0, w: 300.0, h: 300.0 },
    });
    camera.push(salient(10, FIGURE));
    let focus = camera.focus().expect("focus");
    let (fx, _) = focus.center();
    assert!(fx > 1000.0, "salient beats the window: {focus:?}");
    camera.push(Event { t_us: 20, signal: Signal::Damage { x: 10.0, y: 10.0, w: 50.0, h: 50.0 } });
    let focus = camera.focus().expect("focus");
    assert_eq!(focus, Rect::new(10.0, 10.0, 50.0, 50.0), "damage beats salient");
    // Damage expires; salient frames again.
    camera.advance(2_000_000);
    let (fx, _) = camera.focus().expect("focus").center();
    assert!(fx > 1000.0);
}

#[test]
fn later_salient_starts_a_new_set_and_cut_clears_it() {
    let mut camera = Camera::new(Config::default(), ART.0, ART.1);
    camera.push(salient(0, FIGURE));
    camera.push(salient(0, SKY));
    let left = Salient::new(50.0, 400.0, 100.0, 100.0, 1.0);
    camera.push(salient(1_000, left));
    let want = place(Size::new(ART.0, ART.1), (camera.rect().w, camera.rect().h), &[left], 0.03);
    assert_eq!(camera.focus(), Some(want));
    camera.push(Event { t_us: 2_000, signal: Signal::Cut });
    assert_eq!(camera.focus(), None);
}

#[test]
fn bad_salient_signals_are_ignored() {
    let mut camera = Camera::new(Config::default(), ART.0, ART.1);
    for (i, r) in [
        Salient::new(f64::NAN, 0.0, 1.0, 1.0, 1.0),
        Salient::new(0.0, 0.0, 1.0, 1.0, -1.0),
        Salient::new(0.0, 0.0, -5.0, 1.0, 1.0),
        Salient::new(0.0, 0.0, 1.0, 1.0, f64::INFINITY),
    ]
    .into_iter()
    .enumerate()
    {
        camera.push(salient(i as u64, r));
        assert_eq!(camera.focus(), None);
    }
    // Far outside the source: a focus, but the crop stays inside the source.
    camera.push(salient(10, Salient::new(1e7, 1e7, 10.0, 10.0, 1.0)));
    let r = camera.advance(3_000_000);
    assert!(r.x >= 0.0 && r.y >= 0.0 && r.x + r.w <= ART.0 + 1e-6 && r.y + r.h <= ART.1 + 1e-6);
}

#[test]
fn salient_json_round_trips() {
    let e = salient(5, FIGURE);
    let text = serde_json::to_string(&e).expect("json");
    assert!(text.contains("\"kind\":\"salient\""), "{text}");
    let back: Event = serde_json::from_str(&text).expect("parse");
    assert_eq!(back, e);
}

#[test]
fn set_viewport_keeps_the_centre() {
    let config = Config { aspect: 1.0, ..Config::default() };
    let mut camera = Camera::new(config, ART.0, ART.1);
    camera.push(salient(0, Salient::new(780.0, 480.0, 40.0, 40.0, 1.0)));
    let before = camera.advance(1_000_000);
    camera.set_viewport(9.0 / 19.5, 1.0);
    let after = camera.rect();
    assert!((after.w / after.h - 9.0 / 19.5).abs() < 1e-9);
    let (bx, by) = before.center();
    let (ax, ay) = after.center();
    assert!((bx - ax).abs() < 1e-6 && (by - ay).abs() < 1e-6, "{before:?} -> {after:?}");
    // Bad aspects change nothing.
    for bad in [0.0, -1.0, f64::NAN, f64::INFINITY] {
        camera.set_viewport(bad, 1.0);
        assert_eq!(camera.rect(), after);
    }
    camera.set_viewport(2.0, f64::NAN);
    assert!((camera.config().zoom - 1.0).abs() < 1e-12);
}

/// A window dragged from 16:10 to 9:19.5 to 21:9 over 6 s, one viewport
/// change per motion step, with the subject on the right: every step the
/// crop's centre moves at most one step's top speed plus half the step's
/// size change (what the source's edge forces on a crop pinned to it).
#[test]
fn live_resize_never_jumps() {
    let mut camera = Camera::new(Config { aspect: 1.6, ..Config::default() }, ART.0, ART.1);
    camera.push(salient(0, FIGURE));
    camera.push(salient(0, SKY));
    let dt = STEP_US as f64 / 1e6;
    let end_us = 6_000_000u64;
    let aspect_at = |t: u64| {
        let s = t as f64 / end_us as f64;
        // Window sizes at 16:10, 9:19.5 and 21:9; width and height move
        // linearly, as a window drag does.
        let ((fw, fh), (tw, th), k) = if s < 0.5 {
            ((1600.0, 1000.0), (540.0, 1170.0), s * 2.0)
        } else {
            ((540.0, 1170.0), (2100.0, 900.0), s * 2.0 - 1.0)
        };
        let w = fw + (tw - fw) * k;
        let h = fh + (th - fh) * k;
        w / h
    };
    let mut prev = camera.advance(0);
    let mut t = STEP_US;
    let mut max_ratio: f64 = 0.0;
    while t <= end_us + 3_000_000 {
        camera.set_viewport(aspect_at(t.min(end_us)), 1.0);
        let rect = camera.advance(t);
        let (px, py) = prev.center();
        let (cx, cy) = rect.center();
        let vmax = camera.config().max_speed * rect.w.max(prev.w);
        let bound_x = vmax * dt + (rect.w - prev.w).abs() / 2.0 + 1e-6;
        let bound_y = vmax * dt + (rect.h - prev.h).abs() / 2.0 + 1e-6;
        assert!((cx - px).abs() <= bound_x, "x jump {} > {bound_x} at {t}", (cx - px).abs());
        assert!((cy - py).abs() <= bound_y, "y jump {} > {bound_y} at {t}", (cy - py).abs());
        max_ratio = max_ratio.max((cx - px).abs() / bound_x);
        assert!(rect.x >= -1e-6 && rect.x + rect.w <= ART.0 + 1e-6);
        assert!(rect.y >= -1e-6 && rect.y + rect.h <= ART.1 + 1e-6);
        prev = rect;
        t += STEP_US;
    }
    // At rest at 21:9 the crop is fit's.
    let want = fit(Size::new(ART.0, ART.1), aspect_at(end_us), &[FIGURE, SKY]);
    assert!(near(prev, want), "{prev:?} != {want:?}");
    assert!(max_ratio > 0.0);
}

/// Far from the edges no clamp moves the centre: the step bound alone holds.
#[test]
fn resize_in_the_middle_is_pure_pan() {
    let mut camera =
        Camera::new(Config { aspect: 1.0, zoom: 2.0, ..Config::default() }, ART.0, ART.1);
    camera.push(salient(0, Salient::new(790.0, 490.0, 20.0, 20.0, 1.0)));
    let mut prev = camera.advance(0);
    let dt = STEP_US as f64 / 1e6;
    for k in 1..=480u64 {
        let aspect = 1.0 + (k as f64 / 480.0) * 0.6;
        camera.set_viewport(aspect, 2.0);
        let rect = camera.advance(k * STEP_US);
        let vmax = camera.config().max_speed * rect.w.max(prev.w);
        let (px, py) = prev.center();
        let (cx, cy) = rect.center();
        assert!((cx - px).hypot(cy - py) <= vmax * dt * 1.5 + 1e-6, "step {k}");
        prev = rect;
    }
}

#[test]
fn dwell_tour_visits_each_region_smoothly() {
    let regions = [
        Salient::new(1200.0, 250.0, 120.0, 300.0, 0.6),
        Salient::new(150.0, 650.0, 120.0, 120.0, 0.4),
    ];
    let config = Config::wallpaper(16.0 / 10.0);
    let mut camera = Camera::new(config, ART.0, ART.1);
    let events = dwell::tour(&regions, 0, 30_000_000, 2);
    let mut next = events.iter().peekable();
    let mut t = 0;
    let dt = STEP_US as f64 / 1e6;
    let mut prev: Option<Rect> = None;
    let mut seen = [false; 2];
    while t <= 60_000_000 {
        while let Some(e) = next.next_if(|e| e.t_us <= t) {
            camera.push(*e);
        }
        let rect = camera.advance(t);
        if let Some(p) = prev {
            let vmax = config.max_speed * rect.w;
            assert!((rect.x - p.x).abs() <= vmax * dt * 1.0001 + 1e-9, "speed at {t}");
            assert!((rect.y - p.y).abs() <= vmax * dt * 1.0001 + 1e-9, "speed at {t}");
        }
        for (i, r) in regions.iter().enumerate() {
            if contains(rect, *r) {
                seen[i] = true;
            }
        }
        prev = Some(rect);
        t += STEP_US;
    }
    assert_eq!(seen, [true, true]);
}
