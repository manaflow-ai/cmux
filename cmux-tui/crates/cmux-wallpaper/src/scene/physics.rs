//! A scene's physics (plans/cmux-next/motion-scenes.md, "Physics"): 2D rigid
//! boxes on position-based ropes, stepped at a fixed 1/60 s and blended
//! between the last two steps for each drawn frame; a press drags a body; the
//! world sleeps when everything rests, and then costs nothing.
//!
//! Inside, lengths are in shorter sides `S` of the backdrop, so the motion is
//! the same at any resolution; places written as fractions of the backdrop
//! (`at`, `anchor`) are converted with its current size on every step, so an
//! anchor follows a resize. Bodies are integrated as position-based rigid
//! bodies (Müller et al., "Detailed Rigid Body Simulation with Extended
//! Position Based Dynamics", 2020): predict, project constraints, derive the
//! velocities from the moved positions. Rope segments are rope joints (they
//! hold a maximum length, as in the hanging-badge demo Leo pointed at), with a tether from the anchor
//! to every point so a heavy card does not stretch a light rope. Rotation is
//! in radians from +x toward +y (clockwise on screen, y down).

use crate::manifest::{ManifestErrorKind, Result, err, number, required, string};
use crate::scene::value::{ColorSpec, Paint, opt, strict};
use serde_json::Value;

/// The fixed step, seconds.
pub const STEP_S: f64 = 1.0 / 60.0;
/// At most this many bodies.
pub const MAX_BODIES: usize = 2;
/// At most this many ropes.
pub const MAX_ROPES: usize = 2;
/// At most this many segments in one rope (its points are one more).
pub const MAX_ROPE_SEGMENTS: usize = 7;

/// At most this many steps in one `advance`; a longer gap drops its backlog.
const MAX_CATCH_UP: u32 = 8;
/// Constraint passes per step.
const ITERATIONS: usize = 12;
/// Below this speed (shorter sides per second) a body or rope point rests.
const REST_SPEED: f32 = 0.005;
/// Below this spin (radians per second, rotation and twist) a body rests.
const REST_SPIN: f32 = 0.02;
/// Everything must rest this long before the world sleeps.
const REST_HOLD_S: f32 = 0.5;
/// A rope point's inverse mass (a body of mass 1 has 1): the rope is light.
const ROPE_POINT_INV_MASS: f32 = 20.0;
/// The share of a free rope point's velocity kept each step.
const ROPE_KEEP_PER_STEP: f32 = 0.98;
/// The share of the gap between grab point and pointer closed each step.
const DRAG_PULL_PER_STEP: f32 = 0.2;
/// The share of a held body's velocity kept each step (keeps the drag from ringing).
const DRAG_KEEP_PER_STEP: f32 = 0.75;
/// Twist: stiffness, damping (per s) and drive from horizontal speed and spin.
const TWIST_STIFFNESS: f32 = 24.0;
const TWIST_DAMPING: f32 = 3.0;
const TWIST_FROM_VX: f32 = 30.0;
const TWIST_FROM_SPIN: f32 = 1.5;
/// The narrowest a twisted body is drawn.
const MIN_SQUASH: f32 = 0.15;
/// A body is kept within this many shorter sides of the backdrop.
const BOUNDS_MARGIN: f32 = 2.0;

/// A body as written. Positions are fractions of the backdrop, sizes and
/// lengths fractions of its shorter side.
#[derive(Clone, Debug, PartialEq)]
pub struct BodySpec {
    pub id: String,
    pub at: [f32; 2],
    pub size: [f32; 2],
    pub mass: f32,
    pub draggable: bool,
    /// 0..1: the share of velocity lost per second.
    pub damping: f32,
}

/// A rope as written.
#[derive(Clone, Debug, PartialEq)]
pub struct RopeSpec {
    pub id: String,
    /// Where its first end is pinned, a fraction of the backdrop.
    pub anchor: [f32; 2],
    /// The body its last end holds (an index into `bodies`), if any.
    pub to: Option<usize>,
    /// Where on that body, in fractions of its size from its center.
    pub to_at: [f32; 2],
    pub length: f32,
    pub segments: usize,
    pub width: f32,
    pub color: ColorSpec,
}

/// `"physics"` as written.
#[derive(Clone, Debug, PartialEq)]
pub struct WorldSpec {
    /// Shorter sides per second squared.
    pub gravity: [f32; 2],
    pub bodies: Vec<BodySpec>,
    pub ropes: Vec<RopeSpec>,
}

