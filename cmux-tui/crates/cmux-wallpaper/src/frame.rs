//! The `Frame` uniform (`prelude.wgsl`) and the pointer's smoothing.
//!
//! Every field of `Frame` is a `vec4<f32>` (or an array of them), so the
//! layout is the same in Metal, WGSL and GLSL std140: 27 vec4s, 108 floats,
//! 432 bytes.
//!
//! | floats | field | x | y | z | w |
//! |---|---|---|---|---|---|
//! | 0..4 | time | seconds since shown | seconds since the last frame | frame number | still (0/1) |
//! | 4..8 | size | width px | height px | backing scale | seed 0..1 |
//! | 8..12 | pointer | x px | y px | velocity x px/s | velocity y px/s |
//! | 12..16 | presence | inside (eased 0..1) | seconds since it moved | button down | dark |
//! | 16..20 | ink | r | g | b | 1 |
//! | 20..24 | paper | r | g | b | 1 |
//! | 24..28 | accent | r | g | b | 1 |
//! | 28..36 | params | 8 floats in manifest order |
//! | 36..40 | activity | agent activity (eased 0..1) | seconds since the newest agent event | agent events so far (mod 1024) | 0 |
//! | 40..44 | grade | tritone amount 0..1 ([`crate::grade`]; 0 is off) | 0 | 0 | 0 |
//! | 44..108 | trail: 16 rows, newest first ([`TrailState::rows`](crate::trail::TrailState::rows)) | x px | y px | age seconds | valid (0/1) |

use crate::manifest::Manifest;
use crate::trail::TRAIL_POINTS;

/// Floats in `Frame`.
pub const FRAME_FLOATS: usize = TRAIL_START + TRAIL_POINTS * 4;
/// The first float of `Frame.trail`.
pub const TRAIL_START: usize = 44;
/// The first float of `Frame.grade`.
pub const GRADE_START: usize = 40;
/// Bytes in `Frame`.
pub const FRAME_BYTES: usize = FRAME_FLOATS * 4;
/// `presence.y` and `activity.y` never exceed this (a float stays exact).
pub const MAX_SINCE_MOVED: f32 = 1.0e4;
/// `activity.z` counts agent events modulo this, so it stays a small whole float.
pub const AGENT_EVENT_WRAP: u16 = 1024;

/// Everything a frame's uniform holds, by name. Colors are linear RGB
/// ([`srgb_to_linear`] converts a theme color).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FrameInput {
    pub time: f32,
    pub delta: f32,
    pub frame_number: f32,
    pub still: bool,
    pub width: f32,
    pub height: f32,
    pub backing_scale: f32,
    pub seed: f32,
    pub pointer_x: f32,
    pub pointer_y: f32,
    pub velocity_x: f32,
    pub velocity_y: f32,
    pub presence: f32,
    pub since_moved: f32,
    pub button_down: bool,
    pub dark: bool,
    pub ink: [f32; 3],
    pub paper: [f32; 3],
    pub accent: [f32; 3],
    pub params: [f32; 8],
    /// Agent activity, eased 0..1 ([`ActivityState::level`]).
    pub activity: f32,
    /// Seconds since the newest agent event ([`ActivityState::since_event`]).
    pub since_agent_event: f32,
    /// Agent events so far, mod [`AGENT_EVENT_WRAP`] ([`ActivityState::count`]).
    pub agent_events: f32,
    /// The tritone grade's amount, 0 (off, the default) ..1 (`appearance.liveWallpaperGrade`):
    /// `epilogue.wgsl` maps every program's color through [`crate::grade`].
    pub grade: f32,
    /// The pointer's recent path in rendered pixels, newest first
    /// ([`TrailState::rows`](crate::trail::TrailState::rows)); zeros when the host keeps none.
    pub trail: [[f32; 4]; TRAIL_POINTS],
}

fn finite(v: f32) -> f32 {
    if v.is_finite() { v } else { 0.0 }
}

fn flag(b: bool) -> f32 {
    if b { 1.0 } else { 0.0 }
}

