//! Motion scenes (plans/cmux-next/motion-scenes.md): a live wallpaper written
//! as data. `scene.json` (or a Lottie file, [`lottie`]) is parsed into a
//! [`Scene`]; a [`Player`] evaluates its keyframes and steps its physics each
//! frame and packs the 2048-byte `Scene` block (`scene_prelude.wgsl`) that the
//! first-party `scene-engine` program draws in one pass.

pub mod lottie;
pub mod physics;
pub mod value;

use crate::frame::FrameInput;
use crate::manifest::{ManifestError, ManifestErrorKind, Result, err, required, string};
use physics::{Pose, World, WorldSpec};
use serde_json::Value;
use value::{ColorSpec, Theme, Track, opt, strict};

/// `vec4<f32>` rows in the `Scene` block.
pub const SCENE_ROWS: usize = 128;
/// Floats in the `Scene` block.
pub const SCENE_FLOATS: usize = SCENE_ROWS * 4;
/// Bytes in the `Scene` block.
pub const SCENE_BYTES: usize = SCENE_FLOATS * 4;
/// At most this many shapes.
pub const MAX_SHAPES: usize = 16;
/// At most this many guides.
pub const MAX_GUIDES: usize = 8;
/// Field points: exactly this many.
pub const FIELD_POINTS: usize = 4;
/// Rope points the block holds (two ropes of up to 7 segments).
pub const MAX_ROPE_POINTS: usize = 16;
/// The largest `scene.json` read.
pub const MAX_SCENE_BYTES: usize = 64 * 1024;
/// The loop when the scene names none, seconds.
pub const DEFAULT_LOOP_S: f32 = 10.0;

const ROW_HEADER: usize = 0;
const ROW_GRAIN: usize = 1;
const ROW_FIELD: usize = 2;
const ROW_LIGHT: usize = 10;
const ROW_SHAPES: usize = 12;
const SHAPE_ROWS: usize = 5;
const ROW_GUIDES: usize = 92;
const GUIDE_ROWS: usize = 3;
/// Rope points, two to a row: rope 0's, then rope 1's.
const ROW_ROPE_POINTS: usize = 116;
const ROW_ROPES: usize = 124;
const ROW_IMAGE: usize = 126;

/// A shape's kind; the numbers are the block's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShapeKind {
    Circle = 1,
    HalfDisc = 2,
    Lens = 3,
    Eye = 4,
    Arcs = 5,
    RoundRect = 6,
    Cube = 7,
    Ring = 8,
}

impl ShapeKind {
    fn parse(v: &Value, at: &str) -> Result<Self> {
        Ok(match v.as_str() {
            Some("circle") => Self::Circle,
            Some("halfDisc") => Self::HalfDisc,
            Some("lens") => Self::Lens,
            Some("eye") => Self::Eye,
            Some("arcs") => Self::Arcs,
            Some("roundRect") => Self::RoundRect,
            Some("cube") => Self::Cube,
            Some("ring") => Self::Ring,
            _ => {
                return Err(err(
                    ManifestErrorKind::BadFormat,
                    at,
                    "kind is one of circle, halfDisc, lens, eye, arcs, roundRect, cube, ring",
                ));
            }
        })
    }

    /// The `shape` param's default.
    fn default_param(self) -> f32 {
        match self {
            Self::Circle | Self::HalfDisc => 0.0,
            Self::Lens => 0.5,
            Self::Eye => 0.35,
            Self::Arcs => 4.0,
            Self::RoundRect => 0.2,
            Self::Cube => 0.5,
            Self::Ring => 0.15,
        }
    }
}

/// How a shape is filled; the numbers are the block's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FillType {
    Solid = 0,
    Linear = 1,
    Radial = 2,
}

#[derive(Clone, Debug, PartialEq)]
struct FieldPoint {
    at: Track<[f32; 2]>,
    color: Track<ColorSpec>,
    radius: Track<f32>,
}

#[derive(Clone, Debug, PartialEq)]
struct Light {
    at: Track<[f32; 2]>,
    color: Track<ColorSpec>,
    intensity: Track<f32>,
    radius: Track<f32>,
    follow: f32,
}