impl WorldSpec {
    /// Index of the body named `id`.
    pub fn body_index(&self, id: &str) -> Option<usize> {
        self.bodies.iter().position(|b| b.id == id)
    }
}

/// `[x, y]` with each number within `min..=max`.
fn pair(v: &Value, at: &str, min: f64, max: f64) -> Result<[f32; 2]> {
    let a = v
        .as_array()
        .filter(|a| a.len() == 2)
        .ok_or_else(|| err(ManifestErrorKind::WrongType, at, "must be [x, y]"))?;
    let mut p = [0.0; 2];
    for (i, (slot, n)) in p.iter_mut().zip(a).enumerate() {
        *slot = number(n, &format!("{at}/{i}"), min, max)?;
    }
    Ok(p)
}

/// `o[key]` as an array of at most `max` items (empty when absent).
fn items<'a>(
    o: &'a serde_json::Map<String, Value>,
    at: &str,
    key: &str,
    max: usize,
) -> Result<&'a [Value]> {
    let Some(v) = o.get(key) else { return Ok(&[]) };
    let p = format!("{at}/{key}");
    let a = v
        .as_array()
        .ok_or_else(|| err(ManifestErrorKind::WrongType, p.as_str(), "must be an array"))?;
    if a.len() > max {
        return Err(err(ManifestErrorKind::OutOfRange, p, format!("at most {max}")));
    }
    Ok(a)
}

fn bool_at(v: &Value, at: &str) -> Result<bool> {
    v.as_bool().ok_or_else(|| err(ManifestErrorKind::WrongType, at, "must be true or false"))
}

/// A unique id at `{at}/id`.
fn id_at(o: &serde_json::Map<String, Value>, at: &str, seen: &[&str]) -> Result<String> {
    let p = format!("{at}/id");
    let id = string(required(o, at, "id")?, &p, 32)?;
    if seen.contains(&id.as_str()) {
        return Err(err(ManifestErrorKind::Duplicate, p, format!("id {id:?} is used twice")));
    }
    Ok(id)
}

/// Places run a little past the backdrop.
const PLACE: (f64, f64) = (-2.0, 3.0);

/// Parses `"physics"` at JSON pointer `at`.
pub fn parse(v: &Value, at: &str) -> Result<WorldSpec> {
    let o = strict(v, at, &["gravity", "bodies", "ropes"])?;
    let gravity = opt(o, at, "gravity", [0.0, 2.4], |v, a| pair(v, a, -50.0, 50.0))?;

    let mut bodies: Vec<BodySpec> = Vec::new();
    for (i, b) in items(o, at, "bodies", MAX_BODIES)?.iter().enumerate() {
        let p = format!("{at}/bodies/{i}");
        let bo = strict(b, &p, &["id", "at", "size", "mass", "draggable", "damping"])?;
        let seen: Vec<&str> = bodies.iter().map(|b| b.id.as_str()).collect();
        let id = id_at(bo, &p, &seen)?;
        bodies.push(BodySpec {
            id,
            at: pair(required(bo, &p, "at")?, &format!("{p}/at"), PLACE.0, PLACE.1)?,
            size: pair(required(bo, &p, "size")?, &format!("{p}/size"), 0.005, 2.0)?,
            mass: opt(bo, &p, "mass", 1.0, |v, a| number(v, a, 0.01, 1000.0))?,
            draggable: opt(bo, &p, "draggable", false, bool_at)?,
            damping: opt(bo, &p, "damping", 0.4, |v, a| number(v, a, 0.0, 1.0))?,
        });
    }

    let mut ropes: Vec<RopeSpec> = Vec::new();
    for (i, r) in items(o, at, "ropes", MAX_ROPES)?.iter().enumerate() {
        let p = format!("{at}/ropes/{i}");
        let ro =
            strict(r, &p, &["id", "anchor", "to", "toAt", "length", "segments", "width", "color"])?;
        let seen: Vec<&str> = ropes.iter().map(|r| r.id.as_str()).collect();
        let id = id_at(ro, &p, &seen)?;
        let to = match ro.get("to") {
            None => None,
            Some(t) => {
                let tp = format!("{p}/to");
                let name = t.as_str().ok_or_else(|| {
                    err(ManifestErrorKind::WrongType, tp.as_str(), "must be a body id")
                })?;
                let index = bodies.iter().position(|b| b.id == name).ok_or_else(|| {
                    err(ManifestErrorKind::BadFormat, tp, format!("no body {name:?}"))
                })?;
                Some(index)
            }
        };
        let segments = opt(ro, &p, "segments", 6, |v, a| {
            v.as_u64()
                .and_then(|n| usize::try_from(n).ok())
                .filter(|n| (1..=MAX_ROPE_SEGMENTS).contains(n))
                .ok_or_else(|| {
                    err(
                        ManifestErrorKind::OutOfRange,
                        a,
                        format!("must be a whole number from 1 to {MAX_ROPE_SEGMENTS}"),
                    )
                })
        })?;
        ropes.push(RopeSpec {
            id,
            anchor: pair(required(ro, &p, "anchor")?, &format!("{p}/anchor"), PLACE.0, PLACE.1)?,
            to,
            to_at: opt(ro, &p, "toAt", [0.0, 0.0], |v, a| pair(v, a, -1.0, 1.0))?,
            length: number(required(ro, &p, "length")?, &format!("{p}/length"), 0.01, 4.0)?,
            segments,
            width: opt(ro, &p, "width", 0.01, |v, a| number(v, a, 0.0, 0.2))?,
            color: opt(
                ro,
                &p,
                "color",
                ColorSpec { a: Paint::Ink, b: Paint::Ink, mix: 0.0 },
                ColorSpec::parse,
            )?,
        });
    }
    Ok(WorldSpec { gravity, bodies, ropes })
}