/// The [`FRAME_FLOATS`] floats of `Frame` for `input`. A NaN or infinite input becomes 0,
/// so no frame hands the GPU a NaN.
pub fn pack_frame(input: &FrameInput) -> [f32; FRAME_FLOATS] {
    let i = input;
    let rgb1 = |c: [f32; 3]| [finite(c[0]), finite(c[1]), finite(c[2]), 1.0];
    let [ink, paper, accent] = [rgb1(i.ink), rgb1(i.paper), rgb1(i.accent)];
    let p = i.params.map(finite);
    let rows: [[f32; 4]; 11] = [
        [finite(i.time), finite(i.delta), finite(i.frame_number), flag(i.still)],
        [finite(i.width), finite(i.height), finite(i.backing_scale), finite(i.seed)],
        [finite(i.pointer_x), finite(i.pointer_y), finite(i.velocity_x), finite(i.velocity_y)],
        [
            finite(i.presence).clamp(0.0, 1.0),
            finite(i.since_moved).clamp(0.0, MAX_SINCE_MOVED),
            flag(i.button_down),
            flag(i.dark),
        ],
        ink,
        paper,
        accent,
        [p[0], p[1], p[2], p[3]],
        [p[4], p[5], p[6], p[7]],
        [
            finite(i.activity).clamp(0.0, 1.0),
            finite(i.since_agent_event).clamp(0.0, MAX_SINCE_MOVED),
            finite(i.agent_events).clamp(0.0, f32::from(AGENT_EVENT_WRAP)),
            0.0,
        ],
        [finite(i.grade).clamp(0.0, 1.0), 0.0, 0.0, 0.0],
    ];
    let trail = i.trail.iter().flatten().map(|v| finite(*v));
    let mut out = [0.0; FRAME_FLOATS];
    for (slot, v) in out.iter_mut().zip(rows.iter().flatten().copied().chain(trail)) {
        *slot = v;
    }
    out
}

/// One sRGB channel (0..1) in linear light.
pub fn srgb_to_linear(c: f32) -> f32 {
    let c = finite(c).clamp(0.0, 1.0);
    if c <= 0.040_45 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

impl FrameInput {
    /// A still of `manifest` at its `still` time and pointer, `width` x
    /// `height` rendered pixels. The caller sets colors, params and seed.
    pub fn still(manifest: &Manifest, width: f32, height: f32, backing_scale: f32) -> Self {
        Self {
            time: manifest.still.time,
            delta: 0.0,
            frame_number: 0.0,
            still: true,
            width,
            height,
            backing_scale,
            pointer_x: manifest.still.pointer[0] * width,
            pointer_y: manifest.still.pointer[1] * height,
            presence: 1.0,
            since_moved: 10.0,
            ..Self::default()
        }
    }
}

/// Velocity samples blend in with this weight (the gallery's 0.35).
const VELOCITY_BLEND: f32 = 0.35;
/// A pointer sample after a longer gap starts the velocity over.
const VELOCITY_GAP_S: f64 = 0.25;
/// Velocity decays at this rate (1/s) while the pointer is still.
const VELOCITY_DECAY: f32 = 4.0;
/// Presence eases toward inside/outside at this rate (1/s).
const PRESENCE_RATE: f32 = 6.0;
/// Below this speed (px/s) the velocity is 0.
const VELOCITY_REST: f32 = 0.5;
/// Within this of its target the presence snaps to it.
const PRESENCE_REST: f32 = 1.0e-3;

/// The pointer as the program sees it: position, smoothed velocity and
/// eased presence. Times are the host's monotonic clock in seconds.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PointerState {
    /// Backing pixels, top left origin.
    pub x: f32,
    pub y: f32,
    /// Backing pixels per second, smoothed.
    pub vx: f32,
    pub vy: f32,
    /// 0 outside .. 1 inside, eased.
    pub presence: f32,
    /// Whether the pointer is over the window (presence's target).
    pub inside: bool,
    /// When the last position sample came; meaningless until `has_sample`.
    pub last_sample: f64,
    /// When `advance` last ran.
    pub last_advance: f64,
    pub has_sample: bool,
}

