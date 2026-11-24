//! Lottie to scene (plans/cmux-next/motion-scenes.md, "Lottie"): a Bodymovin
//! JSON export translated to `scene.json`'s form, with a lint line for every
//! feature it cannot carry. Pure: bytes in, JSON out.
//!
//! What maps:
//! - shape layers' ellipses (`el`, a `circle`) and rects (`rc`, a `roundRect`
//!   whose `shape` is the roundness over the rect's shorter side), solid layers
//!   (`ty` 1, a `roundRect`), nulls (`ty` 3, as parents) and precomps (`ty` 0,
//!   flattened, with their `st` start and `sr` stretch);
//! - solid fills (`fl`), gradient fills (`gf`: linear or radial, first and last
//!   stop; more stops warn), and strokes (`st`, `gs`) on ellipses and rects, as
//!   a second shape with `stroke` set to the stroke's width;
//! - every transform above a shape (group `tr`, the layer's `ks`, its parents',
//!   the precomps'): composed into the shape's `at`, `size` and `rotate`, and
//!   opacity multiplied into `opacity` (a parent's opacity does not pass to its
//!   children, as in After Effects; a precomp's does);
//! - layer in and out points: `opacity` keys with `hold`;
//! - the bottom layer, when it is an unmoving opaque solid or rect that covers
//!   the canvas: the field's color. Otherwise the scene has no field (paper).
//!
//! Each track is sampled at every keyframe time of everything it depends on.
//! A segment between two such times keeps the Lottie easing (`i`/`o`, a
//! cubic-bezier on the later key) or a hold when that reproduces it; otherwise
//! it is baked to linear samples (at most `MAX_KEYS` keys per track).
//! A linear gradient's `angle` is the direction from its start color to its
//! end color in the shape's own frame (it turns with `rotate`): 0 is +x, 90 is
//! +y (down).
//!
//! What is refused (a lint line with `refused`): paths (`sh`), stars (`sr`),
//! trim paths (`tm`), repeaters (`rp`), merge paths (`mm`), other path
//! modifiers, masks, mattes (`tt`, `td`), effects (`ef`), time remapping, text
//! and image layers, 3D (`ddd`), cameras, expressions, and more than 16 shapes.

use super::MAX_SHAPES;
use super::value::{Ease, MAX_KEYS};
use crate::manifest::{ManifestErrorKind, Result, err};
use serde_json::{Map, Value, json};
use std::rc::Rc;

/// The largest Lottie file read.
pub const MAX_LOTTIE_BYTES: usize = 2 * 1024 * 1024;

/// One thing the translation could not carry over, or changed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Lint {
    /// JSON pointer into the Lottie file.
    pub pointer: String,
    /// The Lottie feature (`sh` path, `tm` trim, mask, matte, ...).
    pub feature: String,
    /// True when the file cannot load because of it; false for a warning
    /// (a 3-stop gradient reduced to 2, say).
    pub refused: bool,
    pub message: String,
}

/// A translated file.
#[derive(Clone, Debug, PartialEq)]
pub struct Translation {
    /// The scene, in `scene.json`'s form (`Scene::from_value` checks it).
    pub scene: Value,
    pub lint: Vec<Lint>,
}

impl Translation {
    /// True when no lint line refuses the file.
    pub fn loadable(&self) -> bool {
        self.lint.iter().all(|l| !l.refused)
    }
}

/// Translates a Lottie file's bytes.
pub fn translate(json: &[u8]) -> Result<Translation> {
    if json.len() > MAX_LOTTIE_BYTES {
        return Err(err(ManifestErrorKind::NotJson, "", "the Lottie file is larger than 2 MiB"));
    }
    let v: Value = serde_json::from_slice(json)
        .map_err(|e| err(ManifestErrorKind::NotJson, "", format!("not JSON: {e}")))?;
    let Some(root) = v.as_object() else {
        return Err(err(ManifestErrorKind::WrongType, "", "a Lottie file is a JSON object"));
    };
    let Some(layers) = root.get("layers").and_then(Value::as_array) else {
        return Err(err(
            ManifestErrorKind::BadFormat,
            "/layers",
            "not a Lottie file: it has no layers array",
        ));
    };
    let mut cx = Cx::new(root);
    cx.run(layers);
    Ok(cx.finish())
}

/// Precomp nesting and group nesting.
const MAX_NEST: usize = 16;
/// Parent links followed from one layer.
const MAX_PARENTS: usize = 32;
/// Points checked (and, when the easing does not match, kept) inside each
/// segment between two keyframe times.
const SEG_POINTS: usize = 7;
/// The step, in frames, for a value just before a jump.
const EPS_FRAME: f64 = 1e-4;
/// Two frames closer than this are one.
const SAME_FRAME: f64 = 1e-6;

// ---------------------------------------------------------------------------
// Properties

/// Root frame to a layer's frame: `f * mul + add`.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Clock {
    mul: f64,
    add: f64,
}

impl Clock {
    const ROOT: Self = Self { mul: 1.0, add: 0.0 };

    fn at(self, f: f64) -> f64 {
        f * self.mul + self.add
    }

    /// The root frame at which this clock reads `local`.
    fn root(self, local: f64) -> f64 {
        (local - self.add) / self.mul
    }

    /// A layer's property clock: its comp's frame less its start.
    fn offset(self, st: f64) -> Self {
        Self { mul: self.mul, add: self.add - st }
    }

    /// A precomp's inner clock: `(frame - st) / sr`.
    fn stretch(self, st: f64, sr: f64) -> Self {
        Self { mul: self.mul / sr, add: (self.add - st) / sr }
    }
}

#[derive(Clone, Debug)]
struct Key {
    t: f64,
    s: Option<Vec<f64>>,
    e: Option<Vec<f64>>,
    hold: bool,
    o: Option<[f64; 2]>,
    i: Option<[f64; 2]>,
    to: Option<Vec<f64>>,
    ti: Option<Vec<f64>>,
}

impl Key {
    fn ease(&self) -> Ease {
        if self.hold {
            return Ease::Hold;
        }
        match (self.o, self.i) {
            (Some([ox, oy]), Some([ix, iy])) => {
                if (ox - oy).abs() < 1e-9 && (ix - iy).abs() < 1e-9 {
                    Ease::Linear
                } else {
                    Ease::Bezier([
                        ox.clamp(0.0, 1.0) as f32,
                        oy.clamp(-4.0, 5.0) as f32,
                        ix.clamp(0.0, 1.0) as f32,
                        iy.clamp(-4.0, 5.0) as f32,
                    ])
                }
            }
            _ => Ease::Linear,
        }
    }

    /// Whether the move to the next key follows a curve (`to`/`ti`).
    fn spatial(&self) -> bool {
        let nonzero =
            |v: &Option<Vec<f64>>| v.as_ref().is_some_and(|v| v.iter().any(|x| x.abs() > 1e-9));
        nonzero(&self.to) || nonzero(&self.ti)
    }
}

/// One keyframe span of a property, in the property's own frames.
#[derive(Clone, Copy, Debug)]
struct Seg {
    t0: f64,
    t1: f64,
    /// The span's easing, when the value follows it (not a curved path).
    ease: Option<Ease>,
    hold: bool,
}

#[derive(Clone, Debug)]
enum Prop {
    Fixed(Vec<f64>),
    Keys(Vec<Key>),
    /// A position written as separate x and y (`"s": true`).
    Split(Box<Prop>, Box<Prop>),
}

impl Prop {
    fn fixed(v: &[f64]) -> Self {
        Self::Fixed(v.to_vec())
    }

    fn at(&self, f: f64) -> Vec<f64> {
        match self {
            Self::Fixed(v) => v.clone(),
            Self::Split(x, y) => vec![x.n(f, 0, 0.0), y.n(f, 0, 0.0)],
            Self::Keys(keys) => keys_at(keys, f),
        }
    }

    fn n(&self, f: f64, i: usize, default: f64) -> f64 {
        self.at(f).get(i).copied().filter(|x| x.is_finite()).unwrap_or(default)
    }

    fn v2(&self, f: f64, default: [f64; 2]) -> [f64; 2] {
        let v = self.at(f);
        let x = v.first().copied().filter(|x| x.is_finite()).unwrap_or(default[0]);
        // A one-number scale or size is uniform.
        let y = v.get(1).copied().filter(|x| x.is_finite()).unwrap_or(if v.len() == 1 {
            x
        } else {
            default[1]
        });
        [x, y]
    }

    fn segments(&self, out: &mut Vec<Seg>) {
        match self {
            Self::Fixed(_) => {}
            Self::Split(x, y) => {
                x.segments(out);
                y.segments(out);
            }
            Self::Keys(keys) => {
                for pair in keys.windows(2) {
                    if let [k, k1] = pair {
                        let ease = if k.spatial() && !k.hold { None } else { Some(k.ease()) };
                        out.push(Seg { t0: k.t, t1: k1.t, ease, hold: k.hold });
                    }
                }
            }
        }
    }
}