#[derive(Clone, Debug, PartialEq)]
struct Shape {
    kind: ShapeKind,
    at: Track<[f32; 2]>,
    size: Track<[f32; 2]>,
    rotate: Track<f32>,
    fill: FillType,
    from: Track<ColorSpec>,
    to: Track<ColorSpec>,
    angle: Track<f32>,
    opacity: Track<f32>,
    soften: Track<f32>,
    stroke: Track<f32>,
    lit: Track<f32>,
    param: Track<f32>,
    body: Option<usize>,
}

#[derive(Clone, Debug, PartialEq)]
struct Guide {
    from: Track<[f32; 2]>,
    to: Track<[f32; 2]>,
    width: Track<f32>,
    opacity: Track<f32>,
    color: Track<ColorSpec>,
    handles: bool,
    dash: Track<f32>,
}

/// The image slot as written.
#[derive(Clone, Debug, PartialEq)]
pub struct ImageSpec {
    /// What the host draws into it (`badge`: the person's avatar and name).
    pub slot: String,
    body: Option<usize>,
    inset: f32,
}

/// A checked scene.
#[derive(Clone, Debug, PartialEq)]
pub struct Scene {
    loop_s: f32,
    points: Vec<FieldPoint>,
    warp: Track<f32>,
    grain_amount: Track<f32>,
    grain_size: Track<f32>,
    grain_animated: bool,
    light: Option<Light>,
    shapes: Vec<Shape>,
    guides: Vec<Guide>,
    physics: Option<WorldSpec>,
    image: Option<ImageSpec>,
}

fn list<'a>(o: &'a serde_json::Map<String, Value>, key: &str, max: usize) -> Result<&'a [Value]> {
    let Some(v) = o.get(key) else { return Ok(&[]) };
    let a = v
        .as_array()
        .ok_or_else(|| err(ManifestErrorKind::WrongType, format!("/{key}"), "must be an array"))?;
    if a.len() > max {
        return Err(err(
            ManifestErrorKind::OutOfRange,
            format!("/{key}"),
            format!("at most {max}"),
        ));
    }
    Ok(a)
}

fn bool_at(v: &Value, at: &str) -> Result<bool> {
    v.as_bool().ok_or_else(|| err(ManifestErrorKind::WrongType, at, "must be true or false"))
}

/// Places run a little past the backdrop (shapes may sit half off it).
const PLACE: (f64, f64) = (-2.0, 3.0);
/// Sizes, widths and lengths in shorter sides.
const SIZE: (f64, f64) = (0.0, 4.0);

impl Scene {
    /// Parses and checks `scene.json`'s bytes.
    pub fn parse(json: &[u8]) -> Result<Self> {
        if json.len() > MAX_SCENE_BYTES {
            return Err(err(
                ManifestErrorKind::NotJson,
                "",
                format!("scene.json is larger than {} KiB", MAX_SCENE_BYTES / 1024),
            ));
        }
        let v: Value = serde_json::from_slice(json)
            .map_err(|e| err(ManifestErrorKind::NotJson, "", format!("not JSON: {e}")))?;
        Self::from_value(&v)
    }

    /// A Lottie file's scene: refused when any lint line refuses it (the
    /// error names the first; [`lottie::translate`] gives them all).
    pub fn from_lottie(json: &[u8]) -> Result<Self> {
        let t = lottie::translate(json)?;
        if let Some(l) = t.lint.iter().find(|l| l.refused) {
            return Err(err(
                ManifestErrorKind::BadFormat,
                l.pointer.clone(),
                format!("{} ({}) has no scene equivalent", l.message, l.feature),
            ));
        }
        Self::from_value(&t.scene)
    }