/// A body's place in a drawn frame, in rendered pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Pose {
    pub x: f32,
    pub y: f32,
    pub rotation: f32,
    /// The twist about the vertical axis as a horizontal squash, 0..1 (1 = facing).
    pub squash: f32,
    pub half_w: f32,
    pub half_h: f32,
}

type V2 = [f32; 2];

fn add(a: V2, b: V2) -> V2 {
    [a[0] + b[0], a[1] + b[1]]
}
fn sub(a: V2, b: V2) -> V2 {
    [a[0] - b[0], a[1] - b[1]]
}
fn scale(a: V2, k: f32) -> V2 {
    [a[0] * k, a[1] * k]
}
fn len(a: V2) -> f32 {
    a[0].hypot(a[1])
}
fn cross(a: V2, b: V2) -> f32 {
    a[0] * b[1] - a[1] * b[0]
}
fn rotate(v: V2, angle: f32) -> V2 {
    let (s, c) = angle.sin_cos();
    [v[0] * c - v[1] * s, v[0] * s + v[1] * c]
}
fn mix(a: f32, b: f32, f: f32) -> f32 {
    a + (b - a) * f
}
fn mix2(a: V2, b: V2, f: f32) -> V2 {
    [mix(a[0], b[0], f), mix(a[1], b[1], f)]
}
fn finite2(a: V2) -> bool {
    a[0].is_finite() && a[1].is_finite()
}
fn get(v: &[V2], i: usize) -> V2 {
    v.get(i).copied().unwrap_or_default()
}
fn put(v: &mut [V2], i: usize, p: V2) {
    if let Some(s) = v.get_mut(i) {
        *s = p;
    }
}

/// A body's place at one step: what frames blend.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Snap {
    p: V2,
    angle: f32,
    twist: f32,
}

#[derive(Clone, Debug)]
struct Body {
    p: V2,
    angle: f32,
    v: V2,
    spin: f32,
    twist: f32,
    twist_v: f32,
    inv_mass: f32,
    inv_inertia: f32,
    half: V2,
    /// The share of velocity kept per second.
    keep: f32,
    draggable: bool,
    prev: Snap,
}

impl Body {
    fn snap(&self) -> Snap {
        Snap { p: self.p, angle: self.angle, twist: self.twist }
    }

    /// `local` (body frame, shorter sides) in the world.
    fn world_point(&self, local: V2) -> V2 {
        add(self.p, rotate(local, self.angle))
    }

    /// `p` in the body frame.
    fn local_point(&self, p: V2) -> V2 {
        rotate(sub(p, self.p), -self.angle)
    }

    fn contains(&self, p: V2, margin: f32) -> bool {
        let l = self.local_point(p);
        l[0].abs() <= self.half[0] + margin && l[1].abs() <= self.half[1] + margin
    }

