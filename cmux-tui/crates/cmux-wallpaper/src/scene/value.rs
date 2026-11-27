//! A scene's animatable values (plans/cmux-next/motion-scenes.md, "The scene
//! file"): a value, or `{"keys": [[t, value, ease?], ...]}`; the easings; and
//! colors, which may name the theme's ink, paper or accent.

use crate::manifest::{ManifestErrorKind, Result, err, object, only_keys, required};
use serde_json::Value;

/// At most this many keys in one track.
pub const MAX_KEYS: usize = 256;

/// How a key is reached from the one before it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Ease {
    Linear,
    /// Keeps the previous value until the key's time.
    Hold,
    /// Cubic ease in.
    In,
    /// Cubic ease out.
    Out,
    /// Cubic ease in and out.
    InOut,
    /// Half a sine wave, in and out.
    Sine,
    /// A CSS cubic-bezier: `[x1, y1, x2, y2]`, x within 0..1.
    Bezier([f32; 4]),
}

impl Ease {
    pub(crate) fn parse(v: &Value, at: &str) -> Result<Self> {
        if let Some(a) = v.as_array() {
            if a.len() != 4 {
                return Err(err(
                    ManifestErrorKind::OutOfRange,
                    at,
                    "a cubic-bezier is [x1, y1, x2, y2]",
                ));
            }
            let mut b = [0.0; 4];
            for (i, (slot, n)) in b.iter_mut().zip(a).enumerate() {
                let (min, max) = if i % 2 == 0 { (0.0, 1.0) } else { (-4.0, 5.0) };
                *slot = crate::manifest::number(n, &format!("{at}/{i}"), min, max)?;
            }
            return Ok(Self::Bezier(b));
        }
        match v.as_str() {
            Some("linear") => Ok(Self::Linear),
            Some("hold") => Ok(Self::Hold),
            Some("in") => Ok(Self::In),
            Some("out") => Ok(Self::Out),
            Some("inOut") => Ok(Self::InOut),
            Some("sine") => Ok(Self::Sine),
            Some(other) => Err(err(
                ManifestErrorKind::BadFormat,
                at,
                format!(
                    "{other:?} is not an ease: linear, hold, in, out, inOut, sine or [x1, y1, x2, y2]"
                ),
            )),
            None => Err(err(
                ManifestErrorKind::WrongType,
                at,
                "must be an ease name or [x1, y1, x2, y2]",
            )),
        }
    }

    /// The eased share for `f` (0..1).
    pub fn apply(self, f: f32) -> f32 {
        let f = f.clamp(0.0, 1.0);
        match self {
            Self::Linear => f,
            Self::Hold => {
                if f >= 1.0 {
                    1.0
                } else {
                    0.0
                }
            }
            Self::In => f * f * f,
            Self::Out => 1.0 - (1.0 - f).powi(3),
            Self::InOut => {
                if f < 0.5 {
                    4.0 * f * f * f
                } else {
                    1.0 - (-2.0 * f + 2.0).powi(3) / 2.0
                }
            }
            Self::Sine => 0.5 - 0.5 * (std::f32::consts::PI * f).cos(),
            Self::Bezier([x1, y1, x2, y2]) => bezier(x1, y1, x2, y2, f),
        }
    }
}

/// One coordinate of a cubic bezier from 0 to 1 with control values `a`, `b`.
fn cubic(a: f32, b: f32, u: f32) -> f32 {
    let v = 1.0 - u;
    3.0 * v * v * u * a + 3.0 * v * u * u * b + u * u * u
}