impl PointerState {
    /// A pointer move to `(x, y)` at time `t`: the velocity takes the new
    /// sample in, and presence heads to 1.
    pub fn moved(&mut self, x: f32, y: f32, t: f64) {
        if !x.is_finite() || !y.is_finite() || !t.is_finite() {
            return;
        }
        if self.has_sample {
            let gap = t - self.last_sample;
            if gap > 0.0 && gap < VELOCITY_GAP_S {
                #[allow(
                    clippy::cast_possible_truncation,
                    reason = "gap is under VELOCITY_GAP_S seconds, well inside f32"
                )]
                let dt = gap.max(1.0 / 240.0) as f32;
                self.vx += ((x - self.x) / dt - self.vx) * VELOCITY_BLEND;
                self.vy += ((y - self.y) / dt - self.vy) * VELOCITY_BLEND;
            }
        } else {
            self.last_advance = t;
        }
        self.x = x;
        self.y = y;
        self.last_sample = t;
        self.has_sample = true;
        self.inside = true;
    }

    /// The pointer left the window: presence heads to 0.
    pub fn left(&mut self) {
        self.inside = false;
    }

    /// Steps the easing to time `t` (once per drawn frame): presence toward
    /// its target, velocity toward 0 while no sample comes.
    pub fn advance(&mut self, t: f64) {
        if !t.is_finite() {
            return;
        }
        #[allow(
            clippy::cast_possible_truncation,
            reason = "a frame interval in seconds; f32 keeps it to well under a microsecond"
        )]
        let dt = (t - self.last_advance).max(0.0) as f32;
        self.last_advance = t;
        let target = if self.inside { 1.0 } else { 0.0 };
        self.presence += (target - self.presence) * (1.0 - (-PRESENCE_RATE * dt).exp());
        if (self.presence - target).abs() < PRESENCE_REST || !self.presence.is_finite() {
            self.presence = target;
        }
        let decay = (-VELOCITY_DECAY * dt).exp();
        self.vx *= decay;
        self.vy *= decay;
        if self.vx.hypot(self.vy) < VELOCITY_REST || !self.vx.is_finite() || !self.vy.is_finite() {
            self.vx = 0.0;
            self.vy = 0.0;
        }
    }

    /// Seconds since the last move, capped at [`MAX_SINCE_MOVED`] (the cap
    /// when there has been none).
    pub fn since_moved(&self, t: f64) -> f32 {
        if !self.has_sample {
            return MAX_SINCE_MOVED;
        }
        #[allow(
            clippy::cast_possible_truncation,
            reason = "clamped to 0..MAX_SINCE_MOVED, an f32 value"
        )]
        let s = (t - self.last_sample).clamp(0.0, f64::from(MAX_SINCE_MOVED)) as f32;
        s
    }

    /// True when nothing is easing: presence is at its target and the
    /// velocity is 0. The pointer then needs no frames of its own.
    pub fn settled(&self) -> bool {
        let target = if self.inside { 1.0 } else { 0.0 };
        self.presence == target && self.vx == 0.0 && self.vy == 0.0
    }
}

/// Events closer than this to the last counted one raise the level but are
/// not counted: a burst of output is one event to the program, not many.
pub const AGENT_EVENT_GAP_S: f64 = 0.4;
/// Each counted event moves the level this share of the way to 1.
const ACTIVITY_STEP: f32 = 0.3;
/// An uncounted event in a burst moves it this share.
const ACTIVITY_BURST_STEP: f32 = 0.05;
/// The level decays at this rate (1/s).
const ACTIVITY_DECAY: f32 = 0.35;
/// Below this the level is 0.
const ACTIVITY_REST: f32 = 1.0e-3;
/// A counted event needs frames this long (its flash) even after the level rests.
pub const AGENT_EVENT_SHOWN_S: f64 = 4.0;

/// The agents' activity as a program sees it (`Frame.activity`): an eased
/// level, the newest event's time and a count. The host calls `event` when
/// an agent in the window writes output or changes state, and `advance` once
/// per drawn frame. Times are the host's monotonic clock in seconds.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ActivityState {
    /// 0 none .. 1 busy, eased.
    pub level: f32,
    /// Counted events so far, mod [`AGENT_EVENT_WRAP`].
    pub count: u16,
    /// When the newest counted event came; meaningless until `has_event`.
    pub last_event: f64,
    /// When `advance` last ran.
    pub last_advance: f64,
    pub has_event: bool,
}

impl ActivityState {
    /// An agent event at time `t`.
    pub fn event(&mut self, t: f64) {
        if !t.is_finite() {
            return;
        }
        if self.has_event && t - self.last_event < AGENT_EVENT_GAP_S {
            self.level += (1.0 - self.level) * ACTIVITY_BURST_STEP;
            return;
        }
        if !self.has_event {
            self.last_advance = t;
        }
        self.level += (1.0 - self.level) * ACTIVITY_STEP;
        self.count = (self.count + 1) % AGENT_EVENT_WRAP;
        self.last_event = t;
        self.has_event = true;
    }