    /// Checks a parsed `scene.json`.
    pub fn from_value(v: &Value) -> Result<Self> {
        let o = strict(
            v,
            "",
            &["loop", "field", "grain", "light", "shapes", "guides", "physics", "image"],
        )?;
        let loop_s =
            opt(o, "", "loop", DEFAULT_LOOP_S, |v, at| crate::manifest::number(v, at, 0.5, 600.0))?;

        let (points, warp) = match o.get("field") {
            None => (Vec::new(), Track::constant(0.0)),
            Some(f) => {
                let fo = strict(f, "/field", &["points", "warp"])?;
                let pts = required(fo, "/field", "points")?.as_array().ok_or_else(|| {
                    err(ManifestErrorKind::WrongType, "/field/points", "must be an array")
                })?;
                if pts.len() != FIELD_POINTS {
                    return Err(err(
                        ManifestErrorKind::OutOfRange,
                        "/field/points",
                        format!("must have {FIELD_POINTS} points"),
                    ));
                }
                let mut points = Vec::with_capacity(FIELD_POINTS);
                for (i, p) in pts.iter().enumerate() {
                    let at = format!("/field/points/{i}");
                    let po = strict(p, &at, &["at", "color", "radius"])?;
                    points.push(FieldPoint {
                        at: Track::point(
                            required(po, &at, "at")?,
                            &format!("{at}/at"),
                            loop_s,
                            PLACE.0,
                            PLACE.1,
                        )?,
                        color: Track::color(
                            required(po, &at, "color")?,
                            &format!("{at}/color"),
                            loop_s,
                        )?,
                        radius: opt(po, &at, "radius", Track::constant(0.9), |v, a| {
                            Track::number(v, a, loop_s, 0.01, SIZE.1)
                        })?,
                    });
                }
                let warp = opt(fo, "/field", "warp", Track::constant(0.0), |v, a| {
                    Track::number(v, a, loop_s, 0.0, 1.0)
                })?;
                (points, warp)
            }
        };

        let (grain_amount, grain_size, grain_animated) = match o.get("grain") {
            None => (Track::constant(0.0), Track::constant(1.0), false),
            Some(g) => {
                let go = strict(g, "/grain", &["amount", "size", "animated"])?;
                (
                    opt(go, "/grain", "amount", Track::constant(0.1), |v, a| {
                        Track::number(v, a, loop_s, 0.0, 1.0)
                    })?,
                    opt(go, "/grain", "size", Track::constant(1.0), |v, a| {
                        Track::number(v, a, loop_s, 0.5, 8.0)
                    })?,
                    opt(go, "/grain", "animated", false, bool_at)?,
                )
            }
        };

        let light = match o.get("light") {
            None => None,
            Some(l) => {
                let lo =
                    strict(l, "/light", &["at", "color", "intensity", "radius", "followPointer"])?;
                Some(Light {
                    at: Track::point(
                        required(lo, "/light", "at")?,
                        "/light/at",
                        loop_s,
                        PLACE.0,
                        PLACE.1,
                    )?,
                    color: opt(
                        lo,
                        "/light",
                        "color",
                        Track::constant(ColorSpec::fixed([1.0; 4])),
                        |v, a| Track::color(v, a, loop_s),
                    )?,
                    intensity: opt(lo, "/light", "intensity", Track::constant(0.5), |v, a| {
                        Track::number(v, a, loop_s, 0.0, 4.0)
                    })?,
                    radius: opt(lo, "/light", "radius", Track::constant(0.8), |v, a| {
                        Track::number(v, a, loop_s, 0.01, SIZE.1)
                    })?,
                    follow: opt(lo, "/light", "followPointer", 0.0, |v, a| {
                        crate::manifest::number(v, a, 0.0, 1.0)
                    })?,
                })
            }
        };

        let physics = match o.get("physics") {
            None => None,
            Some(p) => Some(physics::parse(p, "/physics")?),
        };
        let body_ref = |o: &serde_json::Map<String, Value>, at: &str| -> Result<Option<usize>> {
            let Some(b) = o.get("body") else { return Ok(None) };
            let at = format!("{at}/body");
            let id = b.as_str().ok_or_else(|| {
                err(ManifestErrorKind::WrongType, at.as_str(), "must be a body id")
            })?;
            physics.as_ref().and_then(|w| w.body_index(id)).map(Some).ok_or_else(|| {
                err(ManifestErrorKind::BadFormat, at, format!("no physics body {id:?}"))
            })
        };

        let mut shapes = Vec::new();
        for (i, s) in list(o, "shapes", MAX_SHAPES)?.iter().enumerate() {
            let at = format!("/shapes/{i}");
            let so = strict(
                s,
                &at,
                &[
                    "kind", "at", "size", "rotate", "fill", "opacity", "soften", "stroke", "lit",
                    "shape", "body",
                ],
            )?;
            let kind = ShapeKind::parse(required(so, &at, "kind")?, &format!("{at}/kind"))?;
            let body = body_ref(so, &at)?;
            let default_at = if body.is_some() { [0.0, 0.0] } else { [0.5, 0.5] };
            let fat = format!("{at}/fill");
            let (fill, from, to, angle) = match so.get("fill") {
                None => {
                    let c = Track::constant(ColorSpec::parse(&Value::from("accent"), &fat)?);
                    (FillType::Solid, c.clone(), c, Track::constant(0.0))
                }
                Some(f) if f.is_string() => {
                    let c = Track::color(f, &fat, loop_s)?;
                    (FillType::Solid, c.clone(), c, Track::constant(0.0))
                }
                Some(f) => {
                    let fo = strict(f, &fat, &["type", "from", "to", "angle", "color"])?;
                    let ty = match fo.get("type").and_then(Value::as_str) {
                        None | Some("solid") => FillType::Solid,
                        Some("linear") => FillType::Linear,
                        Some("radial") => FillType::Radial,
                        Some(_) => {
                            return Err(err(
                                ManifestErrorKind::BadFormat,
                                format!("{fat}/type"),
                                "type is solid, linear or radial",
                            ));
                        }
                    };
                    let from = match (fo.get("from"), fo.get("color")) {
                        (Some(c), _) | (None, Some(c)) => {
                            Track::color(c, &format!("{fat}/from"), loop_s)?
                        }
                        (None, None) => {
                            return Err(err(
                                ManifestErrorKind::Missing,
                                fat,
                                "from (or color) is required",
                            ));
                        }
                    };
                    let to = match fo.get("to") {
                        None => from.clone(),
                        Some(c) => Track::color(c, &format!("{fat}/to"), loop_s)?,
                    };
                    let angle = opt(fo, &fat, "angle", Track::constant(90.0), |v, a| {
                        Track::number(v, a, loop_s, -3600.0, 3600.0)
                    })?;
                    (ty, from, to, angle)
                }
            };
            let param_max = if kind == ShapeKind::Arcs { 8.0 } else { 1.0 };
            shapes.push(Shape {
                kind,
                at: opt(so, &at, "at", Track::constant(default_at), |v, a| {
                    Track::point(v, a, loop_s, PLACE.0, PLACE.1)
                })?,
                size: Track::point(
                    required(so, &at, "size")?,
                    &format!("{at}/size"),
                    loop_s,
                    SIZE.0,
                    SIZE.1,
                )?,
                rotate: opt(so, &at, "rotate", Track::constant(0.0), |v, a| {
                    Track::number(v, a, loop_s, -3600.0, 3600.0)
                })?,
                fill,
                from,
                to,
                angle,
                opacity: opt(so, &at, "opacity", Track::constant(1.0), |v, a| {
                    Track::number(v, a, loop_s, 0.0, 1.0)
                })?,
                soften: opt(so, &at, "soften", Track::constant(0.0), |v, a| {
                    Track::number(v, a, loop_s, 0.0, 1.0)
                })?,
                stroke: opt(so, &at, "stroke", Track::constant(0.0), |v, a| {
                    Track::number(v, a, loop_s, 0.0, 0.5)
                })?,
                lit: opt(so, &at, "lit", Track::constant(0.0), |v, a| {
                    Track::number(v, a, loop_s, 0.0, 1.0)
                })?,
                param: opt(so, &at, "shape", Track::constant(kind.default_param()), |v, a| {
                    Track::number(v, a, loop_s, 0.0, param_max)
                })?,
                body,
            });
        }

        let mut guides = Vec::new();
        for (i, g) in list(o, "guides", MAX_GUIDES)?.iter().enumerate() {
            let at = format!("/guides/{i}");
            let go =
                strict(g, &at, &["from", "to", "width", "opacity", "color", "handles", "dash"])?;
            guides.push(Guide {
                from: Track::point(
                    required(go, &at, "from")?,
                    &format!("{at}/from"),
                    loop_s,
                    PLACE.0,
                    PLACE.1,
                )?,
                to: Track::point(
                    required(go, &at, "to")?,
                    &format!("{at}/to"),
                    loop_s,
                    PLACE.0,
                    PLACE.1,
                )?,
                width: opt(go, &at, "width", Track::constant(0.0015), |v, a| {
                    Track::number(v, a, loop_s, 0.0, 0.05)
                })?,
                opacity: opt(go, &at, "opacity", Track::constant(0.5), |v, a| {
                    Track::number(v, a, loop_s, 0.0, 1.0)
                })?,
                color: opt(
                    go,
                    &at,
                    "color",
                    Track::constant(ColorSpec::parse(&Value::from("ink"), &at)?),
                    |v, a| Track::color(v, a, loop_s),
                )?,
                handles: opt(go, &at, "handles", false, bool_at)?,
                dash: opt(go, &at, "dash", Track::constant(0.0), |v, a| {
                    Track::number(v, a, loop_s, 0.0, 0.2)
                })?,
            });
        }

        let image = match o.get("image") {
            None => None,
            Some(i) => {
                let io = strict(i, "/image", &["slot", "body", "inset"])?;
                let slot = string(required(io, "/image", "slot")?, "/image/slot", 32)?;
                if slot != "badge" {
                    return Err(err(
                        ManifestErrorKind::BadFormat,
                        "/image/slot",
                        "the one slot is \"badge\"",
                    ));
                }
                Some(ImageSpec {
                    slot,
                    body: body_ref(io, "/image")?,
                    inset: opt(io, "/image", "inset", 0.0, |v, a| {
                        crate::manifest::number(v, a, 0.0, 0.5)
                    })?,
                })
            }
        };
        if physics.as_ref().is_some_and(|w| {
            w.ropes.iter().map(|r| r.segments + 1).sum::<usize>() > MAX_ROPE_POINTS
        }) {
            return Err(err(
                ManifestErrorKind::OutOfRange,
                "/physics/ropes",
                format!("the ropes have more than {MAX_ROPE_POINTS} points in all"),
            ));
        }

        Ok(Self {
            loop_s,
            points,
            warp,
            grain_amount,
            grain_size,
            grain_animated,
            light,
            shapes,
            guides,
            physics,
            image,
        })
    }

