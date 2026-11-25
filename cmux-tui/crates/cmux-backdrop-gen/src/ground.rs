//! What the sky meets: lagoon water with caustics and glitter, a still mirror of the sky,
//! glossy rolling hills and a fringe of grass.

use crate::canvas::{Canvas, Rgb, gradient, smoothstep};
use crate::noise::{Rng, fbm, hash2, value};

/// Bright, web-like caustic lines (ridges of warped noise) in 0..1.
fn caustic(x: f32, y: f32, seed: u64) -> f32 {
    let warp_x = fbm(x * 0.6, y * 0.6, seed ^ 0x11, 3);
    let warp_y = fbm(x * 0.6 + 5.2, y * 0.6 + 1.3, seed ^ 0x12, 3);
    let ridge = |scale: f32, salt: u64| {
        let n = value(x * scale + warp_x * 2.5, y * scale + warp_y * 2.5, seed ^ salt);
        (1.0 - (2.0 * n - 1.0).abs()).powf(6.0)
    };
    ridge(1.0, 0x21) * 0.8 + ridge(1.9, 0x22) * 0.45
}

/// Points of sunlight on water: one in a few cells of `cell` pixels lights a tiny, wide spark.
fn glitter(x: f32, y: f32, cell: f32, seed: u64) -> f32 {
    let (cx, cy) = ((x / (cell * 2.0)).floor(), (y / cell).floor());
    let (ix, iy) = (cx as i32, cy as i32);
    let n = hash2(ix, iy, seed ^ 0x41);
    if n < 0.9 {
        return 0.0;
    }
    let sx = (cx + 0.2 + 0.6 * hash2(ix, iy, seed ^ 0x42)) * cell * 2.0;
    let sy = (cy + 0.5) * cell;
    let (dx, dy) = ((x - sx) / (cell * 0.5), (y - sy) / (cell * 0.18));
    (-(dx * dx + dy * dy)).exp() * (n - 0.9) * 14.0
}

/// Lagoon water below `horizon` (a height fraction): deep turquoise turning to clear aqua at
/// the front, the sky mirrored near the horizon, caustics on the shallows, the sun's glitter.
pub fn lagoon(canvas: &mut Canvas, horizon: f32, stops: &[(f32, Rgb)], sun_x: f32, seed: u64) {
    let sky = canvas.clone();
    let (u, w, h) = (canvas.unit(), canvas.width as f32, canvas.height as f32);
    let hy = horizon * h;
    canvas.shade(|x, y, c| {
        if y < hy - 1.5 {
            return c;
        }
        let t = ((y - hy) / (h - hy)).clamp(0.0, 1.0);
        let depth = t + 0.06;
        let (wx, wz) = ((x - w * 0.5) / u / depth, 1.0 / depth);
        let ripple = (fbm(wx * 1.2, wz * 3.0, seed ^ 0x31, 4) - 0.5) * 6.0 * (1.0 - t);
        let mirrored = sky.sample(x + ripple, (2.0 * hy - y - ripple * 2.0).max(0.0));
        let base = gradient(stops, t);
        let fresnel = (1.0 - t).powf(5.0) * 0.85;
        let mut out = base.mix(mirrored, fresnel);
        // Caustics, stronger in the shallows at the front.
        let light = caustic(wx * 4.0, wz * 3.0, seed);
        out = out.screen(Rgb::new(0.85, 1.0, 0.98), light * smoothstep(0.12, 0.7, t) * 0.9);
        // The sun's glitter: a column of sparks under it.
        let column = (-((x / u - sun_x) / (0.04 + 0.3 * t)).powi(2)).exp();
        out = out.screen(Rgb::WHITE, column * glitter(x, y, 2.0 + 7.0 * t, seed) * (1.0 - t * 0.5));
        // A bright line where water meets sky.
        let line = (-((y - hy) / 2.5).powi(2)).exp() * 0.7;
        let blend = smoothstep(hy - 1.5, hy + 1.5, y);
        c.mix(out.screen(Rgb::WHITE, line), blend)
    });
}

/// A calm, dark mirror below `horizon`: the sky above reflected, dimmed and gently rippled.
pub fn mirror(canvas: &mut Canvas, horizon: f32, tint: Rgb, seed: u64) {
    let sky = canvas.clone();
    let (u, h) = (canvas.unit(), canvas.height as f32);
    let hy = horizon * h;
    canvas.shade(|x, y, c| {
        if y < hy {
            return c;
        }
        let t = ((y - hy) / (h - hy)).clamp(0.0, 1.0);
        let wobble = (value(x / u * 3.0, (y - hy) / u * 40.0 / (t + 0.1), seed ^ 0x61) - 0.5)
            * 10.0
            * (0.3 + t);
        let reflected = sky.sample(x + wobble, (2.0 * hy - y).max(0.0));
        let out = reflected.times(tint).scale(0.75 - 0.35 * t);
        let line = (-((y - hy) / 2.0).powi(2)).exp() * 0.5;
        c.mix(out.screen(Rgb::new(0.7, 0.95, 1.0), line), smoothstep(hy, hy + 1.5, y))
    });
}