    /// Steps the decay to time `t` (once per drawn frame).
    pub fn advance(&mut self, t: f64) {
        if !t.is_finite() {
            return;
        }
        #[allow(
            clippy::cast_possible_truncation,
            reason = "a frame interval in seconds; f32 keeps it to well under a microsecond"
        )]
        let dt = (t - self.last_advance).max(0.0) as f32;
        self.last_advance = t;
        self.level *= (-ACTIVITY_DECAY * dt).exp();
        if self.level < ACTIVITY_REST || !self.level.is_finite() {
            self.level = 0.0;
        }
    }

    /// Seconds since the newest counted event, capped at [`MAX_SINCE_MOVED`]
    /// (the cap when there has been none).
    pub fn since_event(&self, t: f64) -> f32 {
        if !self.has_event {
            return MAX_SINCE_MOVED;
        }
        #[allow(
            clippy::cast_possible_truncation,
            reason = "clamped to 0..MAX_SINCE_MOVED, an f32 value"
        )]
        let s = (t - self.last_event).clamp(0.0, f64::from(MAX_SINCE_MOVED)) as f32;
        s
    }

    /// True when the activity needs no frames of its own at time `t`: the
    /// level rests at 0 and the newest event's flash is over.
    pub fn settled(&self, t: f64) -> bool {
        self.level == 0.0 && f64::from(self.since_event(t)) >= AGENT_EVENT_SHOWN_S
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PRELUDE: &str = include_str!("prelude.wgsl");

    #[test]
    fn the_layout_matches_the_prelude() {
        // The struct's fields, in order, as the prelude declares them.
        let body = PRELUDE.split("struct Frame {").nth(1).unwrap().split('}').next().unwrap();
        let fields: Vec<String> = body
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(|l| l.trim_end_matches(',').replace(' ', ""))
            .collect();
        assert_eq!(
            fields,
            [
                "time:vec4<f32>",
                "size:vec4<f32>",
                "pointer:vec4<f32>",
                "presence:vec4<f32>",
                "ink:vec4<f32>",
                "paper:vec4<f32>",
                "accent:vec4<f32>",
                "params:array<vec4<f32>,2>",
                "activity:vec4<f32>",
                "grade:vec4<f32>",
                "trail:array<vec4<f32>,16>",
            ]
        );
        assert_eq!(FRAME_FLOATS, 108);
        assert_eq!(FRAME_BYTES, 432);
    }

    #[cfg(feature = "compile")]
    #[test]
    fn layout_by_naga_is_432_bytes() {
        let module = naga::front::wgsl::parse_str(PRELUDE).unwrap();
        let mut layouter = naga::proc::Layouter::default();
        layouter.update(module.to_ctx()).unwrap();
        let (handle, _) =
            module.types.iter().find(|(_, t)| t.name.as_deref() == Some("Frame")).unwrap();
        assert_eq!(layouter[handle].size, 432);
    }

    #[test]
    fn packs_every_field_in_place() {
        let input = FrameInput {
            time: 1.0,
            delta: 2.0,
            frame_number: 3.0,
            still: true,
            width: 5.0,
            height: 6.0,
            backing_scale: 7.0,
            seed: 0.5,
            pointer_x: 9.0,
            pointer_y: 10.0,
            velocity_x: 11.0,
            velocity_y: 12.0,
            presence: 0.25,
            since_moved: 14.0,
            button_down: true,
            dark: false,
            ink: [0.1, 0.2, 0.3],
            paper: [0.4, 0.5, 0.6],
            accent: [0.7, 0.8, 0.9],
            params: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0],
            activity: 0.75,
            since_agent_event: 1.5,
            agent_events: 3.0,
            grade: 0.6,
            trail: std::array::from_fn(|r| {
                let r = f32::from(u8::try_from(r).unwrap());
                [100.0 + r, 200.0 + r, r * 0.05, 1.0]
            }),
        };
        let f = pack_frame(&input);
        assert_eq!(&f[0..4], &[1.0, 2.0, 3.0, 1.0]);
        assert_eq!(&f[4..8], &[5.0, 6.0, 7.0, 0.5]);
        assert_eq!(&f[8..12], &[9.0, 10.0, 11.0, 12.0]);
        assert_eq!(&f[12..16], &[0.25, 14.0, 1.0, 0.0]);
        assert_eq!(&f[16..20], &[0.1, 0.2, 0.3, 1.0]);
        assert_eq!(&f[20..24], &[0.4, 0.5, 0.6, 1.0]);
        assert_eq!(&f[24..28], &[0.7, 0.8, 0.9, 1.0]);
        assert_eq!(&f[28..36], &[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]);
        assert_eq!(&f[36..40], &[0.75, 1.5, 3.0, 0.0]);
        assert_eq!(&f[40..44], &[0.6, 0.0, 0.0, 0.0]);
        assert_eq!(&f[44..48], &[100.0, 200.0, 0.0, 1.0]);
        assert_eq!(&f[104..108], &[115.0, 215.0, 0.75, 1.0]);
        // No grade and no trail from the host: those rows are zeros.
        assert!(pack_frame(&FrameInput::default())[40..].iter().all(|v| *v == 0.0));
    }

    #[test]
    fn nan_never_reaches_the_gpu() {
        let input = FrameInput {
            time: f32::NAN,
            presence: f32::INFINITY,
            ink: [f32::NAN; 3],
            grade: f32::NAN,
            trail: [[f32::NAN, f32::INFINITY, 0.0, 1.0]; TRAIL_POINTS],
            ..Default::default()
        };
        assert!(pack_frame(&input).iter().all(|v| v.is_finite()));
    }

    #[test]
    fn the_grade_amount_is_clamped() {
        let at = |grade| pack_frame(&FrameInput { grade, ..Default::default() })[GRADE_START];
        assert_eq!(at(-1.0), 0.0);
        assert_eq!(at(0.25), 0.25);
        assert_eq!(at(7.0), 1.0);
        assert_eq!(at(f32::INFINITY), 0.0);
    }

    #[test]
    fn srgb_matches_the_standard() {
        assert_eq!(srgb_to_linear(0.0), 0.0);
        assert!((srgb_to_linear(1.0) - 1.0).abs() < 1e-6);
        assert!((srgb_to_linear(0.5) - 0.214_041).abs() < 1e-4);
    }

    #[test]
    fn a_burst_of_agent_output_counts_once_and_the_level_settles() {
        let mut a = ActivityState::default();
        assert!(a.settled(0.0));
        assert_eq!(a.since_event(5.0), MAX_SINCE_MOVED);
        a.event(10.0);
        // Twenty chunks of output within the gap: one counted event.
        for i in 1..20 {
            a.event(10.0 + f64::from(i) * 0.01);
        }
        assert_eq!(a.count, 1);
        assert!(a.level > 0.3 && a.level < 1.0, "{}", a.level);
        assert!(!a.settled(10.5));
        a.event(11.0);
        assert_eq!(a.count, 2);
        assert_eq!(a.since_event(11.5), 0.5);
        a.advance(11.0);
        a.advance(40.0);
        assert_eq!(a.level, 0.0);
        assert!(a.settled(40.0));
    }

    #[test]
    fn the_agent_event_count_wraps() {
        let mut a = ActivityState::default();
        for i in 0..u32::from(AGENT_EVENT_WRAP) + 3 {
            a.event(f64::from(i));
        }
        assert_eq!(a.count, 3);
    }

    #[test]
    fn velocity_follows_motion_and_decays() {
        let mut p = PointerState::default();
        p.moved(0.0, 0.0, 0.0);
        assert_eq!((p.vx, p.vy), (0.0, 0.0));
        for i in 1..=20 {
            p.moved(f32::from(u8::try_from(i).unwrap()) * 10.0, 0.0, f64::from(i) / 60.0);
        }
        // 10 px per 1/60 s = 600 px/s.
        assert!((p.vx - 600.0).abs() < 5.0, "{}", p.vx);
        p.advance(20.0 / 60.0);
        p.advance(3.0);
        assert_eq!((p.vx, p.vy), (0.0, 0.0));
    }

    #[test]
    fn a_long_gap_does_not_make_a_jump() {
        let mut p = PointerState::default();
        p.moved(0.0, 0.0, 0.0);
        p.moved(500.0, 0.0, 5.0);
        assert_eq!(p.vx, 0.0);
    }

    #[test]
    fn presence_eases_in_and_out() {
        let mut p = PointerState::default();
        p.advance(0.0);
        p.moved(1.0, 1.0, 0.0);
        p.advance(0.05);
        assert!(p.presence > 0.0 && p.presence < 1.0);
        assert!(!p.settled());
        p.advance(3.0);
        assert_eq!(p.presence, 1.0);
        assert!(p.settled());
        p.left();
        p.advance(3.1);
        assert!(p.presence < 1.0);
        p.advance(6.0);
        assert_eq!(p.presence, 0.0);
        assert_eq!(p.since_moved(6.0), 6.0);
        assert_eq!(PointerState::default().since_moved(1.0), MAX_SINCE_MOVED);
    }

    #[test]
    fn bad_times_are_ignored() {
        let mut p = PointerState::default();
        p.moved(f32::NAN, 0.0, 0.0);
        p.moved(0.0, 0.0, f64::NAN);
        p.advance(f64::INFINITY);
        assert_eq!(p, PointerState::default());
    }
}