fn keys_at(keys: &[Key], f: f64) -> Vec<f64> {
    let Some(first) = keys.first() else { return Vec::new() };
    let mut prev_end = first.s.clone().or_else(|| first.e.clone()).unwrap_or_default();
    if f < first.t {
        return prev_end;
    }
    for pair in keys.windows(2) {
        let [k, k1] = pair else { continue };
        let start = k.s.clone().unwrap_or_else(|| prev_end.clone());
        let end = k.e.clone().or_else(|| k1.s.clone()).unwrap_or_else(|| start.clone());
        if f < k1.t {
            if k.hold {
                return start;
            }
            let span = k1.t - k.t;
            let x = if span > 0.0 { (f - k.t) / span } else { 1.0 };
            let y = f64::from(k.ease().apply(x as f32));
            return if k.spatial() && start.len() >= 2 {
                curve(
                    &start,
                    &end,
                    k.to.as_deref().unwrap_or(&[]),
                    k.ti.as_deref().unwrap_or(&[]),
                    y,
                )
            } else {
                start
                    .iter()
                    .zip(end.iter().chain(std::iter::repeat(&0.0)))
                    .map(|(a, b)| a + (b - a) * y)
                    .collect()
            };
        }
        prev_end = end;
    }
    keys.last().and_then(|k| k.s.clone()).unwrap_or(prev_end)
}

/// A point on the cubic from `a` (leaving along `to`) to `b` (arriving along `ti`).
fn curve(a: &[f64], b: &[f64], to: &[f64], ti: &[f64], u: f64) -> Vec<f64> {
    let v = 1.0 - u;
    a.iter()
        .enumerate()
        .map(|(i, &p0)| {
            let p3 = b.get(i).copied().unwrap_or(p0);
            let p1 = p0 + to.get(i).copied().unwrap_or(0.0);
            let p2 = p3 + ti.get(i).copied().unwrap_or(0.0);
            v * v * v * p0 + 3.0 * v * v * u * p1 + 3.0 * v * u * u * p2 + u * u * u * p3
        })
        .collect()
}

fn nums(v: &Value) -> Option<Vec<f64>> {
    match v {
        Value::Number(n) => n.as_f64().map(|x| vec![x]),
        Value::Array(a) => a.iter().map(Value::as_f64).collect(),
        _ => None,
    }
}

fn ease_xy(v: Option<&Value>) -> Option<[f64; 2]> {
    let o = v?.as_object()?;
    let first = |v: &Value| v.as_f64().or_else(|| v.as_array()?.first()?.as_f64());
    Some([first(o.get("x")?)?, first(o.get("y")?)?])
}

fn num(o: &Map<String, Value>, key: &str) -> Option<f64> {
    o.get(key).and_then(Value::as_f64).filter(|x| x.is_finite())
}

fn flag(o: &Map<String, Value>, key: &str) -> bool {
    match o.get(key) {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|x| x != 0.0),
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Transforms

/// `[a, b, c, d, tx, ty]`: x' = a x + c y + tx, y' = b x + d y + ty.
type Mat = [f64; 6];
const IDENTITY: Mat = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

/// `m` after `n` (n applied first).
fn mul(m: Mat, n: Mat) -> Mat {
    let [a, b, c, d, tx, ty] = m;
    let [e, f, g, h, ux, uy] = n;
    [
        a * e + c * f,
        b * e + d * f,
        a * g + c * h,
        b * g + d * h,
        a * ux + c * uy + tx,
        b * ux + d * uy + ty,
    ]
}

fn apply(m: Mat, p: [f64; 2]) -> [f64; 2] {
    [m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5]]
}

fn apply_linear(m: Mat, p: [f64; 2]) -> [f64; 2] {
    [m[0] * p[0] + m[2] * p[1], m[1] * p[0] + m[3] * p[1]]
}

/// `angle` (degrees) turned by whole turns to land nearest `near`.
fn snap(angle: f64, near: f64) -> f64 {
    angle + 360.0 * ((near - angle) / 360.0).round()
}

#[derive(Clone, Debug)]
struct Xform {
    a: Prop,
    p: Prop,
    s: Prop,
    r: Prop,
    o: Prop,
}

impl Xform {
    fn matrix(&self, f: f64) -> Mat {
        let a = self.a.v2(f, [0.0, 0.0]);
        let p = self.p.v2(f, [0.0, 0.0]);
        let s = self.s.v2(f, [100.0, 100.0]);
        let (sin, cos) = self.r.n(f, 0, 0.0).to_radians().sin_cos();
        let (sx, sy) = (s[0] / 100.0, s[1] / 100.0);
        let lin = [cos * sx, sin * sx, -sin * sy, cos * sy, 0.0, 0.0];
        let off = apply_linear(lin, [-a[0], -a[1]]);
        [lin[0], lin[1], lin[2], lin[3], p[0] + off[0], p[1] + off[1]]
    }

    fn props(&self) -> [&Prop; 5] {
        [&self.a, &self.p, &self.s, &self.r, &self.o]
    }
}

#[derive(Clone, Debug)]
struct Link {
    xf: Rc<Xform>,
    clock: Clock,
    /// Whether its opacity reaches the shape (not for a parent link).
    opacity: bool,
}

/// Shown while `ip <= clock(f) < op`.
#[derive(Clone, Copy, Debug)]
struct Vis {
    clock: Clock,
    ip: f64,
    op: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Circle,
    RoundRect,
}

#[derive(Clone, Debug)]
struct Geom {
    kind: Kind,
    p: Prop,
    s: Prop,
    r: Prop,
    clock: Clock,
    /// Innermost first.
    chain: Vec<Link>,
    ptr: String,
}

#[derive(Clone, Debug)]
enum PaintKind {
    Solid(Prop),
    Gradient { radial: bool, s: Prop, e: Prop, g: Prop, stops: usize },
}

#[derive(Clone, Debug)]
struct Paint {
    kind: PaintKind,
    o: Prop,
    /// A stroke's width; `None` fills.
    width: Option<Prop>,
    clock: Clock,
}

#[derive(Clone, Debug)]
struct Out {
    geom: Geom,
    paint: Rc<Paint>,
    vis: Vec<Vis>,
    /// The root layer it comes from.
    root_layer: usize,
}

/// A shape at one frame, in scene units.
#[derive(Clone, Copy, Debug, Default)]
struct State {
    at: [f64; 2],
    size: [f64; 2],
    rotate: f64,
    opacity: f64,
    from: [f64; 4],
    to: [f64; 4],
    angle: f64,
    param: f64,
    stroke: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tk {
    At,
    Size,
    Rotate,
    Opacity,
    From,
    To,
    Angle,
    Param,
    Stroke,
}

impl Tk {
    fn get(self, s: &State) -> [f64; 4] {
        match self {
            Self::At => [s.at[0], s.at[1], 0.0, 0.0],
            Self::Size => [s.size[0], s.size[1], 0.0, 0.0],
            Self::Rotate => [s.rotate, 0.0, 0.0, 0.0],
            Self::Opacity => [s.opacity, 0.0, 0.0, 0.0],
            Self::From => s.from,
            Self::To => s.to,
            Self::Angle => [s.angle, 0.0, 0.0, 0.0],
            Self::Param => [s.param, 0.0, 0.0, 0.0],
            Self::Stroke => [s.stroke, 0.0, 0.0, 0.0],
        }
    }

    /// The largest difference that still counts as the same value.
    fn tol(self) -> f64 {
        match self {
            Self::At | Self::Size | Self::Param => 1e-3,
            Self::Stroke => 2e-4,
            Self::Rotate | Self::Angle => 0.1,
            Self::Opacity => 2e-3,
            Self::From | Self::To => 1.5 / 255.0,
        }
    }

    fn same(self, a: [f64; 4], b: [f64; 4]) -> bool {
        let tol = self.tol();
        a.iter().zip(b).all(|(x, y)| (x - y).abs() <= tol)
    }
}

type KeyOut = (f64, [f64; 4], Ease);

fn lerp4(a: [f64; 4], b: [f64; 4], f: f64) -> [f64; 4] {
    [
        a[0] + (b[0] - a[0]) * f,
        a[1] + (b[1] - a[1]) * f,
        a[2] + (b[2] - a[2]) * f,
        a[3] + (b[3] - a[3]) * f,
    ]
}

/// A shape's tracks, ready to write.
struct Baked {
    kind: Kind,
    gradient: Option<bool>,
    stroke: bool,
    tracks: Vec<(Tk, Vec<KeyOut>)>,
    root_layer: usize,
}

impl Baked {
    fn track(&self, tk: Tk) -> Option<&[KeyOut]> {
        self.tracks.iter().find(|(t, _)| *t == tk).map(|(_, k)| k.as_slice())
    }

    /// The value when the track does not move.
    fn constant(&self, tk: Tk) -> Option<[f64; 4]> {
        let keys = self.track(tk)?;
        let first = keys.first()?.1;
        keys.iter().all(|k| tk.same(k.1, first)).then_some(first)
    }
}

// ---------------------------------------------------------------------------
// The walk

struct Cx<'a> {
    root: &'a Map<String, Value>,
    lint: Vec<Lint>,
    fr: f64,
    ip: f64,
    op: f64,
    w: f64,
    h: f64,
    loop_s: f64,
    outs: Vec<Out>,
}

impl<'a> Cx<'a> {
    fn new(root: &'a Map<String, Value>) -> Self {
        Self {
            root,
            lint: Vec::new(),
            fr: 30.0,
            ip: 0.0,
            op: 300.0,
            w: 512.0,
            h: 512.0,
            loop_s: 10.0,
            outs: Vec::new(),
        }
    }

    fn note(
        &mut self,
        pointer: impl Into<String>,
        feature: &str,
        refused: bool,
        message: impl Into<String>,
    ) {
        let pointer = pointer.into();
        if self.lint.iter().any(|l| l.pointer == pointer && l.feature == feature) {
            return;
        }
        self.lint.push(Lint {
            pointer,
            feature: feature.to_string(),
            refused,
            message: message.into(),
        });
    }

    fn refuse(&mut self, pointer: impl Into<String>, feature: &str, message: impl Into<String>) {
        self.note(pointer, feature, true, message);
    }

