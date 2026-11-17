//! A share's keyframes against OpenH264's rate control, deterministically: a still 1080p text
//! desktop coded at the 8 Mbit/s start rate, typing, a keyframe the viewer asks for, then
//! full-screen and windowed motion (cmux-encode `openh264::keyframe_codes_with_skip_off`).
//!
//! OpenH264 v2.6.0 codes a new instance's first IDR at a QP from a bits-per-pixel table
//! (RcCalculateIdrQp), whatever it costs: this desktop comes to ~760 KB, 0.77 s of the start
//! rate. Its skip buffer holds half a second of the rate (SKIP_RATIO), so every frame after
//! that keyframe was dropped until the excess drained: ~270 ms in which a new share's first
//! key presses showed nothing. Numbers: `cargo test -p cmux-encode --features openh264-source
//! --release --test start_keyframe -- --include-ignored --nocapture`.
#![cfg(feature = "openh264-source")]

use cmux_encode::openh264::{OpenH264, OpenH264Api};
use cmux_encode::{EncCfg, H264Encoder, I420};

const W: usize = 1920;
const H: usize = 1080;
const FPS: u32 = 60;
const FRAME_US: i64 = 1_000_000 / FPS as i64;
const START_KBPS: u32 = 8_000;
/// The worst press in the two seconds after a keyframe shows within this (two frames; the
/// screen-share goal is 80 ms end to end).
const PRESS_BOUND_MS: f64 = 34.0;

/// A deterministic generator (an LCG), so every run codes the same pictures.
struct Lcg(u32);
impl Lcg {
    fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        self.0 >> 8
    }
}

/// One 6x10 glyph of 1-pixel strokes at (x, y): text's fine detail, as a terminal shows it.
fn glyph(pic: &mut I420, x: usize, y: usize, rng: &mut Lcg, ink: u8) {
    let bits = rng.next();
    for gy in 0..10 {
        for gx in 0..6 {
            let on = (bits >> ((gy * 3 + gx) % 24)) & 1 == 1 && (gy + gx) % 3 != 0;
            if on && y + gy < pic.height() && x + gx < pic.width {
                pic.y[(y + gy) * pic.width + x + gx] = ink;
            }
        }
    }
}

trait Height {
    fn height(&self) -> usize;
}
impl Height for I420 {
    fn height(&self) -> usize {
        self.y.len() / self.width.max(1)
    }
}

/// A full 1080p desktop of dense text in a few colored panes.
fn desktop(seed: u32) -> I420 {
    let mut pic = I420::new(W, H);
    let mut rng = Lcg(seed);
    pic.y.fill(235);
    // Panes with their own background tint (chroma) and a title bar each.
    for (i, (u, v)) in [(120u8, 136u8), (136, 120), (128, 128), (110, 140)].iter().enumerate() {
        let (x0, y0) = ((i % 2) * W / 2, (i / 2) * H / 2);
        for y in y0 / 2..(y0 + H / 2) / 2 {
            for x in x0 / 2..(x0 + W / 2) / 2 {
                pic.u[y * (W / 2) + x] = *u;
                pic.v[y * (W / 2) + x] = *v;
            }
        }
        for y in y0..y0 + 24 {
            for x in x0..x0 + W / 2 {
                pic.y[y * W + x] = 90;
            }
        }
    }
    for row in (0..H).step_by(12) {
        if row % (H / 2) < 24 {
            continue;
        }
        let len = (rng.next() % 120) as usize + 120;
        for col in 0..len.min(W / 7) {
            if !rng.next().is_multiple_of(9) {
                let x = col * 7 + 2;
                let ink = 30 + (rng.next() % 4) as u8 * 20;
                glyph(&mut pic, x, row + 1, &mut rng, ink);
                // Syntax colors: each glyph's own chroma.
                let (u, v) = (96 + (rng.next() % 64) as u8, 96 + (rng.next() % 64) as u8);
                for cy in row.div_ceil(2)..((row + 11) / 2).min(H / 2) {
                    for cx in x / 2..((x + 6) / 2).min(W / 2) {
                        pic.u[cy * (W / 2) + cx] = u;
                        pic.v[cy * (W / 2) + cx] = v;
                    }
                }
            }
        }
    }
    pic
}

