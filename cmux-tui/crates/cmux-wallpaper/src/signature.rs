//! An agent's dot signature: a small particle glyph made from its session id,
//! drawn on sidebar rows and the running line.
//!
//! It is built on the first-party `particles` wallpaper (no second schema):
//! its variants give the accent and name, its `size` param scales the dots
//! and its `speed` param is the drift. The same id always gives the same
//! glyph, on every machine: the math is integer hashing, `+ - * /` and
//! `sqrt`, all exact in IEEE 754, and every output is rounded to 4 places.

use crate::first_party::first_party_by_id;
use crate::manifest::Manifest;

/// The wallpaper the glyph is made from.
pub const PARTICLES_ID: &str = "particles";
/// The fewest dots in a glyph.
pub const MIN_DOTS: usize = 5;
/// The most dots in a glyph.
pub const MAX_DOTS: usize = 9;
/// The smallest dot radius, a fraction of the glyph box.
pub const MIN_RADIUS: f32 = 0.06;
/// The largest dot radius, a fraction of the glyph box.
pub const MAX_RADIUS: f32 = 0.16;
/// Every dot lies inside this circle around the box's center (0.5, 0.5).
pub const DISK_RADIUS: f32 = 0.42;
/// The least space between two dots' edges.
pub const MIN_GAP: f32 = 0.02;

/// The accent of a variant that names none.
const FALLBACK_ACCENT: &str = "#3D7BFF";
/// The sampler's tries per dot.
const CANDIDATES: usize = 24;
/// How often a dot that does not fit is shrunk and tried again.
const SHRINKS: usize = 6;
/// The dots cover at most this share of the circle, so they always fit.
const AREA_SHARE: f32 = 0.30;

/// One dot as the sampler places it: centered on the origin, unrounded.
#[derive(Clone, Copy, Debug)]
struct Placed {
    x: f32,
    y: f32,
    r: f32,
    phase: f32,
}

// The wire carries every float as an f64 rounded to 4 places, so a JSON
// reader gets exactly the short decimal, not an f32's widening.
/// One dot. `x`, `y` and `r` are fractions of the glyph box, top left origin.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase")]
pub struct Dot {
    pub x: f64,
    pub y: f64,
    /// The radius.
    pub r: f64,
    /// Where the dot starts on its drift circle, 0..1 of a turn.
    pub phase: f64,
}

/// A session's glyph.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "camelCase")]
pub struct Glyph {
    /// 0..1, the meaning `Frame.size.w` has for a wallpaper.
    pub seed: f64,
    /// The particles variant's name.
    pub variant: String,
    /// The variant's accent, `#RRGGBB`.
    pub accent: String,
    /// The variant's `speed`: how far the running line's dots drift.
    pub drift: f64,
    /// 5 to 9 dots, none overlapping.
    pub dots: Vec<Dot>,
}

/// What a glyph takes from one variant.
#[derive(Clone, Debug, PartialEq)]
struct Look {
    name: String,
    accent: String,
    size: f32,
    speed: f32,
}

/// Makes glyphs from one manifest's variants. Build it once and reuse it:
/// [`Signer::glyph`] reads no manifest.
#[derive(Clone, Debug, PartialEq)]
pub struct Signer {
    looks: Vec<Look>,
}

impl Signer {
    /// The first-party `particles` wallpaper's signer.
    pub fn particles() -> Self {
        first_party_by_id(PARTICLES_ID)
            .and_then(|w| Manifest::parse(w.manifest_json.as_bytes()).ok())
            .map(|m| Self::from_manifest(&m))
            .unwrap_or_else(Self::fallback)
    }

    /// A signer for `manifest`'s variants. A param a variant does not set
    /// takes the manifest's default; one the manifest lacks is 1.
    pub fn from_manifest(manifest: &Manifest) -> Self {
        let default =
            |name: &str| manifest.params.iter().find(|p| p.name == name).map_or(1.0, |p| p.default);
        let looks: Vec<Look> = manifest
            .variants
            .iter()
            .map(|v| Look {
                name: v.name.clone(),
                accent: v.accent.clone().unwrap_or_else(|| FALLBACK_ACCENT.to_owned()),
                size: v.params.get("size").copied().unwrap_or_else(|| default("size")),
                speed: v.params.get("speed").copied().unwrap_or_else(|| default("speed")),
            })
            .collect();
        if looks.is_empty() { Self::fallback() } else { Self { looks } }
    }

    /// Used only when the manifest cannot be read, which its tests rule out.
    fn fallback() -> Self {
        Self {
            looks: vec![Look {
                name: "Dust".to_owned(),
                accent: FALLBACK_ACCENT.to_owned(),
                size: 1.0,
                speed: 1.0,
            }],
        }
    }