    /// The loop, seconds.
    pub fn loop_seconds(&self) -> f32 {
        self.loop_s
    }

    /// The image slot, if the scene shows one.
    pub fn image(&self) -> Option<&ImageSpec> {
        self.image.as_ref()
    }

    /// Whether the scene has physics.
    pub fn has_physics(&self) -> bool {
        self.physics.is_some()
    }

    /// Whether anything moves with time: a keyframed value, moving grain or a
    /// field warp. A scene that does not (and whose physics sleeps) is at rest.
    pub fn animated(&self) -> bool {
        let f = |t: &Track<f32>| t.is_animated();
        let p = |t: &Track<[f32; 2]>| t.is_animated();
        let c = |t: &Track<ColorSpec>| t.is_animated();
        self.grain_animated
            || f(&self.warp)
            || self.warp.at(0.0) > 0.0
            || f(&self.grain_amount)
            || f(&self.grain_size)
            || self.points.iter().any(|q| p(&q.at) || c(&q.color) || f(&q.radius))
            || self
                .light
                .as_ref()
                .is_some_and(|l| p(&l.at) || c(&l.color) || f(&l.intensity) || f(&l.radius))
            || self.shapes.iter().any(|s| {
                p(&s.at)
                    || p(&s.size)
                    || f(&s.rotate)
                    || c(&s.from)
                    || c(&s.to)
                    || f(&s.angle)
                    || f(&s.opacity)
                    || f(&s.soften)
                    || f(&s.stroke)
                    || f(&s.lit)
                    || f(&s.param)
            })
            || self.guides.iter().any(|g| {
                p(&g.from) || p(&g.to) || f(&g.width) || f(&g.opacity) || c(&g.color) || f(&g.dash)
            })
    }
}