fn encoder(kbps: u32) -> OpenH264 {
    let cfg = EncCfg {
        width: W as u32,
        height: H as u32,
        fps: FPS,
        kbps,
        threads: 4,
        screen_content: true,
    };
    OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder")
}

#[derive(Debug)]
#[expect(dead_code, reason = "the fields no assertion reads are printed for the report")]
struct Start {
    idr_kb: usize,
    /// The keyframe in milliseconds of the start rate.
    idr_ms: f64,
    /// Frames dropped right after the keyframe.
    skipped_after_idr: usize,
    /// From the keyframe to the next coded frame.
    first_p_ms: f64,
    /// The worst press over the first two seconds: press to the first coded frame that has it.
    worst_press_ms: f64,
    skipped_2s: usize,
    /// A keyframe the viewer asks for at 3 s (a lost reference): its size, the frames
    /// dropped right after it, and the worst press in the two seconds after it.
    forced_kb: usize,
    skipped_after_forced: usize,
    worst_press_after_forced_ms: f64,
    /// The whole 5 s run's bitrate: what dropping frames held.
    mbps: f64,
}

/// When a press at `p` first shows: the first coded frame at or after it.
fn answer_ms(coded: &[i64], p: i64) -> f64 {
    coded.iter().find(|&&t| t >= p).map_or(f64::INFINITY, |&t| (t - p) as f64 / 1e3)
}

/// A still desktop's start keyframe, then a key press every 100 ms for five seconds, and a
/// keyframe the viewer asks for at 3 s.
fn start(enc: &mut OpenH264) -> Start {
    const FORCED: i64 = 3 * FPS as i64;
    let mut pic = desktop(7);
    let mut rng = Lcg(99);
    let mut au = Vec::new();
    let mut idr_bytes = 0;
    let mut forced_bytes = 0;
    let mut total_bytes = 0;
    let mut coded = Vec::new();
    let mut presses = Vec::new();
    let mut next_press = 50_000i64;
    let mut cursor = 0usize;
    for frame in 0..5 * FPS as i64 {
        let t = frame * FRAME_US;
        while t >= next_press {
            // A typed character at the prompt line, as the rig's marker app shows one.
            glyph(&mut pic, 40 + (cursor % 200) * 8, 600 + 16 * (cursor / 200), &mut rng, 20);
            cursor += 1;
            presses.push(next_press);
            next_press += 100_000;
        }
        let idr = enc.encode(&pic, frame == 0 || frame == FORCED, t, &mut au).expect("encode");
        if frame == 0 {
            assert!(idr && !au.is_empty(), "the first frame is a keyframe");
            idr_bytes = au.len();
        }
        if frame == FORCED {
            forced_bytes = au.len();
        }
        total_bytes += au.len();
        if !au.is_empty() {
            coded.push(t);
        }
    }
    let skipped_after_idr = coded.get(1).map_or(usize::MAX, |&t| (t / FRAME_US) as usize - 1);
    let forced_at = FORCED * FRAME_US;
    let worst = |from: i64, to: i64| {
        presses
            .iter()
            .filter(|&&p| p >= from && p < to)
            .map(|&p| answer_ms(&coded, p))
            .fold(0.0, f64::max)
    };
    let after_forced = coded
        .iter()
        .find(|&&t| t > forced_at)
        .map_or(usize::MAX, |&t| ((t - forced_at) / FRAME_US) as usize - 1);
    Start {
        idr_kb: idr_bytes / 1024,
        idr_ms: idr_bytes as f64 * 8.0 / f64::from(START_KBPS),
        skipped_after_idr,
        first_p_ms: coded.get(1).map_or(f64::INFINITY, |&t| t as f64 / 1e3),
        worst_press_ms: worst(0, 2_000_000),
        skipped_2s: (2 * FPS) as usize - coded.iter().filter(|&&t| t < 2_000_000).count(),
        forced_kb: forced_bytes / 1024,
        skipped_after_forced: after_forced,
        worst_press_after_forced_ms: worst(forced_at, forced_at + 2_000_000),
        mbps: total_bytes as f64 * 8.0 / 5.0 / 1e6,
    }
}