/// y for x = `f` on the CSS cubic-bezier: Newton's method, bisection when it stalls.
fn bezier(x1: f32, y1: f32, x2: f32, y2: f32, f: f32) -> f32 {
    let mut u = f;
    for _ in 0..8 {
        let x = cubic(x1, x2, u) - f;
        let v = 1.0 - u;
        let dx = 3.0 * v * v * x1 + 6.0 * v * u * (x2 - x1) + 3.0 * u * u * (1.0 - x2);
        if x.abs() < 1e-5 {
            return cubic(y1, y2, u);
        }
        if dx.abs() < 1e-6 {
            break;
        }
        u = (u - x / dx).clamp(0.0, 1.0);
    }
    let (mut lo, mut hi) = (0.0_f32, 1.0_f32);
    u = f;
    for _ in 0..24 {
        let x = cubic(x1, x2, u);
        if (x - f).abs() < 1e-5 {
            break;
        }
        if x < f {
            lo = u;
        } else {
            hi = u;
        }
        u = 0.5 * (lo + hi);
    }
    cubic(y1, y2, u)
}

/// The theme's colors, linear RGB (`FrameInput`'s ink, paper and accent).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Theme {
    pub ink: [f32; 3],
    pub paper: [f32; 3],
    pub accent: [f32; 3],
}

/// One end of a color: a fixed linear RGBA, or a theme color.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Paint {
    Fixed([f32; 4]),
    Ink,
    Paper,
    Accent,
}

impl Paint {
    fn resolve(self, theme: &Theme) -> [f32; 4] {
        let rgb1 = |c: [f32; 3]| [c[0], c[1], c[2], 1.0];
        match self {
            Self::Fixed(c) => c,
            Self::Ink => rgb1(theme.ink),
            Self::Paper => rgb1(theme.paper),
            Self::Accent => rgb1(theme.accent),
        }
    }

    fn parse(s: &str, at: &str) -> Result<Self> {
        match s {
            "ink" => return Ok(Self::Ink),
            "paper" => return Ok(Self::Paper),
            "accent" => return Ok(Self::Accent),
            _ => {}
        }
        let hex = s
            .strip_prefix('#')
            .filter(|h| (h.len() == 6 || h.len() == 8) && h.bytes().all(|b| b.is_ascii_hexdigit()));
        let Some(hex) = hex else {
            return Err(err(
                ManifestErrorKind::BadFormat,
                at,
                format!("{s:?} is not a color: #RRGGBB, #RRGGBBAA, ink, paper or accent"),
            ));
        };
        let byte = |i: usize| {
            hex.get(i..i + 2)
                .and_then(|b| u8::from_str_radix(b, 16).ok())
                .map_or(0.0, |b| f32::from(b) / 255.0)
        };
        let a = if hex.len() == 8 { byte(6) } else { 1.0 };
        Ok(Self::Fixed([
            crate::frame::srgb_to_linear(byte(0)),
            crate::frame::srgb_to_linear(byte(2)),
            crate::frame::srgb_to_linear(byte(4)),
            a,
        ]))
    }
}

/// A color as written: one paint, or `"a N% b"` (a with N% of b mixed in).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ColorSpec {
    pub a: Paint,
    pub b: Paint,
    /// The share of `b`, 0..1.
    pub mix: f32,
}

impl ColorSpec {
    pub const fn fixed(rgba: [f32; 4]) -> Self {
        Self { a: Paint::Fixed(rgba), b: Paint::Fixed(rgba), mix: 0.0 }
    }

    /// Linear RGBA (straight alpha) in `theme`.
    pub fn resolve(&self, theme: &Theme) -> [f32; 4] {
        let a = self.a.resolve(theme);
        if self.mix <= 0.0 {
            return a;
        }
        lerp4(a, self.b.resolve(theme), self.mix)
    }