    /// Moves the point at offset `r` from the center by `-n * lambda` (the
    /// positional impulse of a constraint along unit `n`), turning the body.
    fn push(&mut self, r: V2, n: V2, lambda: f32) {
        self.p = sub(self.p, scale(n, lambda * self.inv_mass));
        self.angle -= cross(r, n) * lambda * self.inv_inertia;
    }

    /// The generalized inverse mass at offset `r` along `n`.
    fn inv_mass_at(&self, r: V2, n: V2) -> f32 {
        let rn = cross(r, n);
        self.inv_mass + rn * rn * self.inv_inertia
    }
}

#[derive(Clone, Debug)]
struct Rope {
    /// Points, first (anchor) to last, shorter sides.
    pts: Vec<V2>,
    /// Their places one step ago (Verlet velocity).
    old: Vec<V2>,
    /// Their places at the previous step, for blending.
    prev: Vec<V2>,
    seg: f32,
    body: Option<usize>,
    /// The attach point in the body frame, shorter sides.
    attach: V2,
    anchor: V2,
}

#[derive(Clone, Copy, Debug)]
struct Grab {
    body: usize,
    local: V2,
}

/// The running world.
#[derive(Clone, Debug)]
pub struct World {
    spec: WorldSpec,
    bodies: Vec<Body>,
    ropes: Vec<Rope>,
    /// Backdrop size, rendered pixels.
    size: V2,
    started: bool,
    last_now: Option<f64>,
    acc: f64,
    alpha: f32,
    asleep: bool,
    rest_s: f32,
    button: bool,
    target: Option<V2>,
    held: Option<Grab>,
    /// Steps taken, for tests and benches.
    steps: u64,
}

impl World {
    pub fn new(spec: &WorldSpec) -> Self {
        let mut w = Self {
            spec: spec.clone(),
            bodies: Vec::with_capacity(spec.bodies.len()),
            ropes: Vec::with_capacity(spec.ropes.len()),
            size: [1.0, 1.0],
            started: false,
            last_now: None,
            acc: 0.0,
            alpha: 0.0,
            asleep: false,
            rest_s: 0.0,
            button: false,
            target: None,
            held: None,
            steps: 0,
        };
        w.layout();
        w
    }

    fn shorter(&self) -> f32 {
        self.size[0].min(self.size[1])
    }

    /// A fraction of the backdrop in shorter sides.
    fn place(&self, f: V2) -> V2 {
        let s = self.shorter();
        [f[0] * self.size[0] / s, f[1] * self.size[1] / s]
    }

    /// Puts everything where the spec writes it, at rest.
    fn layout(&mut self) {
        self.bodies.clear();
        for b in &self.spec.bodies {
            let p = self.place(b.at);
            let mass = b.mass.max(0.01);
            let (w, h) = (b.size[0], b.size[1]);
            let inertia = (mass * (w * w + h * h) / 12.0).max(1e-6);
            let body = Body {
                p,
                angle: 0.0,
                v: [0.0; 2],
                spin: 0.0,
                twist: 0.0,
                twist_v: 0.0,
                inv_mass: 1.0 / mass,
                inv_inertia: 1.0 / inertia,
                half: [w * 0.5, h * 0.5],
                keep: (1.0 - b.damping).clamp(0.0, 1.0),
                draggable: b.draggable,
                prev: Snap { p, angle: 0.0, twist: 0.0 },
            };
            self.bodies.push(body);
        }
        self.ropes.clear();
        for r in &self.spec.ropes {
            let n = r.segments.clamp(1, MAX_ROPE_SEGMENTS);
            let anchor = self.place(r.anchor);
            let body = r.to.filter(|&i| i < self.bodies.len());
            let attach = body
                .and_then(|i| self.spec.bodies.get(i))
                .map_or([0.0; 2], |b| [r.to_at[0] * b.size[0], r.to_at[1] * b.size[1]]);
            let seg = r.length.max(1e-4) / n as f32;
            // Lay the rope straight toward its body, or straight down.
            let end = body.and_then(|i| self.bodies.get(i)).map(|b| b.world_point(attach));
            let (dir, step) = match end {
                Some(e) if len(sub(e, anchor)) > 1e-6 => {
                    let d = sub(e, anchor);
                    let l = len(d);
                    (scale(d, 1.0 / l), (l / n as f32).min(seg))
                }
                _ => ([0.0, 1.0], seg),
            };
            let pts: Vec<V2> = (0..=n).map(|k| add(anchor, scale(dir, step * k as f32))).collect();
            let mut rope =
                Rope { old: pts.clone(), prev: pts.clone(), pts, seg, body, attach, anchor };
            if let Some(e) = end {
                put(&mut rope.pts, n, e);
                put(&mut rope.old, n, e);
                put(&mut rope.prev, n, e);
            }
            self.ropes.push(rope);
        }
        self.acc = 0.0;
        self.alpha = 0.0;
        self.rest_s = 0.0;
        self.held = None;
    }

