//! The follow camera: a crop of one aspect (9:16, 4:5, 1:1) that follows
//! what the person on the shared screen is doing, for the iPhone
//! screen-share viewer's Follow mode and for vertical cuts of recordings.
//!
//! - Focus: the newest of the text caret and a moving pointer, else recent
//!   damage (where pixels changed) inside the focused window, else the
//!   focused window, else the screen ([`Camera::focus`]).
//! - Cut: a change of focused window (an app or window switch) or an
//!   explicit [`Signal::Cut`] snaps the crop to the new focus. Signals for
//!   [`CUT_SETTLE_US`] after a cut snap too, so the caret of the new window
//!   lands in the same shot.
//! - Dead zone: while the focus stays inside the middle [`Config::dead_zone`]
//!   of the crop's goal, the goal does not move (a locked shot).
//! - Pan: when the focus leaves the dead zone, the goal recentres on it and
//!   the crop moves there with bounded speed and acceleration
//!   ([`Config::max_speed`], [`Config::max_accel`]), braking so it stops on
//!   the goal instead of passing it.
//! - Manual: [`Camera::manual`] (a pinch or drag) holds the crop where the
//!   person put it and keeps its size; [`Camera::resume`] (a tap) pans back
//!   to the focus from there.
//!
//! - Salient: [`Signal::Salient`] regions (from [`saliency`], or faces a
//!   detector found) frame a picture with no person driving it: a wallpaper,
//!   an idle screen, a cover. They rank above the focused window and below
//!   damage; when several are live the goal is [`fit::place`]'s crop, the
//!   one function [`fit::fit`] uses too. [`dwell`] turns regions into a slow
//!   tour for a moving wallpaper.
//! - Viewport: [`Camera::set_viewport`] changes the crop's aspect and zoom
//!   live (a window resize) keeping the crop's centre; the normal pan then
//!   settles on the new goal, so no frame jumps.
//!
//! No I/O, no threads, no clock: every time is the caller's monotonic clock
//! in microseconds, and the same events give the same path at any frame
//! rate (the motion steps at [`STEP_US`]). Coordinates are the shared
//! screen's pixels, origin top left.

use std::collections::VecDeque;

use serde::{Deserialize, Serialize};

pub mod dwell;
pub mod fit;
pub mod saliency;

pub use fit::{
    Bleed, CropReport, FitOptions, Framing, Size, fit, fit_report, fit_with, place, report,
};
pub use saliency::{SaliencyMap, SaliencyOptions, saliency_luma, saliency_map, saliency_rgb};

/// The motion's fixed step: 240 Hz.
pub const STEP_US: u64 = 1_000_000 / 240;
/// After a cut, how long new focus signals still snap instead of pan.
pub const CUT_SETTLE_US: u64 = 200_000;
/// Salient regions kept for the focus (one set; the heaviest count).
const MAX_SALIENT: usize = 32;
/// Damage rects kept for the focus (newest last).
const MAX_DAMAGE: usize = 64;
/// A longer gap between two `advance` calls (a backgrounded viewer) puts
/// the crop on its goal instead of replaying every step.
const MAX_CATCH_UP_US: u64 = 10_000_000;
/// A pointer move shorter than this (pixels) is jitter, not intent.
const POINTER_MOVE_PX: f64 = 3.0;
/// Closer than this (pixels) at a speed under one step's acceleration, the
/// crop is on its goal.
const SETTLE_PX: f64 = 0.5;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }

    pub fn center(&self) -> (f64, f64) {
        (self.x + self.w / 2.0, self.y + self.h / 2.0)
    }

    fn area(&self) -> f64 {
        self.w.max(0.0) * self.h.max(0.0)
    }

    fn union(&self, other: &Rect) -> Rect {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        let r = (self.x + self.w).max(other.x + other.w);
        let b = (self.y + self.h).max(other.y + other.h);
        Rect::new(x, y, r - x, b - y)
    }

    fn intersect(&self, other: &Rect) -> Option<Rect> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let r = (self.x + self.w).min(other.x + other.w);
        let b = (self.y + self.h).min(other.y + other.h);
        (r > x && b > y).then(|| Rect::new(x, y, r - x, b - y))
    }
}