    /// The glyph of `session_id`. Any string works, the empty one too.
    pub fn glyph(&self, session_id: &str) -> Glyph {
        let seed64 = fnv1a64(session_id.as_bytes());
        let len = self.looks.len().max(1) as u64;
        let fallback =
            Look { name: String::new(), accent: FALLBACK_ACCENT.to_owned(), size: 1.0, speed: 1.0 };
        let look = self.looks.get((seed64 % len) as usize).unwrap_or(&fallback);
        let mut rng = Rng(seed64);
        Glyph {
            seed: (seed64 >> 40) as f64 / f64::from(1u32 << 24),
            variant: look.name.clone(),
            accent: look.accent.clone(),
            drift: round4(look.speed),
            dots: dots(&mut rng, look.size),
        }
    }
}

/// The glyph of `session_id` from the first-party `particles` wallpaper.
/// It parses the manifest each call: for many ids, keep a [`Signer`].
pub fn glyph(session_id: &str) -> Glyph {
    Signer::particles().glyph(session_id)
}

/// FNV-1a, 64 bits.
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// SplitMix64.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// 0..1, 24 bits.
    fn unit(&mut self) -> f32 {
        (self.next() >> 40) as f32 / (1u32 << 24) as f32
    }

    /// A point in the disk of radius `reach` around the origin.
    fn in_disk(&mut self, reach: f32) -> (f32, f32) {
        let mut last = (0.0, 0.0);
        for _ in 0..4 {
            let p = ((self.unit() * 2.0 - 1.0) * reach, (self.unit() * 2.0 - 1.0) * reach);
            if p.0 * p.0 + p.1 * p.1 <= reach * reach {
                return p;
            }
            last = p;
        }
        // Four misses (1 in 400): pull the last one inside.
        let len = (last.0 * last.0 + last.1 * last.1).sqrt();
        if len > 0.0 { (last.0 * reach / len * 0.99, last.1 * reach / len * 0.99) } else { last }
    }
}

/// The dots: radii from `size`, then each placed by best candidate, the
/// largest first.
fn dots(rng: &mut Rng, size: f32) -> Vec<Dot> {
    let count = MIN_DOTS + (rng.next() % (MAX_DOTS - MIN_DOTS + 1) as u64) as usize;
    let mut radii: Vec<f32> = (0..count)
        .map(|_| ((MIN_RADIUS + 0.05 * rng.unit()) * size).clamp(MIN_RADIUS, MAX_RADIUS))
        .collect();
    let area: f32 = radii.iter().map(|r| r * r).sum();
    let cap = AREA_SHARE * DISK_RADIUS * DISK_RADIUS;
    if area > cap {
        let k = (cap / area).sqrt();
        for r in &mut radii {
            *r = (*r * k).max(MIN_RADIUS);
        }
    }
    radii.sort_by(|a, b| b.total_cmp(a));
    let mut placed: Vec<Placed> = Vec::with_capacity(count);
    for r0 in radii {
        let phase = rng.unit();
        let mut r = r0;
        for _ in 0..SHRINKS {
            if let Some((x, y)) = best_candidate(rng, &placed, r) {
                placed.push(Placed { x, y, r, phase });
                break;
            }
            r = (r * 0.85).max(MIN_RADIUS);
        }
    }
    placed
        .into_iter()
        .map(|d| Dot {
            x: round4(0.5 + d.x),
            y: round4(0.5 + d.y),
            r: round4_down(d.r),
            phase: round4(d.phase),
        })
        .collect()
}

/// The candidate farthest from every placed dot, centered on the origin,
/// or none when even it is nearer than [`MIN_GAP`].
fn best_candidate(rng: &mut Rng, placed: &[Placed], r: f32) -> Option<(f32, f32)> {
    let reach = DISK_RADIUS - r;
    let mut best: Option<((f32, f32), f32)> = None;
    for _ in 0..CANDIDATES {
        let c = rng.in_disk(reach);
        let gap = placed
            .iter()
            .map(|d| {
                let (dx, dy) = (c.0 - d.x, c.1 - d.y);
                (dx * dx + dy * dy).sqrt() - r - d.r
            })
            .fold(f32::INFINITY, f32::min);
        if best.is_none_or(|(_, g)| gap > g) {
            best = Some((c, gap));
        }
    }
    best.filter(|(_, gap)| *gap >= MIN_GAP).map(|(c, _)| c)
}

fn round4(v: f32) -> f64 {
    (f64::from(v) * 10_000.0).round() / 10_000.0
}

/// Rounded down, so a rounded radius never grows into a neighbor (by more
/// than the 1e-7 that keeps an f32 0.06, 0.0599999986, at 0.06).
fn round4_down(v: f32) -> f64 {
    (f64::from(v) * 10_000.0 + 1e-3).floor() / 10_000.0
}

#[cfg(test)]
#[path = "signature_tests.rs"]
mod tests;