    /// The draggable body under `p` (topmost: the last written) and the local point.
    fn hit(&self, p: V2, margin: f32) -> Option<Grab> {
        self.bodies
            .iter()
            .enumerate()
            .rev()
            .find(|(_, b)| b.draggable && b.contains(p, margin))
            .map(|(i, b)| Grab { body: i, local: b.local_point(p) })
    }

    /// Steps the world to `now` (seconds, the host's clock since shown) at the
    /// fixed step, for a backdrop of `width` x `height` rendered pixels, with
    /// the pointer at `pointer` (rendered pixels) and the button down or up.
    /// Asleep, it only checks whether the pointer wakes it.
    pub fn advance(&mut self, now: f64, width: f32, height: f32, pointer: [f32; 2], button: bool) {
        let size = [
            if width.is_finite() && width >= 1.0 { width } else { 1.0 },
            if height.is_finite() && height >= 1.0 { height } else { 1.0 },
        ];
        let resized = size != self.size;
        self.size = size;
        let s = self.shorter();
        let ptr = finite2(pointer).then(|| scale(pointer, 1.0 / s));
        let pressed = button && !self.button;
        self.button = button;

        if !self.started {
            self.started = true;
            self.layout();
            self.last_now = now.is_finite().then_some(now);
            self.asleep = false;
        } else if self.asleep {
            // O(bodies): a resize or a press on a draggable body. A pointer
            // move alone does not wake it (nothing would push the body).
            let wake = resized || (pressed && ptr.is_some_and(|p| self.hit(p, 0.0).is_some()));
            if !wake {
                return;
            }
            self.asleep = false;
            self.rest_s = 0.0;
            self.acc = 0.0;
            self.alpha = 0.0;
            self.last_now = now.is_finite().then_some(now);
        }

        if pressed {
            self.held = ptr.and_then(|p| self.hit(p, 0.0));
        }
        if !button {
            self.held = None;
        }
        if ptr.is_some() {
            self.target = ptr;
        }

        if !now.is_finite() {
            return;
        }
        let dt = match self.last_now {
            Some(last) if now >= last => now - last,
            _ => 0.0,
        };
        self.last_now = Some(now);
        self.acc += dt;
        let mut n = 0;
        while self.acc >= STEP_S && n < MAX_CATCH_UP {
            self.acc -= STEP_S;
            n += 1;
            self.step();
            if self.asleep {
                return;
            }
        }
        if self.acc >= STEP_S {
            self.acc = self.acc.rem_euclid(STEP_S);
        }
        #[allow(clippy::cast_possible_truncation, reason = "a share of one step, 0..1")]
        let alpha = (self.acc / STEP_S) as f32;
        self.alpha = alpha.clamp(0.0, 1.0);
    }