    fn warn(&mut self, pointer: impl Into<String>, feature: &str, message: impl Into<String>) {
        self.note(pointer, feature, false, message);
    }

    fn run(&mut self, layers: &'a [Value]) {
        let root = self.root;
        match num(root, "fr").filter(|f| *f > 0.0) {
            Some(fr) => self.fr = fr,
            None => self.refuse("/fr", "fr", "the frame rate is missing or not above 0"),
        }
        self.ip = num(root, "ip").unwrap_or(0.0);
        match num(root, "op").filter(|op| *op > self.ip) {
            Some(op) => self.op = op,
            None => {
                self.refuse("/op", "op", "the out point is missing or not after the in point");
                self.op = self.ip + self.fr * 10.0;
            }
        }
        for (key, slot) in [("w", 0), ("h", 1)] {
            match num(root, key).filter(|x| *x > 0.0) {
                Some(x) if slot == 0 => self.w = x,
                Some(x) => self.h = x,
                None => self.refuse(format!("/{key}"), key, "the canvas size is missing"),
            }
        }
        let loop_s = (self.op - self.ip) / self.fr;
        if loop_s > 600.0 {
            self.refuse(
                "/op",
                "duration",
                format!("the animation is {loop_s:.0} s long; a scene loops at most 600 s"),
            );
        } else if loop_s < 0.5 {
            self.warn(
                "/op",
                "duration",
                "the animation is shorter than 0.5 s; the loop is held to 0.5 s",
            );
        }
        // The loop as the scene reads it (f32), so no key time passes it.
        self.loop_s = f64::from(((loop_s * 1e4).round() / 1e4).clamp(0.5, 600.0) as f32);
        if flag(root, "ddd") {
            self.refuse("/ddd", "ddd", "3D compositions have no scene equivalent");
        }
        let env = Env {
            clock: Clock::ROOT,
            chain: Vec::new(),
            vis: Vec::new(),
            depth: 0,
            root_layer: None,
        };
        let mut outs = Vec::new();
        self.comp(layers, "/layers", &env, &mut outs);
        self.outs = outs;
    }