    pub(crate) fn parse(v: &Value, at: &str) -> Result<Self> {
        let s = v
            .as_str()
            .ok_or_else(|| err(ManifestErrorKind::WrongType, at, "must be a color string"))?;
        let parts: Vec<&str> = s.split_whitespace().collect();
        match parts.as_slice() {
            [one] => {
                let p = Paint::parse(one, at)?;
                Ok(Self { a: p, b: p, mix: 0.0 })
            }
            [a, pct, b] => {
                let n = pct
                    .strip_suffix('%')
                    .and_then(|n| n.parse::<f32>().ok())
                    .filter(|n| (0.0..=100.0).contains(n))
                    .ok_or_else(|| {
                        err(
                            ManifestErrorKind::BadFormat,
                            at,
                            format!("{pct:?} must be a share like 40%"),
                        )
                    })?;
                Ok(Self { a: Paint::parse(a, at)?, b: Paint::parse(b, at)?, mix: n / 100.0 })
            }
            _ => Err(err(
                ManifestErrorKind::BadFormat,
                at,
                format!("{s:?} is not a color: a color, or \"a N% b\""),
            )),
        }
    }
}

pub(crate) fn lerp(a: f32, b: f32, f: f32) -> f32 {
    a + (b - a) * f
}

pub(crate) fn lerp2(a: [f32; 2], b: [f32; 2], f: f32) -> [f32; 2] {
    [lerp(a[0], b[0], f), lerp(a[1], b[1], f)]
}

pub(crate) fn lerp4(a: [f32; 4], b: [f32; 4], f: f32) -> [f32; 4] {
    [lerp(a[0], b[0], f), lerp(a[1], b[1], f), lerp(a[2], b[2], f), lerp(a[3], b[3], f)]
}

/// A value over the loop: one key is a constant.
#[derive(Clone, Debug, PartialEq)]
pub struct Track<K> {
    /// `(t, value, ease into it)`, by time; never empty.
    keys: Vec<(f32, K, Ease)>,
    /// The first key's value: what `sample` answers before it.
    first: K,
}

impl<K: Clone> Track<K> {
    pub fn constant(v: K) -> Self {
        Self { keys: vec![(0.0, v.clone(), Ease::Linear)], first: v }
    }

    /// The keys, by time: `(t, value, ease into it)`.
    pub fn keys(&self) -> &[(f32, K, Ease)] {
        &self.keys
    }

    /// Whether the value changes over the loop.
    pub fn is_animated(&self) -> bool {
        self.keys.len() > 1
    }

    /// `v` is a value (`key` parses it) or `{"keys": [[t, value, ease?], ...]}`,
    /// times within 0..=`loop_s`, in order.
    pub(crate) fn parse(
        v: &Value,
        at: &str,
        loop_s: f32,
        key: impl Fn(&Value, &str) -> Result<K>,
    ) -> Result<Self> {
        let Some(o) = v.as_object().filter(|o| o.contains_key("keys")) else {
            return Ok(Self::constant(key(v, at)?));
        };
        only_keys(o, at, &["keys"])?;
        let ka = format!("{at}/keys");
        let list = required(o, at, "keys")?
            .as_array()
            .ok_or_else(|| err(ManifestErrorKind::WrongType, ka.as_str(), "must be an array"))?;
        if list.is_empty() || list.len() > MAX_KEYS {
            return Err(err(
                ManifestErrorKind::OutOfRange,
                ka,
                format!("must have 1 to {MAX_KEYS} keys"),
            ));
        }
        let mut keys = Vec::with_capacity(list.len());
        let mut last = 0.0_f32;
        for (i, k) in list.iter().enumerate() {
            let kat = format!("{ka}/{i}");
            let parts = k.as_array().filter(|p| p.len() == 2 || p.len() == 3).ok_or_else(|| {
                err(
                    ManifestErrorKind::WrongType,
                    kat.as_str(),
                    "a key is [t, value] or [t, value, ease]",
                )
            })?;
            let (Some(tv), Some(vv)) = (parts.first(), parts.get(1)) else {
                return Err(err(
                    ManifestErrorKind::WrongType,
                    kat,
                    "a key is [t, value] or [t, value, ease]",
                ));
            };
            let t = crate::manifest::number(tv, &format!("{kat}/0"), 0.0, f64::from(loop_s))?;
            if t < last {
                return Err(err(
                    ManifestErrorKind::OutOfRange,
                    format!("{kat}/0"),
                    "keys must be in time order",
                ));
            }
            last = t;
            let value = key(vv, &format!("{kat}/1"))?;
            let ease = match parts.get(2) {
                None => Ease::Linear,
                Some(e) => Ease::parse(e, &format!("{kat}/2"))?,
            };
            keys.push((t, value, ease));
        }
        let Some(first) = keys.first().map(|k| k.1.clone()) else {
            return Err(err(ManifestErrorKind::OutOfRange, ka, "must have a key"));
        };
        Ok(Self { keys, first })
    }