/// A scene running in one backdrop: its physics world, if any, lives here.
#[derive(Clone, Debug)]
pub struct Player {
    scene: Scene,
    world: Option<World>,
    rope_scratch: Vec<[f32; 2]>,
}

fn set(out: &mut [f32; SCENE_FLOATS], row: usize, v: [f32; 4]) {
    let at = row * 4;
    if let Some(slot) = out.get_mut(at..at + 4) {
        for (s, x) in slot.iter_mut().zip(v) {
            *s = if x.is_finite() { x } else { 0.0 };
        }
    }
}

#[allow(clippy::cast_precision_loss, reason = "counts and flags are at most a few hundred")]
fn count(n: usize) -> f32 {
    n as f32
}

/// `p` turned by `angle` radians.
fn rotate(p: [f32; 2], angle: f32) -> [f32; 2] {
    let (s, c) = angle.sin_cos();
    [p[0] * c - p[1] * s, p[0] * s + p[1] * c]
}

impl Player {
    pub fn new(scene: Scene) -> Self {
        let world = scene.physics.as_ref().map(World::new);
        Self { scene, world, rope_scratch: Vec::with_capacity(MAX_ROPE_POINTS) }
    }

    pub fn scene(&self) -> &Scene {
        &self.scene
    }

    /// True when nothing would change on screen without input: the scene
    /// has no motion and its physics, if any, sleeps. The scheduler then
    /// holds it (`HoldReason::AtRest`).
    pub fn at_rest(&self) -> bool {
        // A light that follows the pointer answers it, so that scene is left
        // to the scheduler's own idle rule.
        let follows = self.scene.light.as_ref().is_some_and(|l| l.follow > 0.0);
        !self.scene.animated() && !follows && self.world.as_ref().is_none_or(World::asleep)
    }