    /// The asset with `id`, when it holds layers.
    fn asset(&self, id: &str) -> Option<(usize, &'a [Value])> {
        let assets = self.root.get("assets")?.as_array()?;
        assets.iter().enumerate().find_map(|(i, a)| {
            let o = a.as_object()?;
            let aid = match o.get("id")? {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            if aid != id {
                return None;
            }
            Some((i, o.get("layers")?.as_array()?.as_slice()))
        })
    }

    fn prop(&mut self, v: Option<&Value>, ptr: &str, default: &[f64]) -> Prop {
        let Some(v) = v else { return Prop::fixed(default) };
        let Some(o) = v.as_object() else {
            return Prop::Fixed(nums(v).unwrap_or_else(|| default.to_vec()));
        };
        if o.get("x").is_some_and(Value::is_string) {
            self.refuse(format!("{ptr}/x"), "expression", "an expression drives this property");
        }
        if flag(o, "s") && o.get("x").is_some_and(Value::is_object) {
            let d0 = default.first().copied().unwrap_or(0.0);
            let d1 = default.get(1).copied().unwrap_or(0.0);
            let x = self.prop(o.get("x"), &format!("{ptr}/x"), &[d0]);
            let y = self.prop(o.get("y"), &format!("{ptr}/y"), &[d1]);
            return Prop::Split(Box::new(x), Box::new(y));
        }
        let Some(k) = o.get("k") else { return Prop::fixed(default) };
        let Some(list) = k.as_array().filter(|a| a.first().is_some_and(Value::is_object)) else {
            return Prop::Fixed(nums(k).unwrap_or_else(|| default.to_vec()));
        };
        let mut keys = Vec::with_capacity(list.len());
        for (j, kv) in list.iter().enumerate() {
            let Some((ko, t)) = kv.as_object().and_then(|ko| Some((ko, num(ko, "t")?))) else {
                self.warn(
                    format!("{ptr}/k/{j}"),
                    "keyframe",
                    "a keyframe without a time is skipped",
                );
                continue;
            };
            keys.push(Key {
                t,
                s: ko.get("s").and_then(nums),
                e: ko.get("e").and_then(nums),
                hold: flag(ko, "h"),
                o: ease_xy(ko.get("o")),
                i: ease_xy(ko.get("i")),
                to: ko.get("to").and_then(nums),
                ti: ko.get("ti").and_then(nums),
            });
        }
        keys.sort_by(|a, b| a.t.total_cmp(&b.t));
        if keys.is_empty() {
            return Prop::fixed(default);
        }
        if keys.len() == 1 {
            return Prop::Fixed(keys_at(&keys, 0.0));
        }
        Prop::Keys(keys)
    }

    fn xform(&mut self, v: Option<&Value>, ptr: &str) -> Xform {
        let o = v.and_then(Value::as_object);
        let get = |k: &str| o.and_then(|o| o.get(k));
        for key in ["sk", "rx", "ry", "or"] {
            let p = self.prop(get(key), &format!("{ptr}/{key}"), &[0.0]);
            let moves = matches!(p, Prop::Keys(_) | Prop::Split(..))
                || p.at(0.0).iter().any(|x| x.abs() > 1e-6);
            if moves {
                if key == "sk" {
                    self.warn(format!("{ptr}/sk"), "skew", "skew is dropped");
                } else {
                    self.refuse(
                        format!("{ptr}/{key}"),
                        "3D rotation",
                        "3D rotation has no scene equivalent",
                    );
                }
            }
        }
        let rkey = if get("r").is_none() && get("rz").is_some() { "rz" } else { "r" };
        Xform {
            a: self.prop(get("a"), &format!("{ptr}/a"), &[0.0, 0.0]),
            p: self.prop(get("p"), &format!("{ptr}/p"), &[0.0, 0.0]),
            s: self.prop(get("s"), &format!("{ptr}/s"), &[100.0, 100.0]),
            r: self.prop(get(rkey), &format!("{ptr}/{rkey}"), &[0.0]),
            o: self.prop(get("o"), &format!("{ptr}/o"), &[100.0]),
        }
    }

    /// One composition's layers, top first.
    fn comp(&mut self, layers: &'a [Value], base: &str, env: &Env, outs: &mut Vec<Out>) {
        let xfs: Vec<Rc<Xform>> = layers
            .iter()
            .enumerate()
            .map(|(i, l)| Rc::new(self.xform(l.get("ks"), &format!("{base}/{i}/ks"))))
            .collect();
        for (i, layer) in layers.iter().enumerate() {
            let lp = format!("{base}/{i}");
            let Some(lo) = layer.as_object() else {
                self.warn(lp, "layer", "a layer that is not an object is skipped");
                continue;
            };
            if flag(lo, "hd") {
                continue;
            }
            self.layer_lint(lo, &lp);
            let st = num(lo, "st").unwrap_or(0.0);
            let lclock = env.clock.offset(st);
            let Some(own) = xfs.get(i).cloned() else { continue };
            let mut chain = vec![Link { xf: own, clock: lclock, opacity: true }];
            self.parents(layers, &xfs, base, lo, env.clock, &mut chain);
            chain.extend(env.chain.iter().cloned());
            let mut vis = env.vis.clone();
            vis.push(Vis {
                clock: env.clock,
                ip: num(lo, "ip").unwrap_or(f64::NEG_INFINITY),
                op: num(lo, "op").unwrap_or(f64::INFINITY),
            });
            let inner = Env {
                clock: lclock,
                chain,
                vis,
                depth: env.depth,
                root_layer: Some(env.root_layer.unwrap_or(i)),
            };
            let ty = lo.get("ty").and_then(Value::as_i64).unwrap_or(-1);
            match ty {
                4 => {
                    let shapes =
                        lo.get("shapes").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
                    self.items(shapes, &format!("{lp}/shapes"), &inner, None, 0, outs);
                }
                1 => self.solid(lo, &lp, &inner, outs),
                3 => {}
                0 => self.precomp(lo, &lp, env, inner, st, outs),
                2 => self.refuse(lp, "image layer", "image layers have no scene equivalent"),
                5 => self.refuse(lp, "text layer", "text layers have no scene equivalent"),
                6 => self.warn(lp, "audio layer", "audio is dropped"),
                13 => self.refuse(lp, "camera", "cameras (3D) have no scene equivalent"),
                other => self.refuse(
                    lp,
                    "layer type",
                    format!("layer type {other} has no scene equivalent"),
                ),
            }
        }
    }

    fn layer_lint(&mut self, lo: &Map<String, Value>, lp: &str) {
        if flag(lo, "ddd") {
            self.refuse(format!("{lp}/ddd"), "ddd", "3D layers have no scene equivalent");
        }
        let nonempty = |k: &str| lo.get(k).and_then(Value::as_array).is_some_and(|a| !a.is_empty());
        if nonempty("masksProperties") || flag(lo, "hasMask") {
            self.refuse(format!("{lp}/masksProperties"), "mask", "masks have no scene equivalent");
        }
        if num(lo, "tt").is_some_and(|t| t != 0.0) {
            self.refuse(format!("{lp}/tt"), "matte", "track mattes have no scene equivalent");
        }
        if flag(lo, "td") {
            self.refuse(
                format!("{lp}/td"),
                "matte",
                "this layer is a track matte, which has no scene equivalent",
            );
        }
        if nonempty("ef") {
            self.refuse(format!("{lp}/ef"), "effects", "effects have no scene equivalent");
        }
        if lo.get("tm").is_some_and(Value::is_object) {
            self.refuse(format!("{lp}/tm"), "time remap", "time remapping has no scene equivalent");
        }
        if nonempty("sy") {
            self.warn(format!("{lp}/sy"), "layer style", "layer styles are dropped");
        }
        if num(lo, "bm").is_some_and(|b| b != 0.0) {
            self.warn(
                format!("{lp}/bm"),
                "blend mode",
                "blend modes are dropped (drawn as normal)",
            );
        }
        if flag(lo, "ao") {
            self.warn(format!("{lp}/ao"), "auto-orient", "auto-orient is dropped");
        }
    }

    fn parents(
        &mut self,
        layers: &[Value],
        xfs: &[Rc<Xform>],
        base: &str,
        lo: &Map<String, Value>,
        comp_clock: Clock,
        chain: &mut Vec<Link>,
    ) {
        let mut next = num(lo, "parent");
        let mut n = 0;
        while let Some(pid) = next {
            n += 1;
            if n > MAX_PARENTS {
                self.refuse(base, "parent", "the parent links loop");
                return;
            }
            let found = layers
                .iter()
                .zip(xfs)
                .find(|(l, _)| l.get("ind").and_then(Value::as_f64) == Some(pid));
            let Some((pl, xf)) = found else {
                self.warn(base, "parent", format!("no layer has ind {pid}; the parent is dropped"));
                return;
            };
            let st = pl.get("st").and_then(Value::as_f64).unwrap_or(0.0);
            chain.push(Link { xf: Rc::clone(xf), clock: comp_clock.offset(st), opacity: false });
            next = pl.get("parent").and_then(Value::as_f64);
        }
    }

    fn precomp(
        &mut self,
        lo: &Map<String, Value>,
        lp: &str,
        env: &Env,
        inner: Env,
        st: f64,
        outs: &mut Vec<Out>,
    ) {
        let Some(id) = lo.get("refId").and_then(Value::as_str) else {
            self.refuse(format!("{lp}/refId"), "precomp", "the precomp names no asset");
            return;
        };
        let Some((ai, layers)) = self.asset(id) else {
            self.refuse(format!("{lp}/refId"), "precomp", format!("no asset {id:?} with layers"));
            return;
        };
        if env.depth >= MAX_NEST {
            self.refuse(lp, "precomp", "precomps nest too deep");
            return;
        }
        let sr = num(lo, "sr").filter(|s| s.abs() > 1e-9).unwrap_or(1.0);
        let env = Env {
            clock: env.clock.stretch(st, sr),
            chain: inner.chain,
            vis: inner.vis,
            depth: env.depth + 1,
            root_layer: inner.root_layer,
        };
        self.comp(layers, &format!("/assets/{ai}/layers"), &env, outs);
    }

    fn solid(&mut self, lo: &Map<String, Value>, lp: &str, env: &Env, outs: &mut Vec<Out>) {
        let sw = num(lo, "sw").unwrap_or(self.w);
        let sh = num(lo, "sh").unwrap_or(self.h);
        let Some(rgb) = lo.get("sc").and_then(Value::as_str).and_then(hex_rgb) else {
            self.warn(format!("{lp}/sc"), "solid", "a solid without a #RRGGBB color is skipped");
            return;
        };
        let geom = Geom {
            kind: Kind::RoundRect,
            p: Prop::fixed(&[sw / 2.0, sh / 2.0]),
            s: Prop::fixed(&[sw, sh]),
            r: Prop::fixed(&[0.0]),
            clock: env.clock,
            chain: env.chain.clone(),
            ptr: lp.to_string(),
        };
        let paint = Paint {
            kind: PaintKind::Solid(Prop::Fixed(rgb.to_vec())),
            o: Prop::fixed(&[100.0]),
            width: None,
            clock: env.clock,
        };
        outs.push(Out {
            geom,
            paint: Rc::new(paint),
            vis: env.vis.clone(),
            root_layer: env.root_layer.unwrap_or(0),
        });
    }

    /// One group's items, top first. Returns the ellipses and rects in it, for
    /// the paints below it in the enclosing groups.
    fn items(
        &mut self,
        items: &[Value],
        ptr: &str,
        env: &Env,
        tr: Option<Link>,
        depth: usize,
        outs: &mut Vec<Out>,
    ) -> Vec<Geom> {
        if depth > MAX_NEST {
            self.refuse(ptr, "group", "groups nest too deep");
            return Vec::new();
        }
        let mut chain = Vec::with_capacity(env.chain.len() + 1);
        chain.extend(tr);
        chain.extend(env.chain.iter().cloned());
        let mut pending: Vec<Geom> = Vec::new();
        for (j, it) in items.iter().enumerate() {
            let ip = format!("{ptr}/{j}");
            let Some(io) = it.as_object() else { continue };
            if flag(io, "hd") {
                continue;
            }
            let ty = io.get("ty").and_then(Value::as_str).unwrap_or("");
            match ty {
                "gr" => {
                    let inner =
                        io.get("it").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
                    let tr = inner
                        .iter()
                        .enumerate()
                        .rev()
                        .find(|(_, x)| x.get("ty").and_then(Value::as_str) == Some("tr"));
                    let link = tr.map(|(k, x)| Link {
                        xf: Rc::new(self.xform(Some(x), &format!("{ip}/it/{k}"))),
                        clock: env.clock,
                        opacity: true,
                    });
                    let sub = Env {
                        clock: env.clock,
                        chain: chain.clone(),
                        vis: env.vis.clone(),
                        depth: env.depth,
                        root_layer: env.root_layer,
                    };
                    pending.extend(self.items(
                        inner,
                        &format!("{ip}/it"),
                        &sub,
                        link,
                        depth + 1,
                        outs,
                    ));
                }
                "el" | "rc" => {
                    let kind = if ty == "el" { Kind::Circle } else { Kind::RoundRect };
                    pending.push(Geom {
                        kind,
                        p: self.prop(io.get("p"), &format!("{ip}/p"), &[0.0, 0.0]),
                        s: self.prop(io.get("s"), &format!("{ip}/s"), &[0.0, 0.0]),
                        r: self.prop(io.get("r"), &format!("{ip}/r"), &[0.0]),
                        clock: env.clock,
                        chain: chain.clone(),
                        ptr: ip,
                    });
                }
                "fl" | "gf" | "st" | "gs" => {
                    let Some(paint) = self.paint(io, ty, &ip, env.clock) else { continue };
                    let paint = Rc::new(paint);
                    for g in &pending {
                        outs.push(Out {
                            geom: g.clone(),
                            paint: Rc::clone(&paint),
                            vis: env.vis.clone(),
                            root_layer: env.root_layer.unwrap_or(0),
                        });
                    }
                }
                "tr" => {}
                "rd" => self.warn(ip, "rd round corners", "round corners are dropped"),
                "sh" => self.refuse(
                    ip,
                    "sh path",
                    "paths have no scene equivalent; use ellipses and rects",
                ),
                "sr" => self.refuse(ip, "sr star", "stars and polygons have no scene equivalent"),
                "tm" => self.refuse(ip, "tm trim", "trim paths have no scene equivalent"),
                "rp" => self.refuse(ip, "rp repeater", "repeaters have no scene equivalent"),
                "mm" => self.refuse(ip, "mm merge", "merge paths have no scene equivalent"),
                other => {
                    self.refuse(ip, other, format!("shape item {other:?} has no scene equivalent"));
                }
            }
        }
        pending
    }

    fn paint(
        &mut self,
        io: &Map<String, Value>,
        ty: &str,
        ip: &str,
        clock: Clock,
    ) -> Option<Paint> {
        let o = self.prop(io.get("o"), &format!("{ip}/o"), &[100.0]);
        let width = if ty == "st" || ty == "gs" {
            if io.get("d").and_then(Value::as_array).is_some_and(|d| !d.is_empty()) {
                self.warn(format!("{ip}/d"), "dashes", "stroke dashes are dropped (drawn solid)");
            }
            Some(self.prop(io.get("w"), &format!("{ip}/w"), &[1.0]))
        } else {
            None
        };
        let kind = if ty == "fl" || ty == "st" {
            PaintKind::Solid(self.prop(io.get("c"), &format!("{ip}/c"), &[1.0, 1.0, 1.0, 1.0]))
        } else {
            let radial = num(io, "t") == Some(2.0);
            let g = io.get("g").and_then(Value::as_object);
            let stops = g.and_then(|g| num(g, "p")).map_or(2, |p| p.max(1.0) as usize);
            if stops > 2 {
                self.warn(
                    format!("{ip}/g"),
                    "gradient stops",
                    format!("a gradient with {stops} stops keeps its first and last"),
                );
            }
            let gp = format!("{ip}/g/k");
            let g = self.prop(
                g.and_then(|g| g.get("k")),
                &gp,
                &[0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
            );
            PaintKind::Gradient {
                radial,
                s: self.prop(io.get("s"), &format!("{ip}/s"), &[0.0, 0.0]),
                e: self.prop(io.get("e"), &format!("{ip}/e"), &[100.0, 0.0]),
                g,
                stops,
            }
        };
        Some(Paint { kind, o, width, clock })
    }

    // -----------------------------------------------------------------------
    // Baking

    fn state(&self, out: &Out, f: f64) -> State {
        let g = &out.geom;
        let mut m = IDENTITY;
        let mut rot = 0.0;
        let mut opacity = 1.0;
        for link in &g.chain {
            let lf = link.clock.at(f);
            m = mul(link.xf.matrix(lf), m);
            rot += link.xf.r.n(lf, 0, 0.0);
            if link.opacity {
                opacity *= (link.xf.o.n(lf, 0, 100.0) / 100.0).clamp(0.0, 1.0);
            }
        }
        for v in &out.vis {
            let lf = v.clock.at(f);
            if !(v.ip - SAME_FRAME..v.op - SAME_FRAME).contains(&lf) {
                opacity = 0.0;
            }
        }
        let gf = g.clock.at(f);
        let center = apply(m, g.p.v2(gf, [0.0, 0.0]));
        let sz = g.s.v2(gf, [0.0, 0.0]);
        let (sx, sy) = (sz[0].abs(), sz[1].abs());
        let kx = m[0].hypot(m[1]);
        let det = m[0] * m[3] - m[1] * m[2];
        let ky = if kx > 1e-12 { det.abs() / kx } else { m[2].hypot(m[3]) };
        let theta = snap(m[1].atan2(m[0]).to_degrees(), rot);
        let short = self.w.min(self.h);
        let param = if g.kind == Kind::RoundRect {
            let r = g.r.n(gf, 0, 0.0).max(0.0);
            let side = sx.min(sy);
            if side > 0.0 { (r / side).clamp(0.0, 0.5) } else { 0.0 }
        } else {
            0.0
        };

        let p = &out.paint;
        let pf = p.clock.at(f);
        opacity *= (p.o.n(pf, 0, 100.0) / 100.0).clamp(0.0, 1.0);
        let (from, to, angle) = match &p.kind {
            PaintKind::Solid(c) => {
                let c = color(&c.at(pf));
                (c, c, 0.0)
            }
            PaintKind::Gradient { s, e, g: stops_prop, stops, .. } => {
                let (a, b) = gradient_ends(&stops_prop.at(pf), *stops);
                let sp = s.v2(pf, [0.0, 0.0]);
                let ep = e.v2(pf, [100.0, 0.0]);
                let local = [ep[0] - sp[0], ep[1] - sp[1]];
                let d = apply_linear(m, local);
                let reference = local[1].atan2(local[0]).to_degrees() + rot;
                // In the shape's own frame: it turns with `rotate`.
                (a, b, snap(d[1].atan2(d[0]).to_degrees(), reference) - theta)
            }
        };
        let stroke =
            p.width.as_ref().map_or(0.0, |w| w.n(pf, 0, 1.0).abs() * (kx * ky).sqrt() / short);
        State {
            at: [center[0] / self.w, center[1] / self.h],
            size: [sx * kx / short, sy * ky / short],
            rotate: theta,
            opacity,
            from,
            to,
            angle,
            param,
            stroke,
        }
    }

    fn bake(&mut self, out: &Out) -> Baked {
        let (ip, op, fr) = (self.ip, self.op, self.fr);
        let mut times = vec![ip, op];
        let mut disc = Vec::new();
        let mut cands: Vec<(f64, f64, Ease)> = Vec::new();
        let mut segs = Vec::new();
        let mut add = |p: &Prop, clock: Clock| {
            segs.clear();
            p.segments(&mut segs);
            for s in &segs {
                let (a, b) = (clock.root(s.t0), clock.root(s.t1));
                let (a, b) = if a <= b { (a, b) } else { (b, a) };
                times.push(a);
                times.push(b);
                if s.hold {
                    disc.push(if clock.mul > 0.0 { b } else { a });
                }
                if let Some(e) = s.ease.filter(|_| clock.mul > 0.0) {
                    cands.push((a, b, e));
                }
            }
        };
        let g = &out.geom;
        for p in [&g.p, &g.s, &g.r] {
            add(p, g.clock);
        }
        for link in &g.chain {
            for p in link.xf.props() {
                add(p, link.clock);
            }
        }
        let paint = &out.paint;
        add(&paint.o, paint.clock);
        if let Some(w) = &paint.width {
            add(w, paint.clock);
        }
        match &paint.kind {
            PaintKind::Solid(c) => add(c, paint.clock),
            PaintKind::Gradient { s, e, g, .. } => {
                for p in [s, e, g] {
                    add(p, paint.clock);
                }
            }
        }
        for v in &out.vis {
            for edge in [v.ip, v.op] {
                if edge.is_finite() {
                    let f = v.clock.root(edge);
                    times.push(f);
                    disc.push(f);
                }
            }
        }
        times.retain(|t| t.is_finite() && *t >= ip && *t <= op);
        times.sort_by(f64::total_cmp);
        times.dedup_by(|a, b| (*a - *b).abs() < SAME_FRAME);
        disc.retain(|d| *d > ip + SAME_FRAME && *d < op - SAME_FRAME);

        let segments = times.len().saturating_sub(1).max(1);
        let budget = MAX_KEYS.saturating_sub(times.len() + disc.len());
        let per_seg = (budget / segments).min(SEG_POINTS);

        let mut tks = vec![Tk::At, Tk::Size, Tk::Rotate, Tk::Opacity, Tk::From];
        if matches!(paint.kind, PaintKind::Gradient { .. }) {
            tks.push(Tk::To);
            tks.push(Tk::Angle);
        }
        if g.kind == Kind::RoundRect {
            tks.push(Tk::Param);
        }
        if paint.width.is_some() {
            tks.push(Tk::Stroke);
        }
        let loop_s = self.loop_s;
        let tsec = |f: f64| ((f - ip) / fr).clamp(0.0, loop_s);
        let s0 = self.state(out, ip);
        let mut tracks: Vec<(Tk, Vec<KeyOut>)> =
            tks.iter().map(|&tk| (tk, vec![(0.0, tk.get(&s0), Ease::Linear)])).collect();
        let mut coarse = false;
        for pair in times.windows(2) {
            let [a, b] = pair else { continue };
            let (a, b) = (*a, *b);
            let jump = disc.iter().any(|d| (d - b).abs() < SAME_FRAME);
            let left = if jump || b >= op - SAME_FRAME {
                self.state(out, b - EPS_FRAME)
            } else {
                self.state(out, b)
            };
            let right = if jump { Some(self.state(out, b)) } else { None };
            let fracs: Vec<f64> =
                (1..=SEG_POINTS).map(|j| j as f64 / (SEG_POINTS + 1) as f64).collect();
            let inner: Vec<State> =
                fracs.iter().map(|x| self.state(out, a + (b - a) * x)).collect();
            let mut eases = vec![Ease::Linear];
            for (c0, c1, e) in &cands {
                if (c0 - a).abs() < SAME_FRAME && (c1 - b).abs() < SAME_FRAME && !eases.contains(e)
                {
                    eases.push(*e);
                }
            }
            for (tk, keys) in &mut tracks {
                let tk = *tk;
                let Some(start) = keys.last().map(|k| k.1) else { continue };
                let end = tk.get(&left);
                let fit = eases.iter().copied().find(|e| {
                    fracs.iter().zip(&inner).all(|(x, s)| {
                        let want = lerp4(start, end, f64::from(e.apply(*x as f32)));
                        tk.same(want, tk.get(s))
                    })
                });
                match fit {
                    Some(e) => keys.push((tsec(b), end, e)),
                    None => {
                        if per_seg < SEG_POINTS {
                            coarse = true;
                        }
                        for j in 0..per_seg {
                            let pick = ((j + 1) * (SEG_POINTS + 1)) / (per_seg + 1);
                            let (Some(x), Some(s)) = (
                                fracs.get(pick.saturating_sub(1)),
                                inner.get(pick.saturating_sub(1)),
                            ) else {
                                continue;
                            };
                            keys.push((tsec(a + (b - a) * x), tk.get(s), Ease::Linear));
                        }
                        keys.push((tsec(b), end, Ease::Linear));
                    }
                }
                if let Some(r) = &right {
                    let v = tk.get(r);
                    if !tk.same(v, end) {
                        keys.push((tsec(b), v, Ease::Hold));
                    }
                }
            }
        }
        let mut over = false;
        for (tk, keys) in &mut tracks {
            let k = simplify(std::mem::take(keys), *tk);
            over |= k.len() > MAX_KEYS;
            *keys = thin(k);
        }
        if coarse || over {
            self.warn(
                g.ptr.clone(),
                "keyframes",
                format!("this shape changes too often to follow every frame; it is sampled to at most {MAX_KEYS} keys"),
            );
        }
        Baked {
            kind: g.kind,
            gradient: match paint.kind {
                PaintKind::Gradient { radial, .. } => Some(radial),
                PaintKind::Solid(_) => None,
            },
            stroke: paint.width.is_some(),
            tracks,
            root_layer: out.root_layer,
        }
    }

    /// The bottom shape's color, when it is an unmoving opaque solid that
    /// covers the canvas.
    fn background(&self, b: &Baked, bottom_layer: usize) -> Option<[f64; 4]> {
        if b.root_layer != bottom_layer
            || b.kind != Kind::RoundRect
            || b.gradient.is_some()
            || b.stroke
        {
            return None;
        }
        let at = b.constant(Tk::At)?;
        let size = b.constant(Tk::Size)?;
        let rot = b.constant(Tk::Rotate)?[0];
        let opacity = b.constant(Tk::Opacity)?[0];
        let color = b.constant(Tk::From)?;
        let param = b.constant(Tk::Param).map_or(0.0, |p| p[0]);
        let short = self.w.min(self.h);
        let turned = (rot / 90.0).round();
        if (rot - turned * 90.0).abs() > 0.5 || opacity < 0.999 || color[3] < 0.999 || param > 0.01
        {
            return None;
        }
        let (bw, bh) = if (turned as i64).rem_euclid(2) == 0 {
            (size[0], size[1])
        } else {
            (size[1], size[0])
        };
        let half = [bw * short / self.w / 2.0, bh * short / self.h / 2.0];
        let tol = 2e-3;
        let covers = at[0] - half[0] <= tol
            && at[0] + half[0] >= 1.0 - tol
            && at[1] - half[1] <= tol
            && at[1] + half[1] >= 1.0 - tol;
        covers.then_some(color)
    }

    fn finish(mut self) -> Translation {
        let outs = std::mem::take(&mut self.outs);
        // Bake no more than the scene can draw (the extra one may be the background).
        let skip = outs.len().saturating_sub(MAX_SHAPES + 1);
        let mut baked: Vec<Baked> = outs.iter().skip(skip).map(|o| self.bake(o)).collect();
        let bottom_layer = self.root.get("layers").and_then(Value::as_array).map_or(0, |l| {
            l.iter().rposition(|x| x.get("hd").and_then(Value::as_bool) != Some(true)).unwrap_or(0)
        });
        let mut field = None;
        if let Some(last) = baked.last()
            && let Some(c) = self.background(last, bottom_layer)
        {
            field = Some(c);
            baked.pop();
        }
        let total = outs.len() - usize::from(field.is_some());
        if total > MAX_SHAPES {
            self.refuse(
                "/layers",
                "shapes",
                format!("{total} shapes; a scene draws at most {MAX_SHAPES}"),
            );
            let extra = baked.len().saturating_sub(MAX_SHAPES);
            baked.drain(..extra);
        }

        let mut scene = Map::new();
        scene.insert("loop".into(), json!(self.loop_s));
        if let Some(c) = field {
            let hex = hex(c);
            let points: Vec<Value> = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
                .iter()
                .map(|at| json!({ "at": at, "color": hex }))
                .collect();
            scene.insert("field".into(), json!({ "points": points }));
        }
        // Lottie lists the top first; the scene draws in order.
        let shapes: Vec<Value> = baked.iter().rev().map(|b| self.shape_json(b)).collect();
        scene.insert("shapes".into(), Value::Array(shapes));
        Translation { scene: Value::Object(scene), lint: self.lint }
    }

    fn shape_json(&self, b: &Baked) -> Value {
        let mut o = Map::new();
        let t = |tk: Tk| self.track_json(b.track(tk).unwrap_or(&[]), tk);
        o.insert("kind".into(), json!(if b.kind == Kind::Circle { "circle" } else { "roundRect" }));
        o.insert("at".into(), t(Tk::At));
        o.insert("size".into(), t(Tk::Size));
        if b.constant(Tk::Rotate).is_none_or(|r| r[0].abs() > 1e-3) {
            o.insert("rotate".into(), t(Tk::Rotate));
        }
        let fill = match b.gradient {
            None => json!({ "type": "solid", "from": t(Tk::From) }),
            Some(radial) => json!({
                "type": if radial { "radial" } else { "linear" },
                "from": t(Tk::From),
                "to": t(Tk::To),
                "angle": t(Tk::Angle),
            }),
        };
        o.insert("fill".into(), fill);
        if b.constant(Tk::Opacity).is_none_or(|v| v[0] < 0.999) {
            o.insert("opacity".into(), t(Tk::Opacity));
        }
        if b.kind == Kind::RoundRect {
            o.insert("shape".into(), t(Tk::Param));
        }
        if b.stroke {
            o.insert("stroke".into(), t(Tk::Stroke));
        }
        Value::Object(o)
    }

    fn track_json(&self, keys: &[KeyOut], tk: Tk) -> Value {
        let first = keys.first().map_or([0.0; 4], |k| k.1);
        if keys.iter().all(|k| tk.same(k.1, first)) {
            return value_json(tk, first);
        }
        let list: Vec<Value> = keys
            .iter()
            .map(|(t, v, e)| {
                let t = round(*t, 1e4).min(self.loop_s);
                let v = value_json(tk, *v);
                match e {
                    Ease::Linear | Ease::In | Ease::Out | Ease::InOut | Ease::Sine => json!([t, v]),
                    Ease::Hold => json!([t, v, "hold"]),
                    Ease::Bezier(b) => {
                        let b: Vec<f64> = b.iter().map(|x| round(f64::from(*x), 1e4)).collect();
                        json!([t, v, b])
                    }
                }
            })
            .collect();
        json!({ "keys": list })
    }
}

struct Env {
    /// The comp's clock.
    clock: Clock,
    chain: Vec<Link>,
    vis: Vec<Vis>,
    depth: usize,
    root_layer: Option<usize>,
}

/// Drops keys that the keys around them already give (linear segments).
fn simplify(keys: Vec<KeyOut>, tk: Tk) -> Vec<KeyOut> {
    if keys.len() <= 2 {
        return keys;
    }
    let mut out: Vec<KeyOut> = Vec::with_capacity(keys.len());
    let mut anchor = 0;
    if let Some(k) = keys.first() {
        out.push(*k);
    }
    for j in 1..keys.len().saturating_sub(1) {
        let (Some(a), Some(k), Some(next)) = (keys.get(anchor), keys.get(j), keys.get(j + 1))
        else {
            continue;
        };
        let span = next.0 - a.0;
        let droppable = k.2 == Ease::Linear
            && next.2 == Ease::Linear
            && span > 1e-9
            && k.0 > a.0
            && next.0 > k.0
            && keys.get(anchor + 1..=j).is_some_and(|mid| {
                mid.iter().all(|m| tk.same(m.1, lerp4(a.1, next.1, (m.0 - a.0) / span)))
            });
        if !droppable {
            out.push(*k);
            anchor = j;
        }
    }
    if let Some(k) = keys.last() {
        out.push(*k);
    }
    // A last key that repeats the one before it says nothing.
    while out.len() >= 2 {
        let n = out.len();
        let (Some(prev), Some(last)) = (out.get(n - 2), out.get(n - 1)) else { break };
        if last.2 == Ease::Linear && tk.same(prev.1, last.1) {
            out.pop();
        } else {
            break;
        }
    }
    out
}

/// At most `MAX_KEYS` keys, evenly picked, the first and last kept.
fn thin(keys: Vec<KeyOut>) -> Vec<KeyOut> {
    let n = keys.len();
    if n <= MAX_KEYS {
        return keys;
    }
    (0..MAX_KEYS).filter_map(|i| keys.get(i * (n - 1) / (MAX_KEYS - 1)).copied()).collect()
}

fn round(x: f64, scale: f64) -> f64 {
    let r = (x * scale).round() / scale;
    if r.is_finite() { r } else { 0.0 }
}

fn value_json(tk: Tk, v: [f64; 4]) -> Value {
    let n = |x: f64, lo: f64, hi: f64, scale: f64| round(x.clamp(lo, hi), scale);
    match tk {
        Tk::At => json!([n(v[0], -2.0, 3.0, 1e4), n(v[1], -2.0, 3.0, 1e4)]),
        Tk::Size => json!([n(v[0], 0.0, 4.0, 1e4), n(v[1], 0.0, 4.0, 1e4)]),
        Tk::Rotate | Tk::Angle => json!(n(v[0], -3600.0, 3600.0, 1e3)),
        Tk::Opacity | Tk::Param => json!(n(v[0], 0.0, 1.0, 1e4)),
        Tk::Stroke => json!(n(v[0], 0.0, 0.5, 1e5)),
        Tk::From | Tk::To => json!(hex(v)),
    }
}

/// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
fn hex(c: [f64; 4]) -> String {
    let b = |x: f64| (x.clamp(0.0, 1.0) * 255.0).round() as u8;
    if b(c[3]) == 255 {
        format!("#{:02X}{:02X}{:02X}", b(c[0]), b(c[1]), b(c[2]))
    } else {
        format!("#{:02X}{:02X}{:02X}{:02X}", b(c[0]), b(c[1]), b(c[2]), b(c[3]))
    }
}

fn hex_rgb(s: &str) -> Option<[f64; 4]> {
    let h = s.strip_prefix('#')?;
    if h.len() != 6 {
        return None;
    }
    let byte = |i: usize| {
        h.get(i..i + 2).and_then(|b| u8::from_str_radix(b, 16).ok()).map(|b| f64::from(b) / 255.0)
    };
    Some([byte(0)?, byte(2)?, byte(4)?, 1.0])
}

/// A Lottie color (0..1, or 0..255 in old files) as RGBA 0..1.
fn color(v: &[f64]) -> [f64; 4] {
    let scale = if v.iter().take(3).any(|x| *x > 1.0) { 255.0 } else { 1.0 };
    let c = |i: usize, d: f64| v.get(i).map_or(d, |x| x / scale).clamp(0.0, 1.0);
    [c(0, 1.0), c(1, 1.0), c(2, 1.0), v.get(3).map_or(1.0, |a| a.clamp(0.0, 1.0))]
}

/// A gradient's first and last stop colors with their opacities. `g` is
/// `[offset, r, g, b] * stops`, then `[offset, alpha] *`.
fn gradient_ends(g: &[f64], stops: usize) -> ([f64; 4], [f64; 4]) {
    let rgb = |i: usize| -> [f64; 4] {
        let at = |k: usize| g.get(i * 4 + k).copied().unwrap_or(1.0);
        color(&[at(1), at(2), at(3)])
    };
    let mut a = rgb(0);
    let mut b = rgb(stops.saturating_sub(1));
    if let Some(alphas) = g.get(stops * 4..).filter(|r| r.len() >= 2) {
        if let Some(x) = alphas.get(1) {
            a[3] = x.clamp(0.0, 1.0);
        }
        if let Some(x) = alphas.get(alphas.len() - alphas.len() % 2 - 1) {
            b[3] = x.clamp(0.0, 1.0);
        }
    }
    (a, b)
}

#[cfg(test)]
mod tests {
    use super::super::Scene;
    use super::super::value::Track;
    use super::*;

    fn run(v: &Value) -> Translation {
        translate(v.to_string().as_bytes()).unwrap()
    }

    /// The scene's `shapes[i][key]` as a point track.
    fn point(t: &Translation, i: usize, key: &str) -> Track<[f32; 2]> {
        let loop_s = t.scene["loop"].as_f64().unwrap() as f32;
        Track::point(&t.scene["shapes"][i][key], "", loop_s, -2.0, 4.0).unwrap()
    }

    fn number(t: &Translation, v: &Value) -> Track<f32> {
        let loop_s = t.scene["loop"].as_f64().unwrap() as f32;
        Track::number(v, "", loop_s, -3600.0, 3600.0).unwrap()
    }

    fn near2(a: [f32; 2], b: [f32; 2]) -> bool {
        (a[0] - b[0]).abs() < 2e-3 && (a[1] - b[1]).abs() < 2e-3
    }

    fn loads(t: &Translation) {
        assert!(t.loadable(), "{:#?}", t.lint);
        Scene::from_value(&t.scene).unwrap_or_else(|e| panic!("{e:?}\n{:#}", t.scene));
    }

    fn file(layers: Value) -> Value {
        json!({ "v": "5.7.4", "fr": 30, "ip": 0, "op": 60, "w": 400, "h": 400, "ddd": 0, "assets": [], "layers": layers })
    }

    fn shape_layer(ks: Value, shapes: Value) -> Value {
        json!({ "ddd": 0, "ind": 1, "ty": 4, "nm": "L", "sr": 1, "ks": ks, "ao": 0, "shapes": shapes,
                "ip": 0, "op": 60, "st": 0, "bm": 0 })
    }

    fn red_fill() -> Value {
        json!({ "ty": "fl", "c": { "a": 0, "k": [1, 0, 0, 1] }, "o": { "a": 0, "k": 100 }, "r": 1 })
    }

    #[test]
    fn a_moving_scaling_ellipse_keeps_its_bezier_easing() {
        let ease = json!({ "o": { "x": [0.4], "y": [0] }, "i": { "x": [0.2], "y": [1] } });
        let mut k0 = json!({ "t": 0, "s": [100, 100, 0] });
        let mut s0 = json!({ "t": 0, "s": [100, 100, 100] });
        for k in [&mut k0, &mut s0] {
            k["o"] = ease["o"].clone();
            k["i"] = ease["i"].clone();
        }
        let ks = json!({
            "p": { "a": 1, "k": [k0, { "t": 30, "s": [300, 200, 0] }] },
            "s": { "a": 1, "k": [s0, { "t": 30, "s": [200, 200, 100] }] },
            "a": { "a": 0, "k": [0, 0, 0] }, "r": { "a": 0, "k": 0 }, "o": { "a": 0, "k": 100 }
        });
        let shapes = json!([{ "ty": "gr", "it": [
            { "ty": "el", "p": { "a": 0, "k": [0, 0] }, "s": { "a": 0, "k": [100, 100] } },
            red_fill(),
            { "ty": "tr", "p": { "a": 0, "k": [0, 0] }, "a": { "a": 0, "k": [0, 0] }, "s": { "a": 0, "k": [100, 100] },
              "r": { "a": 0, "k": 0 }, "o": { "a": 0, "k": 100 } }
        ]}]);
        let t = run(&file(json!([shape_layer(ks, shapes)])));
        loads(&t);
        let s = &t.scene["shapes"][0];
        assert_eq!(t.scene["loop"], json!(2.0));
        assert_eq!(s["kind"], "circle");
        assert_eq!(s["fill"]["from"], "#FF0000");
        assert_eq!(
            s["at"],
            json!({ "keys": [[0.0, [0.25, 0.25]], [1.0, [0.75, 0.5], [0.4, 0.0, 0.2, 1.0]]] })
        );
        assert_eq!(
            s["size"],
            json!({ "keys": [[0.0, [0.25, 0.25]], [1.0, [0.5, 0.5], [0.4, 0.0, 0.2, 1.0]]] })
        );
        // Halfway in time is well past halfway in value with this ease.
        let at = point(&t, 0, "at").at(0.5);
        assert!(at[0] > 0.6, "{at:?}");
    }

    #[test]
    fn a_rect_in_a_group_in_a_parented_layer_composes_every_transform() {
        let parent = json!({ "ind": 1, "ty": 3, "ks": {
            "p": { "a": 0, "k": [200, 200, 0] }, "r": { "a": 0, "k": 90 }, "o": { "a": 0, "k": 50 } },
            "ip": 0, "op": 60, "st": 0 });
        let child = json!({ "ind": 2, "ty": 4, "parent": 1, "ks": { "p": { "a": 0, "k": [50, 0, 0] } },
        "ip": 0, "op": 60, "st": 0,
        "shapes": [{ "ty": "gr", "it": [
            { "ty": "rc", "p": { "a": 0, "k": [0, 0] }, "s": { "a": 0, "k": [40, 20] }, "r": { "a": 0, "k": 5 } },
            red_fill(),
            { "ty": "tr", "p": { "a": 0, "k": [10, 0] }, "o": { "a": 0, "k": 80 } }
        ]}]});
        let t = run(&file(json!([parent, child])));
        loads(&t);
        let s = &t.scene["shapes"][0];
        assert_eq!(s["kind"], "roundRect");
        // (50 + 10, 0) turned 90 degrees about the parent, at (200, 200): (200, 260).
        assert_eq!(s["at"], json!([0.5, 0.65]));
        assert_eq!(s["size"], json!([0.1, 0.05]));
        assert_eq!(s["rotate"], json!(90.0));
        assert_eq!(s["shape"], json!(0.25));
        // The group's 80% reaches it; the parent's 50% does not.
        assert_eq!(s["opacity"], json!(0.8));
    }

    #[test]
    fn a_gradient_fill_maps_to_a_linear_fill() {
        let shapes = json!([
            { "ty": "el", "p": { "a": 0, "k": [200, 200] }, "s": { "a": 0, "k": [200, 200] } },
            { "ty": "gf", "t": 1, "o": { "a": 0, "k": 100 },
              "s": { "a": 0, "k": [-100, 0] }, "e": { "a": 0, "k": [0, 100] },
              "g": { "p": 2, "k": { "a": 0, "k": [0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0.5] } } }
        ]);
        let t = run(&file(json!([shape_layer(json!({}), shapes.clone())])));
        loads(&t);
        let fill = &t.scene["shapes"][0]["fill"];
        assert_eq!(fill["type"], "linear");
        assert_eq!(fill["from"], "#FF0000");
        assert_eq!(fill["to"], "#0000FF80");
        assert_eq!(fill["angle"], json!(45.0));
        assert!(t.lint.is_empty(), "{:?}", t.lint);

        // The angle is in the shape's own frame: turning the layer turns the
        // shape, not the angle.
        let turned = run(&file(json!([shape_layer(json!({ "r": { "a": 0, "k": 90 } }), shapes)])));
        loads(&turned);
        assert_eq!(turned.scene["shapes"][0]["rotate"], json!(90.0));
        assert_eq!(turned.scene["shapes"][0]["fill"]["angle"], json!(45.0));
    }

    #[test]
    fn three_stops_warn_but_load() {
        let shapes = json!([
            { "ty": "el", "p": { "a": 0, "k": [200, 200] }, "s": { "a": 0, "k": [200, 200] } },
            { "ty": "gf", "t": 2, "s": { "a": 0, "k": [0, 0] }, "e": { "a": 0, "k": [100, 0] },
              "g": { "p": 3, "k": { "a": 0, "k": [0, 1, 0, 0, 0.5, 0, 1, 0, 1, 0, 0, 1] } } }
        ]);
        let v = file(json!([shape_layer(json!({}), shapes)]));
        let t = run(&v);
        loads(&t);
        assert_eq!(t.lint.len(), 1);
        assert_eq!(t.lint[0].pointer, "/layers/0/shapes/1/g");
        assert!(!t.lint[0].refused);
        let fill = &t.scene["shapes"][0]["fill"];
        assert_eq!(
            (fill["type"].as_str(), fill["from"].as_str(), fill["to"].as_str()),
            (Some("radial"), Some("#FF0000"), Some("#0000FF"))
        );
        assert!(Scene::from_lottie(v.to_string().as_bytes()).is_ok());
    }

    #[test]
    fn hold_keyframes_jump() {
        let ks = json!({ "p": { "a": 1, "k": [
            { "t": 0, "s": [100, 100], "h": 1 },
            { "t": 30, "s": [300, 100], "h": 1 },
            { "t": 45, "s": [200, 100] } ] } });
        let shapes = json!([{ "ty": "el", "s": { "a": 0, "k": [40, 40] } }, red_fill()]);
        let t = run(&file(json!([shape_layer(ks, shapes)])));
        loads(&t);
        let keys = t.scene["shapes"][0]["at"]["keys"].as_array().unwrap().clone();
        assert!(keys.iter().any(|k| k[2] == "hold"), "{keys:?}");
        let at = point(&t, 0, "at");
        assert!(near2(at.at(0.99), [0.25, 0.25]));
        assert!(near2(at.at(1.0), [0.75, 0.25]));
        assert!(near2(at.at(1.49), [0.75, 0.25]));
        assert!(near2(at.at(1.5), [0.5, 0.25]));
    }

    #[test]
    fn a_split_position_reads_x_and_y() {
        let ks = json!({ "p": { "s": true,
            "x": { "a": 1, "k": [{ "t": 0, "s": [0], "o": { "x": [0.5], "y": [0.5] }, "i": { "x": [0.5], "y": [0.5] } },
                                 { "t": 60, "s": [400] }] },
            "y": { "a": 0, "k": 100 } } });
        let shapes = json!([{ "ty": "el", "s": { "a": 0, "k": [40, 40] } }, red_fill()]);
        let t = run(&file(json!([shape_layer(ks, shapes)])));
        loads(&t);
        assert_eq!(
            t.scene["shapes"][0]["at"],
            json!({ "keys": [[0.0, [0.0, 0.25]], [2.0, [1.0, 0.25]]] })
        );
    }

    #[test]
    fn old_keyframes_with_e_play() {
        let ks = json!({ "p": { "k": [
            { "t": 0, "s": [0, 200], "e": [400, 200], "i": { "x": 0.833, "y": 0.833 }, "o": { "x": 0.167, "y": 0.167 } },
            { "t": 30 } ] } });
        let shapes = json!([{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()]);
        let t = run(&file(json!([shape_layer(ks, shapes)])));
        loads(&t);
        let at = point(&t, 0, "at");
        assert!(near2(at.at(0.0), [0.0, 0.5]));
        assert!(near2(at.at(1.0), [1.0, 0.5]));
        assert!(near2(at.at(1.8), [1.0, 0.5]));
        assert!(near2(at.at(0.5), [0.5, 0.5]));
    }

    #[test]
    fn a_precomp_shifts_time_by_its_start() {
        let inner = json!({ "ind": 1, "ty": 4, "ip": 0, "op": 200, "st": 0,
            "ks": { "p": { "a": 1, "k": [{ "t": 0, "s": [0, 0] }, { "t": 30, "s": [400, 0] }] } },
            "shapes": [{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()] });
        let mut v = file(
            json!([{ "ind": 1, "ty": 0, "refId": "comp_0", "ip": 0, "op": 90, "st": 15, "w": 400, "h": 400,
            "ks": { "p": { "k": [0, 200] } } }]),
        );
        v["op"] = json!(90);
        v["assets"] = json!([{ "id": "comp_0", "layers": [inner] }]);
        let t = run(&v);
        loads(&t);
        let at = point(&t, 0, "at");
        assert!(near2(at.at(0.25), [0.0, 0.5]));
        assert!(near2(at.at(0.5), [0.0, 0.5]));
        assert!(near2(at.at(1.0), [0.5, 0.5]));
        assert!(near2(at.at(1.5), [1.0, 0.5]));
    }

    #[test]
    fn in_and_out_points_hold_the_opacity() {
        let mut l =
            shape_layer(json!({}), json!([{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()]));
        l["ip"] = json!(15);
        l["op"] = json!(45);
        let t = run(&file(json!([l])));
        loads(&t);
        let o = number(&t, &t.scene["shapes"][0]["opacity"]);
        assert_eq!(o.at(0.0), 0.0);
        assert_eq!(o.at(0.49), 0.0);
        assert_eq!(o.at(0.5), 1.0);
        assert_eq!(o.at(1.49), 1.0);
        assert_eq!(o.at(1.5), 0.0);
        assert!(o.keys().iter().any(|k| k.2 == Ease::Hold));
    }

    #[test]
    fn a_bottom_solid_becomes_the_field() {
        let solid = json!({ "ind": 2, "ty": 1, "sc": "#203040", "sw": 400, "sh": 400, "ip": 0, "op": 60, "st": 0,
            "ks": { "a": { "k": [200, 200, 0] }, "p": { "k": [200, 200, 0] } } });
        let top =
            shape_layer(json!({}), json!([{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()]));
        let t = run(&file(json!([top, solid])));
        loads(&t);
        assert_eq!(t.scene["field"]["points"][2]["color"], "#203040");
        assert_eq!(t.scene["shapes"].as_array().unwrap().len(), 1);
        // Without the solid, no field.
        let t = run(&file(json!([shape_layer(
            json!({}),
            json!([{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()])
        )])));
        assert!(t.scene.get("field").is_none());
    }

    #[test]
    fn shapes_draw_bottom_first() {
        let blue = json!({ "ty": "fl", "c": { "k": [0, 0, 1, 1] } });
        let shapes = json!([
            { "ty": "gr", "it": [{ "ty": "el", "s": { "k": [40, 40] } }, red_fill(), { "ty": "tr" }] },
            { "ty": "gr", "it": [{ "ty": "rc", "s": { "k": [40, 40] } }, blue, { "ty": "tr" }] }
        ]);
        let t = run(&file(json!([shape_layer(json!({}), shapes)])));
        loads(&t);
        assert_eq!(t.scene["shapes"][0]["kind"], "roundRect");
        assert_eq!(t.scene["shapes"][1]["kind"], "circle");
    }

    #[test]
    fn a_stroke_on_an_ellipse_is_an_outline() {
        let shapes = json!([
            { "ty": "el", "p": { "k": [200, 200] }, "s": { "k": [100, 100] } },
            { "ty": "st", "c": { "k": [1, 1, 1, 1] }, "o": { "k": 100 }, "w": { "k": 8 } },
            red_fill()
        ]);
        let t = run(&file(json!([shape_layer(json!({}), shapes)])));
        loads(&t);
        let s = t.scene["shapes"].as_array().unwrap();
        assert_eq!(s.len(), 2);
        assert!(s[0].get("stroke").is_none());
        assert_eq!(s[1]["stroke"], json!(0.02));
        assert_eq!(s[1]["fill"]["from"], "#FFFFFF");
    }

    #[test]
    fn a_path_layer_is_refused_where_it_is() {
        let shapes = json!([{ "ty": "gr", "it": [
            { "ty": "sh", "ks": { "a": 0, "k": { "c": true, "v": [[0, 0], [10, 0], [10, 10]], "i": [], "o": [] } } },
            red_fill(), { "ty": "tr" } ] }]);
        let v = file(json!([shape_layer(json!({}), shapes)]));
        let t = run(&v);
        assert!(!t.loadable());
        let l = t.lint.iter().find(|l| l.refused).unwrap();
        assert_eq!(l.pointer, "/layers/0/shapes/0/it/0");
        assert_eq!(l.feature, "sh path");
        let e = Scene::from_lottie(v.to_string().as_bytes()).unwrap_err();
        assert_eq!(e.pointer, "/layers/0/shapes/0/it/0");
    }

    #[test]
    fn refused_features_each_get_a_line() {
        let mut l = shape_layer(
            json!({ "o": { "a": 0, "k": 100, "x": "wiggle(2, 10)" } }),
            json!([{ "ty": "el", "s": { "k": [40, 40] } }, { "ty": "tm" }, red_fill()]),
        );
        l["masksProperties"] = json!([{ "mode": "a" }]);
        l["tt"] = json!(1);
        l["ef"] = json!([{ "ty": 5 }]);
        let text = json!({ "ind": 3, "ty": 5, "ip": 0, "op": 60, "st": 0, "ks": {} });
        let t = run(&file(json!([l, text])));
        let found: Vec<(&str, &str)> = t
            .lint
            .iter()
            .filter(|l| l.refused)
            .map(|l| (l.pointer.as_str(), l.feature.as_str()))
            .collect();
        for want in [
            ("/layers/0/ks/o/x", "expression"),
            ("/layers/0/masksProperties", "mask"),
            ("/layers/0/tt", "matte"),
            ("/layers/0/ef", "effects"),
            ("/layers/0/shapes/1", "tm trim"),
            ("/layers/1", "text layer"),
        ] {
            assert!(found.contains(&want), "{want:?} not in {found:?}");
        }
    }

    #[test]
    fn more_than_16_shapes_is_refused_but_the_scene_still_parses() {
        let shapes: Vec<Value> = (0..17)
            .map(|i| json!({ "ty": "gr", "it": [{ "ty": "el", "p": { "k": [i * 20, 100] }, "s": { "k": [10, 10] } }, red_fill(), { "ty": "tr" }] }))
            .collect();
        let t = run(&file(json!([shape_layer(json!({}), Value::Array(shapes))])));
        assert!(!t.loadable());
        assert!(t.lint.iter().any(|l| l.refused && l.feature == "shapes"));
        assert!(Scene::from_value(&t.scene).is_ok());
    }

    #[test]
    fn not_lottie_is_an_error() {
        assert!(translate(b"{\"v\": \"5.7\"}").is_err());
        assert!(translate(b"[1, 2]").is_err());
        assert!(translate(b"nope").is_err());
        // Only refused content still translates, with lint.
        let t = run(&file(json!([{ "ty": 2, "ind": 1, "ks": {}, "ip": 0, "op": 60, "st": 0 }])));
        assert!(!t.loadable());
    }

    #[test]
    fn the_orbs_fixture_loads() {
        let bytes = include_bytes!("../../tests/fixtures/lottie/orbs.json");
        assert!(bytes.len() <= 300 * 1024);
        let t = translate(bytes).unwrap();
        loads(&t);
        assert!(t.lint.is_empty(), "{:#?}", t.lint);
        assert!(t.scene.get("field").is_some());
        let shapes = t.scene["shapes"].as_array().unwrap();
        assert!((3..=5).contains(&shapes.len()));
        assert_eq!(t.scene["loop"], json!(6.0));
        let scene = Scene::from_lottie(bytes).unwrap();
        assert!(scene.animated());
        // Every orb moves and stays within its keys' limit.
        for s in shapes {
            assert!(s["at"].get("keys").is_some(), "{s}");
            assert!(s["at"]["keys"].as_array().unwrap().len() <= MAX_KEYS);
        }
    }
}