/// One focus signal from the shared screen.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Signal {
    /// The shared screen's size changed.
    Source { w: f64, h: f64 },
    /// The pointer's position.
    Pointer { x: f64, y: f64 },
    /// The text caret (insertion point) of the focused text.
    Caret { x: f64, y: f64, w: f64, h: f64 },
    /// The focused window's frame. A new `id` is a cut.
    Window { id: u64, x: f64, y: f64, w: f64, h: f64 },
    /// A region whose pixels changed.
    Damage { x: f64, y: f64, w: f64, h: f64 },
    /// A salient part of the picture (a figure, a face) with a positive
    /// weight. Regions pushed at the same time form one set; a region at a
    /// later time starts a new set (a new saliency pass, the next stop of a
    /// [`dwell`] tour). A cut clears the set.
    Salient { x: f64, y: f64, w: f64, h: f64, weight: f64 },
    /// A cut the source knows about (a scene change in a recording).
    Cut,
}

/// A signal at a time: one line of a trace file.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub t_us: u64,
    #[serde(flatten)]
    pub signal: Signal,
}

/// Reads a trace: one JSON [`Event`] per line, blank lines skipped.
pub fn read_trace(text: &str) -> Result<Vec<Event>, serde_json::Error> {
    text.lines().filter(|line| !line.trim().is_empty()).map(serde_json::from_str).collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Config {
    /// The crop's width over its height: 9/16, 4/5, 1.
    pub aspect: f64,
    /// 1 is the largest crop of `aspect` the screen holds; 2 is half that.
    pub zoom: f64,
    /// The middle share of the crop (each axis) the focus may move in
    /// without moving the camera.
    pub dead_zone: f64,
    /// The dead zone while a [`Signal::Salient`] set is the focus. A fit crop
    /// is a target to reach, not a point to keep in view, so it is far
    /// smaller than `dead_zone`: at 0.04 the crop's centre may sit 2% of the
    /// crop either side of the goal's before the camera moves. The smaller of
    /// the two applies.
    #[serde(default = "default_salient_dead_zone")]
    pub salient_dead_zone: f64,
    /// Top speed, in crop widths per second.
    pub max_speed: f64,
    /// Top acceleration, in crop widths per second squared.
    pub max_accel: f64,
    /// How long a caret or pointer move stays the focus.
    pub intent_hold_us: u64,
    /// How long damage stays the focus.
    pub damage_hold_us: u64,
    /// Damage covering more than this share of the screen (a full redraw,
    /// a scroll of everything) says nothing about where to look.
    pub damage_max_share: f64,
}

fn default_salient_dead_zone() -> f64 {
    0.04
}

impl Default for Config {
    fn default() -> Self {
        Self {
            aspect: 9.0 / 16.0,
            zoom: 1.0,
            dead_zone: 0.6,
            salient_dead_zone: default_salient_dead_zone(),
            max_speed: 3.0,
            max_accel: 12.0,
            intent_hold_us: 3_000_000,
            damage_hold_us: 800_000,
            damage_max_share: 0.4,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Follow,
    Manual,
}

#[derive(Debug, Clone, Copy, Default)]
struct Axis {
    pos: f64,
    vel: f64,
}

impl Axis {
    /// One step toward `goal`: the speed the remaining distance allows to
    /// still stop on the goal, capped at `vmax`, reached with at most
    /// `amax` of acceleration.
    fn step(&mut self, goal: f64, vmax: f64, amax: f64, dt: f64) {
        let d = goal - self.pos;
        let dv_max = amax * dt;
        if d.abs() < SETTLE_PX && self.vel.abs() <= dv_max {
            self.pos = goal;
            self.vel = 0.0;
            return;
        }
        // The fastest speed that still stops within `d` when it loses
        // `dv_max` a step: v^2 / 2a + v dt / 2 = d.
        let half = dv_max / 2.0;
        let brake = (half * half + 2.0 * amax * d.abs()).sqrt() - half;
        let want = d.signum() * vmax.min(brake);
        self.vel += (want - self.vel).clamp(-dv_max, dv_max);
        let next = self.pos + self.vel * dt;
        if (goal - next).signum() != d.signum() && self.vel.abs() <= dv_max {
            // The last, slowest step lands on the goal instead of past it.
            self.pos = goal;
            self.vel = 0.0;
        } else {
            self.pos = next;
        }
    }
}

/// The follow camera. Feed it events in time order with [`Camera::push`]
/// and read the crop at any time with [`Camera::advance`].
#[derive(Debug, Clone)]
pub struct Camera {
    config: Config,
    source: (f64, f64),
    mode: Mode,
    /// The crop size; set by `zoom`, or by the person in manual mode.
    size: (f64, f64),
    x: Axis,
    y: Axis,
    /// Where the crop's top left is going.
    goal: (f64, f64),
    now_us: u64,
    /// The motion's time: the last [`STEP_US`] grid step it ran.
    sim_us: u64,
    started: bool,
    window: Option<(u64, Rect)>,
    caret: Option<(u64, Rect)>,
    pointer: Option<(u64, f64, f64)>,
    /// When the pointer last moved more than `POINTER_MOVE_PX`.
    pointer_moved_us: Option<u64>,
    damage: VecDeque<(u64, Rect)>,
    /// The live salient set and the time it was pushed.
    salient: Vec<fit::Salient>,
    salient_us: u64,
    /// Signals up to this time snap.
    snap_until_us: Option<u64>,
    /// The best focus the shot since the last cut has framed.
    shot: Option<Rank>,
}

/// How much a focus says about where the person looks, least first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Rank {
    Window,
    Salient,
    Damage,
    Intent,
}

impl Camera {
    pub fn new(config: Config, source_w: f64, source_h: f64) -> Self {
        let mut camera = Self {
            config,
            source: (source_w, source_h),
            mode: Mode::Follow,
            size: (0.0, 0.0),
            x: Axis::default(),
            y: Axis::default(),
            goal: (0.0, 0.0),
            now_us: 0,
            sim_us: 0,
            started: false,
            window: None,
            caret: None,
            pointer: None,
            pointer_moved_us: None,
            damage: VecDeque::new(),
            salient: Vec::new(),
            salient_us: 0,
            snap_until_us: None,
            shot: None,
        };
        camera.size = camera.zoom_size(config.zoom);
        camera.center_on(source_w / 2.0, source_h / 2.0, true);
        camera
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// The crop now, without moving time.
    pub fn rect(&self) -> Rect {
        self.clamp(self.x.pos, self.y.pos)
    }

    /// The crop's size for a zoom: the largest rect of `aspect` inside the
    /// screen, divided by `zoom`.
    fn zoom_size(&self, zoom: f64) -> (f64, f64) {
        let (sw, sh) = self.source;
        let zoom = zoom.max(1.0);
        let (w, h) = if sw / sh > self.config.aspect {
            (sh * self.config.aspect, sh)
        } else {
            (sw, sw / self.config.aspect)
        };
        (w / zoom, h / zoom)
    }

    fn clamp(&self, x: f64, y: f64) -> Rect {
        let (sw, sh) = self.source;
        let (w, h) = self.size;
        Rect::new(x.clamp(0.0, (sw - w).max(0.0)), y.clamp(0.0, (sh - h).max(0.0)), w, h)
    }

    fn center_on(&mut self, cx: f64, cy: f64, snap: bool) {
        let r = self.clamp(cx - self.size.0 / 2.0, cy - self.size.1 / 2.0);
        self.goal = (r.x, r.y);
        if snap {
            self.x = Axis { pos: r.x, vel: 0.0 };
            self.y = Axis { pos: r.y, vel: 0.0 };
        }
    }

    /// Applies one event, after moving the camera up to its time. Events
    /// older than the camera's time apply at the camera's time.
    pub fn push(&mut self, event: Event) {
        self.advance(event.t_us);
        let t = self.now_us;
        match event.signal {
            Signal::Source { w, h } => {
                self.source = (w, h);
                self.size = self.zoom_size(self.config.zoom);
                self.cut(t);
            }
            Signal::Pointer { x, y } => {
                // The first position says where the pointer rests, not
                // that anyone moved it.
                match self.pointer {
                    Some((_, px, py)) if (x - px).hypot(y - py) < POINTER_MOVE_PX => {}
                    Some(_) => {
                        self.pointer = Some((t, x, y));
                        self.pointer_moved_us = Some(t);
                    }
                    None => self.pointer = Some((t, x, y)),
                }
            }
            Signal::Caret { x, y, w, h } => self.caret = Some((t, Rect::new(x, y, w, h))),
            Signal::Window { id, x, y, w, h } => {
                let switched = self.window.is_none_or(|(old, _)| old != id);
                self.window = Some((id, Rect::new(x, y, w, h)));
                if switched {
                    self.cut(t);
                }
            }
            Signal::Damage { x, y, w, h } => {
                let rect = Rect::new(x, y, w, h);
                let screen = self.source.0 * self.source.1;
                if rect.area() > 0.0 && rect.area() <= screen * self.config.damage_max_share {
                    if self.damage.len() == MAX_DAMAGE {
                        self.damage.pop_front();
                    }
                    self.damage.push_back((t, rect));
                }
            }
            Signal::Salient { x, y, w, h, weight } => {
                if self.salient_us != t {
                    self.salient.clear();
                    self.salient_us = t;
                }
                let finite = [x, y, w, h, weight].iter().all(|v| v.is_finite());
                if finite && weight > 0.0 && w >= 0.0 && h >= 0.0 {
                    if self.salient.len() == MAX_SALIENT {
                        // Keep the heaviest: drop the lightest when this one is heavier.
                        let lightest = self
                            .salient
                            .iter()
                            .enumerate()
                            .min_by(|a, b| a.1.weight.total_cmp(&b.1.weight))
                            .filter(|(_, r)| r.weight < weight)
                            .map(|(i, _)| i);
                        if let Some(i) = lightest {
                            self.salient.remove(i);
                        }
                    }
                    if self.salient.len() < MAX_SALIENT {
                        self.salient.push(fit::Salient::new(x, y, w, h, weight));
                    }
                }
            }
            Signal::Cut => self.cut(t),
        }
        self.started = true;
        self.retarget();
    }

    /// A cut: what the old shot followed no longer counts, and the next
    /// focus snaps.
    fn cut(&mut self, t: u64) {
        self.caret = None;
        self.pointer_moved_us = None;
        self.damage.clear();
        self.salient.clear();
        self.snap_until_us = Some(t + CUT_SETTLE_US);
        self.shot = None;
    }

    /// What the camera should look at now: the newest intent (caret or a
    /// moving pointer), else recent damage in the focused window, else the
    /// crop that keeps the most salient weight, else the focused window,
    /// else nothing.
    pub fn focus(&self) -> Option<Rect> {
        self.ranked_focus().map(|(_, rect)| rect)
    }

    fn ranked_focus(&self) -> Option<(Rank, Rect)> {
        let t = self.now_us;
        let hold = self.config.intent_hold_us;
        let caret = self.caret.filter(|(at, _)| t.saturating_sub(*at) <= hold);
        let pointer = self
            .pointer
            .zip(self.pointer_moved_us)
            .filter(|(_, moved)| t.saturating_sub(*moved) <= hold)
            .map(|((_, x, y), moved)| (moved, Rect::new(x, y, 0.0, 0.0)));
        let intent = match (caret, pointer) {
            (Some(c), Some(p)) => Some(if p.0 > c.0 { p.1 } else { c.1 }),
            (c, p) => c.or(p).map(|(_, r)| r),
        };
        if let Some(intent) = intent {
            return Some((Rank::Intent, intent));
        }
        let window = self.window.map(|(_, r)| r);
        let damage = self
            .damage
            .iter()
            .filter(|(at, _)| t.saturating_sub(*at) <= self.config.damage_hold_us)
            .filter_map(|(_, r)| match window {
                Some(w) => r.intersect(&w),
                None => Some(*r),
            })
            .reduce(|a, b| a.union(&b));
        damage
            .map(|r| (Rank::Damage, r))
            .or_else(|| self.salient_focus().map(|r| (Rank::Salient, r)))
            .or(window.map(|r| (Rank::Window, r)))
    }

    /// The crop of the camera's size that keeps the most salient weight
    /// ([`fit::place`], the function [`fit::fit`] uses), or none without a
    /// live salient set.
    fn salient_focus(&self) -> Option<Rect> {
        if self.salient.is_empty() {
            return None;
        }
        let source = Size::new(self.source.0, self.source.1);
        let rect = place(source, self.size, &self.salient, FitOptions::default().center_bias);
        (rect.w > 0.0 && rect.h > 0.0).then_some(rect)
    }

    /// Moves the goal when the focus has left the dead zone. Right after a
    /// cut the move is a snap, and a better focus than the shot's (the new
    /// window's caret after its frame) recentres even inside the dead zone.
    fn retarget(&mut self) {
        if self.mode == Mode::Manual {
            return;
        }
        let Some((rank, focus)) = self.ranked_focus() else { return };
        let (fx, fy) = focus.center();
        let snap = self.snap_until_us.is_some_and(|until| self.now_us <= until);
        let better = snap && self.shot.is_none_or(|shot| rank > shot);
        if snap {
            self.shot = self.shot.max(Some(rank));
        }
        if !better {
            let (w, h) = self.size;
            // A salient focus is already a whole framed crop, not a point to
            // keep in view: hold only within a small zone, so the picture
            // lands on its fit and a slightly different saliency pass does
            // not move it.
            let dead_zone = if rank == Rank::Salient {
                self.config.salient_dead_zone.min(self.config.dead_zone)
            } else {
                self.config.dead_zone
            };
            let margin_x = w * (1.0 - dead_zone) / 2.0;
            let margin_y = h * (1.0 - dead_zone) / 2.0;
            let (gx, gy) = self.goal;
            let inside = fx >= gx + margin_x
                && fx <= gx + w - margin_x
                && fy >= gy + margin_y
                && fy <= gy + h - margin_y;
            if inside {
                return;
            }
        }
        self.center_on(fx, fy, snap);
    }

    /// Moves time to `now_us` and returns the crop then.
    pub fn advance(&mut self, now_us: u64) -> Rect {
        let now_us = now_us.max(self.now_us);
        // The motion steps on a fixed grid, so where the caller samples
        // never changes the path; the crop shows the last grid step.
        let grid = now_us - now_us % STEP_US;
        if !self.started || grid.saturating_sub(self.sim_us) > MAX_CATCH_UP_US {
            self.sim_us = grid;
            self.x = Axis { pos: self.goal.0, vel: 0.0 };
            self.y = Axis { pos: self.goal.1, vel: 0.0 };
        }
        while self.sim_us < grid {
            self.sim_us += STEP_US;
            self.now_us = self.now_us.max(self.sim_us);
            // Holds expire with time: a stale caret hands the focus on.
            self.retarget();
            if self.mode == Mode::Follow {
                let dt = STEP_US as f64 / 1e6;
                let vmax = self.config.max_speed * self.size.0;
                let amax = self.config.max_accel * self.size.0;
                self.x.step(self.goal.0, vmax, amax, dt);
                self.y.step(self.goal.1, vmax, amax, dt);
            }
        }
        self.now_us = now_us;
        if self.snap_until_us.is_some_and(|until| self.now_us > until) {
            self.snap_until_us = None;
        }
        self.rect()
    }

    /// The person took the camera (a pinch or a drag): hold `rect` (its
    /// size too) until [`Camera::resume`].
    pub fn manual(&mut self, rect: Rect) {
        self.mode = Mode::Manual;
        if rect.w > 0.0 && rect.h > 0.0 {
            self.size = (rect.w.min(self.source.0), rect.h.min(self.source.1));
        }
        let r = self.clamp(rect.x, rect.y);
        self.x = Axis { pos: r.x, vel: 0.0 };
        self.y = Axis { pos: r.y, vel: 0.0 };
        self.goal = (r.x, r.y);
    }

    /// The crop's shape changed live (the window or split showing it was
    /// resized): a new `aspect` (width over height) and `zoom`. The crop keeps
    /// its centre (moved only as far as the source's edges force) and its
    /// goal's centre, then the focus retargets and the normal bounded pan
    /// settles on it, so no frame jumps. The speed is capped at the new
    /// size's top speed. An aspect that is not positive and finite is
    /// ignored; a zoom that is not finite keeps the current zoom. In manual
    /// mode the person's crop takes the new size too.
    pub fn set_viewport(&mut self, aspect: f64, zoom: f64) {
        if !(aspect.is_finite() && aspect > 0.0) {
            return;
        }
        let zoom = if zoom.is_finite() { zoom.max(1.0) } else { self.config.zoom };
        let (cx, cy) = self.rect().center();
        let (gcx, gcy) = (self.goal.0 + self.size.0 / 2.0, self.goal.1 + self.size.1 / 2.0);
        self.config.aspect = aspect;
        self.config.zoom = zoom;
        self.size = self.zoom_size(zoom);
        let (w, h) = self.size;
        let r = self.clamp(cx - w / 2.0, cy - h / 2.0);
        let vmax = self.config.max_speed * w;
        self.x = Axis { pos: r.x, vel: self.x.vel.clamp(-vmax, vmax) };
        self.y = Axis { pos: r.y, vel: self.y.vel.clamp(-vmax, vmax) };
        let g = self.clamp(gcx - w / 2.0, gcy - h / 2.0);
        self.goal = (g.x, g.y);
        if self.mode == Mode::Manual {
            self.goal = (r.x, r.y);
        }
        self.retarget();
    }

    /// Hands the camera back (a tap): pan from where the person left it to
    /// the focus, keeping their crop size.
    pub fn resume(&mut self) {
        self.mode = Mode::Follow;
        self.snap_until_us = None;
        if let Some(focus) = self.focus() {
            let (fx, fy) = focus.center();
            self.center_on(fx, fy, false);
        }
    }
}

/// One frame of a cut's camera path.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Frame {
    pub t_us: u64,
    pub rect: Rect,
}

/// The camera path over a whole trace, one frame every `1/fps` second from
/// the first event to the last: what a recording cutter crops by.
pub fn path(
    config: Config,
    source_w: f64,
    source_h: f64,
    events: &[Event],
    fps: f64,
) -> Vec<Frame> {
    let mut camera = Camera::new(config, source_w, source_h);
    let (Some(first), Some(last)) = (events.first(), events.last()) else {
        return Vec::new();
    };
    let frame_us = 1e6 / fps.max(1.0);
    let mut frames = Vec::new();
    let mut next = events.iter().peekable();
    for i in 0.. {
        let t = first.t_us + (f64::from(i) * frame_us).round() as u64;
        if t > last.t_us {
            break;
        }
        while let Some(event) = next.next_if(|e| e.t_us <= t) {
            camera.push(*event);
        }
        frames.push(Frame { t_us: t, rect: camera.advance(t) });
    }
    frames
}