    fn step(&mut self) {
        self.steps += 1;
        let dt = STEP_S as f32;
        let g = self.spec.gravity;
        for b in &mut self.bodies {
            b.prev = b.snap();
        }
        for r in &mut self.ropes {
            r.prev.clone_from(&r.pts);
        }
        // Anchors follow the current size.
        for (r, spec) in self.ropes.iter_mut().zip(&self.spec.ropes) {
            let s = self.size[0].min(self.size[1]);
            r.anchor = [spec.anchor[0] * self.size[0] / s, spec.anchor[1] * self.size[1] / s];
        }

        // Predict.
        for b in &mut self.bodies {
            b.v = add(b.v, scale(g, dt));
            b.p = add(b.p, scale(b.v, dt));
            b.angle += b.spin * dt;
        }
        for r in &mut self.ropes {
            let last_free =
                if r.body.is_some() { r.pts.len().saturating_sub(1) } else { r.pts.len() };
            for (k, (x, o)) in r.pts.iter_mut().zip(r.old.iter_mut()).enumerate() {
                if k == 0 || k >= last_free {
                    continue;
                }
                let vel = scale(sub(*x, *o), ROPE_KEEP_PER_STEP);
                *o = *x;
                *x = add(add(*x, vel), scale(g, dt * dt));
            }
        }

        // The drag: a soft pull of the grab point toward the pointer.
        if let (Some(grab), Some(target)) = (self.held, self.target)
            && let Some(b) = self.bodies.get_mut(grab.body)
        {
            let r = rotate(grab.local, b.angle);
            let d = sub(add(b.p, r), target);
            let l = len(d);
            if l > 1e-6 {
                let n = scale(d, 1.0 / l);
                let w = b.inv_mass_at(r, n);
                if w > 0.0 {
                    b.push(r, n, DRAG_PULL_PER_STEP * l / w);
                }
            }
        }

        // Project the rope joints.
        for _ in 0..ITERATIONS {
            for rope in &mut self.ropes {
                solve_rope(rope, &mut self.bodies);
            }
        }
        for rope in &mut self.ropes {
            let n = rope.pts.len().saturating_sub(1);
            if let Some(b) = rope.body.and_then(|i| self.bodies.get(i)) {
                let e = b.world_point(rope.attach);
                put(&mut rope.pts, n, e);
                put(&mut rope.old, n, e);
            }
            put(&mut rope.old, 0, rope.anchor);
        }

        // Velocities from the moves; damping; twist; bounds.
        let (lo, hi) = {
            let s = self.shorter();
            (
                [-BOUNDS_MARGIN, -BOUNDS_MARGIN],
                [self.size[0] / s + BOUNDS_MARGIN, self.size[1] / s + BOUNDS_MARGIN],
            )
        };
        let held = self.held.map(|g| g.body);
        for (i, b) in self.bodies.iter_mut().enumerate() {
            let keep = b.keep.powf(dt) * if held == Some(i) { DRAG_KEEP_PER_STEP } else { 1.0 };
            b.v = scale(sub(b.p, b.prev.p), keep / dt);
            b.spin = (b.angle - b.prev.angle) * keep / dt;
            let accel = -TWIST_STIFFNESS * b.twist - TWIST_DAMPING * b.twist_v
                + TWIST_FROM_VX * b.v[0]
                + TWIST_FROM_SPIN * b.spin;
            b.twist_v += accel * dt;
            b.twist += b.twist_v * dt;
            for k in 0..2 {
                let (Some(p), Some(v), Some(&l), Some(&h)) =
                    (b.p.get_mut(k), b.v.get_mut(k), lo.get(k), hi.get(k))
                else {
                    continue;
                };
                if *p < l || *p > h {
                    *p = p.clamp(l, h);
                    *v = 0.0;
                }
            }
        }

        if !self.finite() {
            // Never draw a NaN: start over from the written layout.
            let last_now = self.last_now;
            self.layout();
            self.last_now = last_now;
            return;
        }

        // Rest and sleep.
        let resting = self.held.is_none()
            && self.bodies.iter().all(|b| {
                len(b.v) < REST_SPEED && b.spin.abs() < REST_SPIN && b.twist_v.abs() < REST_SPIN
            })
            && self
                .ropes
                .iter()
                .all(|r| r.pts.iter().zip(&r.old).all(|(x, o)| len(sub(*x, *o)) < REST_SPEED * dt));
        self.rest_s = if resting { self.rest_s + dt } else { 0.0 };
        if self.rest_s >= REST_HOLD_S {
            self.sleep();
        }
    }

    fn finite(&self) -> bool {
        self.bodies.iter().all(|b| {
            finite2(b.p)
                && finite2(b.v)
                && b.angle.is_finite()
                && b.spin.is_finite()
                && b.twist.is_finite()
                && b.twist_v.is_finite()
        }) && self.ropes.iter().all(|r| r.pts.iter().chain(&r.old).all(|p| finite2(*p)))
    }

    /// Stops: the blended pose is the current one, nothing moves on.
    fn sleep(&mut self) {
        self.asleep = true;
        self.acc = 0.0;
        self.alpha = 0.0;
        for b in &mut self.bodies {
            b.v = [0.0; 2];
            b.spin = 0.0;
            b.twist_v = 0.0;
            b.prev = b.snap();
        }
        for r in &mut self.ropes {
            r.old.clone_from(&r.pts);
            r.prev.clone_from(&r.pts);
        }
    }

    /// True when the world rests and nothing holds a body: no step runs.
    pub fn asleep(&self) -> bool {
        self.asleep
    }