/// One rolling hill line: its ridge height at x, colours and gloss.
#[derive(Clone, Copy, Debug)]
pub struct Hill {
    pub base: f32,
    pub waves: [(f32, f32, f32); 2],
    pub top: Rgb,
    pub bottom: Rgb,
    pub gloss: f32,
    pub seed: u64,
}

impl Hill {
    pub fn random(rng: &mut Rng, base: f32, top: Rgb, bottom: Rgb, gloss: f32) -> Self {
        Hill {
            base,
            waves: [
                (rng.range(0.05, 0.09), rng.range(1.1, 2.0), rng.angle()),
                (rng.range(0.015, 0.03), rng.range(2.5, 4.5), rng.angle()),
            ],
            top,
            bottom,
            gloss,
            seed: rng.next_u64(),
        }
    }

    fn ridge(&self, px: f32) -> f32 {
        let [(a1, f1, p1), (a2, f2, p2)] = self.waves;
        self.base - a1 * (f1 * px + p1).sin() - a2 * (f2 * px + p2).sin()
    }
}

pub fn hill(canvas: &mut Canvas, hill: Hill) {
    let u = canvas.unit();
    let px_unit = 1.0 / u;
    canvas.shade(|x, y, c| {
        let (px, py) = (x / u, y / u);
        let ridge = hill.ridge(px);
        let below = py - ridge;
        if below < -px_unit * 2.0 {
            return c;
        }
        let cover = smoothstep(-px_unit, px_unit, below);
        let shade = smoothstep(0.0, 0.28, below);
        // Soft lit and shaded patches, like light across turf.
        let patch = fbm(px * 2.2, py * 4.0, hill.seed, 4);
        let mut col = hill.top.mix(hill.bottom, shade).scale(0.86 + 0.28 * patch);
        // Gloss: a bright rim just under the ridge and a broad sheen below it.
        let rim = (-below / 0.008).exp() * 0.4;
        let sheen = (-((below - 0.05) / 0.04).powi(2)).exp() * 0.1;
        col = col.screen(Rgb::new(0.92, 1.0, 0.75), (rim + sheen) * hill.gloss);
        c.mix(col, cover)
    });
}

/// A fringe of grass blades along the bottom edge.
#[derive(Clone, Copy, Debug)]
pub struct Grass {
    /// Where the blades are rooted, in units from the top.
    pub ground: f32,
    /// The tallest blade, in units.
    pub height: f32,
    pub spacing: f32,
    /// Extra edge softness in pixels, like an out-of-focus foreground.
    pub blur: f32,
    pub base: Rgb,
    pub tip: Rgb,
    pub seed: u64,
}

pub fn grass(canvas: &mut Canvas, g: Grass) {
    let Grass { ground, height, spacing, blur, base, tip, seed } = g;
    let u = canvas.unit();
    let soft = (1.0 + blur) / u;
    canvas.shade(|x, y, c| {
        let (px, py) = (x / u, y / u);
        let root = ground + 0.01 * (px * 3.0).sin();
        let rise = root - py;
        if rise > height * 1.6 {
            return c;
        }
        if rise < 0.0 {
            return c.mix(base.scale(0.8), smoothstep(0.0, soft, -rise));
        }
        let mut cover: f32 = 0.0;
        let mut tipness: f32 = 0.0;
        let cell = (px / spacing).floor();
        for k in -2..=2 {
            let i = cell as i32 + k;
            let tall = height * (0.45 + 0.9 * hash2(i, 7, seed));
            if rise > tall {
                continue;
            }
            let lean = (hash2(i, 11, seed) - 0.5) * 2.2;
            let along = rise / tall;
            let centre = (i as f32 + 0.5 + (hash2(i, 13, seed) - 0.5) * 0.8) * spacing
                + lean * along * along * tall * 0.6;
            let half = spacing * 0.55 * (1.0 - along).powf(0.8);
            let inside = smoothstep(half + soft, half - soft, (px - centre).abs());
            if inside > cover {
                cover = inside;
                tipness = along;
            }
        }
        let shade = value(px * 30.0, py * 2.0, seed ^ 0x71);
        let col = base.mix(tip, smoothstep(0.0, 1.0, tipness) * (0.7 + 0.3 * shade));
        c.mix(col, cover)
    });
}