    /// The keys around `t` (seconds into the loop) and the eased share of the
    /// way from the first to the second.
    pub fn sample(&self, t: f32) -> (&K, &K, f32) {
        let mut prev: Option<&(f32, K, Ease)> = None;
        for k in &self.keys {
            if k.0 > t {
                let Some(p) = prev else { return (&k.1, &k.1, 0.0) };
                let span = k.0 - p.0;
                let f = if span > 0.0 { (t - p.0) / span } else { 1.0 };
                return (&p.1, &k.1, k.2.apply(f));
            }
            prev = Some(k);
        }
        // At or past the last key.
        let v = prev.map_or(&self.first, |p| &p.1);
        (v, v, 0.0)
    }
}

impl Track<f32> {
    pub fn at(&self, t: f32) -> f32 {
        let (a, b, f) = self.sample(t);
        lerp(*a, *b, f)
    }

    /// A number within `min..=max`, or keys of them.
    pub(crate) fn number(v: &Value, at: &str, loop_s: f32, min: f64, max: f64) -> Result<Self> {
        Self::parse(v, at, loop_s, |v, at| crate::manifest::number(v, at, min, max))
    }
}

impl Track<[f32; 2]> {
    pub fn at(&self, t: f32) -> [f32; 2] {
        let (a, b, f) = self.sample(t);
        lerp2(*a, *b, f)
    }

    /// `[x, y]`, each within `min..=max`, or keys of them.
    pub(crate) fn point(v: &Value, at: &str, loop_s: f32, min: f64, max: f64) -> Result<Self> {
        Self::parse(v, at, loop_s, |v, at| {
            let a = v
                .as_array()
                .filter(|a| a.len() == 2)
                .ok_or_else(|| err(ManifestErrorKind::WrongType, at, "must be [x, y]"))?;
            let mut p = [0.0; 2];
            for (i, (slot, n)) in p.iter_mut().zip(a).enumerate() {
                *slot = crate::manifest::number(n, &format!("{at}/{i}"), min, max)?;
            }
            Ok(p)
        })
    }
}

impl Track<ColorSpec> {
    /// Linear RGBA in `theme`: the two keys resolved, then blended.
    pub fn at(&self, t: f32, theme: &Theme) -> [f32; 4] {
        let (a, b, f) = self.sample(t);
        if f <= 0.0 {
            return a.resolve(theme);
        }
        lerp4(a.resolve(theme), b.resolve(theme), f)
    }

    pub(crate) fn color(v: &Value, at: &str, loop_s: f32) -> Result<Self> {
        Self::parse(v, at, loop_s, ColorSpec::parse)
    }
}

/// `o[key]` parsed by `f`, or `default` when absent.
pub(crate) fn opt<T>(
    o: &serde_json::Map<String, Value>,
    at: &str,
    key: &str,
    default: T,
    f: impl FnOnce(&Value, &str) -> Result<T>,
) -> Result<T> {
    match o.get(key) {
        None => Ok(default),
        Some(v) => f(v, &format!("{at}/{key}")),
    }
}

/// `v` as an object with only `allowed` keys.
pub(crate) fn strict<'a>(
    v: &'a Value,
    at: &str,
    allowed: &[&str],
) -> Result<&'a serde_json::Map<String, Value>> {
    let o = object(v, at)?;
    only_keys(o, at, allowed)?;
    Ok(o)
}

#[cfg(test)]
#[path = "value_tests.rs"]
mod tests;