    /// Body `i`'s pose, blended between the last two steps.
    pub fn pose(&self, i: usize) -> Pose {
        let Some(b) = self.bodies.get(i) else { return Pose { squash: 1.0, ..Pose::default() } };
        let s = self.shorter();
        let a = self.alpha;
        let p = mix2(b.prev.p, b.p, a);
        let twist = mix(b.prev.twist, b.twist, a);
        let pose = Pose {
            x: p[0] * s,
            y: p[1] * s,
            rotation: mix(b.prev.angle, b.angle, a),
            squash: twist.cos().abs().clamp(MIN_SQUASH, 1.0),
            half_w: b.half[0] * s,
            half_h: b.half[1] * s,
        };
        if [pose.x, pose.y, pose.rotation, pose.squash].iter().all(|v| v.is_finite()) {
            pose
        } else {
            Pose { squash: 1.0, half_w: pose.half_w, half_h: pose.half_h, ..Pose::default() }
        }
    }

    /// Rope `i`'s points, first end to last, blended between the last two
    /// steps, appended to `out` (rendered pixels).
    pub fn rope_points(&self, i: usize, out: &mut Vec<[f32; 2]>) {
        let Some(r) = self.ropes.get(i) else { return };
        let s = self.shorter();
        let start = out.len();
        out.extend(r.prev.iter().zip(&r.pts).map(|(p, c)| scale(mix2(*p, *c, self.alpha), s)));
        // The pinned end sits at its fraction of the current size, even
        // in the frame of a resize.
        if let (Some(first), Some(spec)) = (out.get_mut(start), self.spec.ropes.get(i)) {
            *first = scale(self.place(spec.anchor), s);
        }
    }
}

/// One pass over a rope's joints and tethers, moving its body too.
fn solve_rope(rope: &mut Rope, bodies: &mut [Body]) {
    let n = rope.pts.len().saturating_sub(1);
    let anchor = rope.anchor;
    put(&mut rope.pts, 0, anchor);
    let mut body = rope.body.and_then(|i| bodies.get_mut(i));
    let inv_pt = |k: usize| if k == 0 { 0.0 } else { ROPE_POINT_INV_MASS };

    // Rope joints: each segment at most `seg` long.
    for k in 0..n {
        let a = get(&rope.pts, k);
        let wa = inv_pt(k);
        match body.as_deref_mut() {
            Some(b) if k + 1 == n => {
                let r = rotate(rope.attach, b.angle);
                let d = sub(add(b.p, r), a);
                let l = len(d);
                if l <= rope.seg || l < 1e-9 {
                    continue;
                }
                let nrm = scale(d, 1.0 / l);
                let w = wa + b.inv_mass_at(r, nrm);
                if w <= 0.0 {
                    continue;
                }
                let lambda = (l - rope.seg) / w;
                put(&mut rope.pts, k, add(a, scale(nrm, lambda * wa)));
                b.push(r, nrm, lambda);
            }
            _ => {
                let bp = get(&rope.pts, k + 1);
                let wb = ROPE_POINT_INV_MASS;
                let d = sub(bp, a);
                let l = len(d);
                if l <= rope.seg || l < 1e-9 {
                    continue;
                }
                let nrm = scale(d, 1.0 / l);
                let lambda = (l - rope.seg) / (wa + wb);
                put(&mut rope.pts, k, add(a, scale(nrm, lambda * wa)));
                put(&mut rope.pts, k + 1, sub(bp, scale(nrm, lambda * wb)));
            }
        }
    }

    // Tethers: point k is at most k segments from the anchor.
    for k in 1..=n {
        let max = rope.seg * k as f32;
        match body.as_deref_mut() {
            Some(b) if k == n => {
                let r = rotate(rope.attach, b.angle);
                let d = sub(add(b.p, r), anchor);
                let l = len(d);
                if l <= max || l < 1e-9 {
                    continue;
                }
                let nrm = scale(d, 1.0 / l);
                let w = b.inv_mass_at(r, nrm);
                if w > 0.0 {
                    b.push(r, nrm, (l - max) / w);
                }
            }
            _ => {
                let x = get(&rope.pts, k);
                let d = sub(x, anchor);
                let l = len(d);
                if l > max && l > 1e-9 {
                    put(&mut rope.pts, k, add(anchor, scale(d, max / l)));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
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
}