    /// [`Player::evaluate_at`] with the physics clock read from `frame.time`.
    pub fn evaluate(&mut self, frame: &FrameInput, out: &mut [f32; SCENE_FLOATS]) {
        self.evaluate_at(frame, f64::from(frame.time), out);
    }

    // perf-hot: 50us scene-evaluate
    /// Steps the physics to `now` (the host's monotonic seconds: an f64, so
    /// the fixed step stays exact after hours shown; `frame.time` is f32) and
    /// packs the block for `frame`.
    pub fn evaluate_at(&mut self, frame: &FrameInput, now: f64, out: &mut [f32; SCENE_FLOATS]) {
        out.fill(0.0);
        let (w, h) = (frame.width.max(1.0), frame.height.max(1.0));
        let s = w.min(h);
        let t = frame.time.rem_euclid(self.scene.loop_s);
        let theme = Theme { ink: frame.ink, paper: frame.paper, accent: frame.accent };
        let place = |p: [f32; 2]| [p[0] * w, p[1] * h];
        let pointer = [frame.pointer_x, frame.pointer_y];

        if let Some(world) = self.world.as_mut() {
            world.advance(now, w, h, pointer, frame.button_down);
        }
        let pose = |i: Option<usize>| -> Option<Pose> { Some(self.world.as_ref()?.pose(i?)) };

        let sc = &self.scene;
        // Still grain keeps seed 0; moving grain gets a new seed each frame.
        let grain_seed =
            if sc.grain_animated { (frame.frame_number * 0.618_034).fract() + 0.001 } else { 0.0 };
        set(
            out,
            ROW_GRAIN,
            [
                sc.grain_amount.at(t),
                sc.grain_size.at(t) * frame.backing_scale.max(0.25),
                grain_seed,
                if sc.image.is_some() { 1.0 } else { 0.0 },
            ],
        );
        // A field point's spare lane: point 0 carries the warp, point 1 the loop phase.
        let spare = [sc.warp.at(t), t / sc.loop_s, 0.0, 0.0];
        for (i, p) in sc.points.iter().enumerate() {
            let at = place(p.at.at(t));
            let c = p.color.at(t, &theme);
            set(
                out,
                ROW_FIELD + 2 * i,
                [at[0], at[1], p.radius.at(t) * s, spare.get(i).copied().unwrap_or(0.0)],
            );
            set(out, ROW_FIELD + 2 * i + 1, [c[0], c[1], c[2], 1.0]);
        }
        if let Some(l) = &sc.light {
            let home = place(l.at.at(t));
            let follow = l.follow * frame.presence.clamp(0.0, 1.0);
            let at = value::lerp2(home, pointer, follow);
            let c = l.color.at(t, &theme);
            set(out, ROW_LIGHT, [at[0], at[1], l.radius.at(t) * s, l.intensity.at(t)]);
            set(out, ROW_LIGHT + 1, [c[0], c[1], c[2], 0.0]);
        }
        for (i, sh) in sc.shapes.iter().enumerate() {
            let row = ROW_SHAPES + SHAPE_ROWS * i;
            let size = sh.size.at(t);
            let mut rot = sh.rotate.at(t).to_radians();
            let mut squash = 1.0;
            let center = match pose(sh.body) {
                Some(b) => {
                    let off =
                        rotate([sh.at.at(t)[0] * s * b.squash, sh.at.at(t)[1] * s], b.rotation);
                    rot += b.rotation;
                    squash = b.squash;
                    [b.x + off[0], b.y + off[1]]
                }
                None => place(sh.at.at(t)),
            };
            let c0 = sh.from.at(t, &theme);
            let c1 = sh.to.at(t, &theme);
            let kind = sh.kind as u8;
            let fill = sh.fill as u8;
            set(out, row, [f32::from(kind), center[0], center[1], rot]);
            set(out, row + 1, [size[0] * s * 0.5, size[1] * s * 0.5, sh.param.at(t), squash]);
            set(out, row + 2, [c0[0], c0[1], c0[2], sh.opacity.at(t) * c0[3]]);
            set(out, row + 3, [c1[0], c1[1], c1[2], f32::from(fill)]);
            set(
                out,
                row + 4,
                [
                    sh.angle.at(t).to_radians(),
                    sh.soften.at(t) * s,
                    sh.stroke.at(t) * s,
                    sh.lit.at(t),
                ],
            );
        }
        for (i, g) in sc.guides.iter().enumerate() {
            let row = ROW_GUIDES + GUIDE_ROWS * i;
            let (a, b) = (place(g.from.at(t)), place(g.to.at(t)));
            let c = g.color.at(t, &theme);
            set(out, row, [a[0], a[1], b[0], b[1]]);
            set(
                out,
                row + 1,
                [
                    g.width.at(t) * s,
                    g.opacity.at(t) * c[3],
                    if g.handles { 1.0 } else { 0.0 },
                    g.dash.at(t) * s,
                ],
            );
            set(out, row + 2, [c[0], c[1], c[2], 0.0]);
        }
        let mut rope_counts = [0_usize; 2];
        if let (Some(world), Some(spec)) = (self.world.as_ref(), sc.physics.as_ref()) {
            let mut points: [[f32; 2]; MAX_ROPE_POINTS] = [[0.0; 2]; MAX_ROPE_POINTS];
            let mut n = 0;
            for (r, rope) in spec.ropes.iter().enumerate().take(2) {
                self.rope_scratch.clear();
                world.rope_points(r, &mut self.rope_scratch);
                for (slot, p) in points.iter_mut().skip(n).zip(&self.rope_scratch) {
                    *slot = *p;
                    n += 1;
                    if let Some(c) = rope_counts.get_mut(r) {
                        *c += 1;
                    }
                }
                let c = rope.color.resolve(&theme);
                set(out, ROW_ROPES + r, [c[0], c[1], c[2], rope.width * s]);
            }
            for (i, pair) in points.chunks(2).enumerate() {
                if let [a, b] = pair {
                    set(out, ROW_ROPE_POINTS + i, [a[0], a[1], b[0], b[1]]);
                }
            }
        }
        if let Some(img) = &sc.image {
            let b = pose(img.body).unwrap_or(Pose {
                x: w * 0.5,
                y: h * 0.5,
                rotation: 0.0,
                squash: 1.0,
                half_w: s * 0.1,
                half_h: s * 0.14,
            });
            let inset = img.inset * s;
            set(
                out,
                ROW_IMAGE,
                [b.x, b.y, (b.half_w - inset).max(0.0), (b.half_h - inset).max(0.0)],
            );
            set(out, ROW_IMAGE + 1, [b.rotation, b.squash, inset * 0.5, 1.0]);
        }
        set(out, ROW_HEADER, {
            let [r0, r1] = rope_counts;
            [count(sc.shapes.len()), count(sc.guides.len()), count(r0), count(r1)]
        });
    }
}

/// Reads a wallpaper's scene: `scene.json` bytes, or a Lottie file's.
pub fn load(manifest: &crate::Manifest, bytes: &[u8]) -> std::result::Result<Scene, ManifestError> {
    if manifest.lottie.is_some() { Scene::from_lottie(bytes) } else { Scene::parse(bytes) }
}

#[cfg(test)]
mod tests;