#[derive(Debug)]
struct Steady {
    fps: f64,
    mbps: f64,
}

/// A share that starts on a still desktop at the start rate; after a second the link's rate
/// is `kbps` and pictures move for five seconds, of which the last three count. `window`
/// moves a 960x540 region only (the share stays in screen usage), else the whole desktop
/// scrolls (camera usage for the motion).
fn steady(enc: &mut OpenH264, kbps: u32, window: bool) -> Steady {
    let base = desktop(11);
    let mut au = Vec::new();
    for n in 0..FPS as i64 {
        enc.encode(&base, n == 0, n * FRAME_US, &mut au).expect("encode");
    }
    enc.set_bitrate(kbps);
    let (mut frames, mut bytes) = (0usize, 0usize);
    let total = 5 * FPS as i64;
    let mut rng = Lcg(5);
    let mut pic = base.clone();
    for n in 1..=total {
        let t = (FPS as i64 + n) * FRAME_US;
        if window {
            // A playing video in a window: new 4x4-block texture every frame.
            for by in (270..810).step_by(4) {
                for bx in (480..1440).step_by(4) {
                    let l = 16 + (rng.next() % 200) as u8;
                    for y in by..by + 4 {
                        pic.y[y * W + bx..y * W + bx + 4].fill(l);
                    }
                }
            }
        } else {
            // A scroll: the whole desktop moves up 4 rows a frame.
            let shift = (n as usize * 4) % H;
            for y in 0..H {
                let src = (y + shift) % H;
                pic.y[y * W..(y + 1) * W].copy_from_slice(&base.y[src * W..(src + 1) * W]);
            }
        }
        enc.encode(&pic, false, t, &mut au).expect("encode");
        if n > 2 * FPS as i64 && !au.is_empty() {
            frames += 1;
            bytes += au.len();
        }
    }
    let secs = (total - 2 * FPS as i64) as f64 / f64::from(FPS);
    Steady { fps: frames as f64 / secs, mbps: bytes as f64 * 8.0 / secs / 1e6 }
}

#[test]
fn a_keyframe_drops_no_frame_after_it_and_presses_show_within_two_frames() {
    let s = start(&mut encoder(START_KBPS));
    println!("start: {s:?}");
    assert_eq!(s.skipped_after_idr, 0, "frames dropped after the start keyframe: {s:?}");
    assert_eq!(s.skipped_after_forced, 0, "frames dropped after a forced keyframe: {s:?}");
    assert!(s.worst_press_ms <= PRESS_BOUND_MS, "a press after the start keyframe: {s:?}");
    assert!(
        s.worst_press_after_forced_ms <= PRESS_BOUND_MS,
        "a press after a forced keyframe: {s:?}"
    );
    // The rate still holds: the keyframes' bits are repaid within the run.
    assert!(s.mbps * 1000.0 <= f64::from(START_KBPS) / 2.0, "the run's rate: {s:?}");
}

/// Steady motion's frame rate and bitrate, for the before/after table (no bound: the
/// comparison is base against head on the same machine).
#[test]
#[ignore = "a measurement: cargo test --release -- --ignored --nocapture"]
fn steady_motion_report() {
    for kbps in [8_000, 48_000] {
        for window in [false, true] {
            let s = steady(&mut encoder(START_KBPS), kbps, window);
            println!(
                "steady {} at {kbps} kbit/s: {:.1} fps, {:.1} Mbit/s",
                if window { "window video" } else { "full scroll" },
                s.fps,
                s.mbps
            );
        }
    }
}
