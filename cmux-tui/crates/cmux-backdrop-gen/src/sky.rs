//! The air: the sky gradient and sun, soft clouds, rays and light streaks, glossy ribbons,
//! stars and aurora curtains. Positions are in units of the canvas's short side.

use crate::canvas::{Canvas, Rgb, gradient, smoothstep};
use crate::noise::{Rng, fbm, hash2, value};

/// Where the light comes from and how it glows.
#[derive(Clone, Copy, Debug)]
pub struct Sun {
    pub x: f32,
    pub y: f32,
    pub color: Rgb,
    /// The tight core's strength.
    pub core: f32,
    /// The wide halo's strength.
    pub halo: f32,
}

/// The vertical sky gradient (`stops` by height, 0 top) with the sun's glow over it.
pub fn sky(canvas: &mut Canvas, stops: &[(f32, Rgb)], sun: Sun) {
    let (u, h) = (canvas.unit(), canvas.height as f32);
    canvas.shade(|x, y, _| {
        let (dx, dy) = (x / u - sun.x, y / u - sun.y);
        let d2 = dx * dx + dy * dy;
        let glow = sun.core * (-d2 * 22.0).exp() + sun.halo * (-d2.sqrt() * 2.2).exp();
        gradient(stops, y / h).plus(sun.color.scale(glow))
    });
}

/// Soft white cloud wisps, stretched sideways, thinning toward `floor` (a height fraction).
pub fn clouds(canvas: &mut Canvas, seed: u64, amount: f32, floor: f32, puffiness: f32) {
    let (u, h) = (canvas.unit(), canvas.height as f32);
    let seed = seed ^ 0xC10D;
    canvas.shade(|x, y, c| {
        let (px, py) = (x / u, y / u);
        let warp = fbm(px * 0.8, py * 0.8, seed ^ 7, 3);
        let n = fbm(px * 0.9 * puffiness + warp * 1.4, py * 2.4 * puffiness + warp, seed, 6);
        let shape = smoothstep(0.50, 0.78, n);
        // Lit tops, slightly shaded undersides.
        let lit = smoothstep(
            0.45,
            0.85,
            fbm(px * 0.9 * puffiness + warp * 1.4, (py - 0.02) * 2.4 * puffiness + warp, seed, 6),
        );
        let fade = 1.0 - smoothstep(floor * 0.6, floor, y / h);
        let white = Rgb::WHITE.mix(Rgb::new(0.72, 0.82, 0.95), (1.0 - lit) * 0.5);
        c.mix(white, shape * amount * fade)
    });
}

/// Rays fanning out of the sun, each a soft wedge of light.
pub fn rays(canvas: &mut Canvas, sun: Sun, seed: u64, amount: f32) {
    let u = canvas.unit();
    canvas.shade(|x, y, c| {
        let (dx, dy) = (x / u - sun.x, y / u - sun.y);
        let d = (dx * dx + dy * dy).sqrt().max(1e-4);
        let (ax, ay) = (dx / d, dy / d);
        let n = value(ax * 6.0 + 50.0, ay * 6.0 + 50.0, seed ^ 0x4A75);
        let fine = value(ax * 19.0 + 9.0, ay * 19.0 + 9.0, seed ^ 0x77);
        let ray = (n * 0.75 + fine * 0.25).powf(4.0) * 3.0;
        c.screen(sun.color, ray * amount * (-d * 1.1).exp() * smoothstep(0.0, 0.12, d))
    });
}

/// Long, thin streaks of light crossing the frame from the sun, like a lens catching it.
pub fn streaks(canvas: &mut Canvas, sun: Sun, rng: &mut Rng, count: usize, amount: f32) {
    let u = canvas.unit();
    let lines: Vec<(f32, f32, f32, f32)> = (0..count)
        .map(|_| {
            let angle = rng.range(0.15, 1.2);
            (angle.cos(), angle.sin(), rng.range(0.0015, 0.006), rng.range(0.3, 1.0))
        })
        .collect();
    canvas.shade(|x, y, c| {
        let (px, py) = (x / u - sun.x, y / u - sun.y);
        let mut light = 0.0;
        for &(cx, cy, width, strength) in &lines {
            let along = px * cx + py * cy;
            let across = px * cy - py * cx;
            if along > 0.0 {
                let w = width * (1.0 + along * 1.5);
                light += strength
                    * (-(across / w).powi(2)).exp()
                    * (-along * 0.9).exp()
                    * smoothstep(0.0, 0.2, along);
            }
        }
        c.screen(sun.color, light * amount)
    });
}

/// A glossy ribbon swept across the picture: a translucent band with bright edges, thick in
/// places and pinched to a hairline in others (the "swoosh").
#[derive(Clone, Copy, Debug)]
pub struct Ribbon {
    pub base: f32,
    pub tilt: f32,
    pub waves: [(f32, f32, f32); 2],
    pub thickness: f32,
    pub pinch: (f32, f32),
    pub color: Rgb,
    pub alpha: f32,
    pub span: (f32, f32),
}

impl Ribbon {
    /// A ribbon around height `base`, its shape from `rng`.
    pub fn random(
        rng: &mut Rng,
        base: f32,
        thickness: f32,
        color: Rgb,
        alpha: f32,
        aspect: f32,
    ) -> Self {
        Ribbon {
            base,
            tilt: rng.range(-0.22, 0.05),
            waves: [
                (rng.range(0.04, 0.10), rng.range(1.2, 2.4), rng.angle()),
                (rng.range(0.01, 0.03), rng.range(3.0, 5.5), rng.angle()),
            ],
            thickness,
            pinch: (rng.range(1.6, 3.2), rng.angle()),
            color,
            alpha,
            span: (rng.range(-0.3, 0.2), aspect + rng.range(-0.2, 0.3)),
        }
    }

    fn center(&self, px: f32) -> f32 {
        let [(a1, f1, p1), (a2, f2, p2)] = self.waves;
        self.base + self.tilt * px + a1 * (f1 * px + p1).sin() + a2 * (f2 * px + p2).sin()
    }
}

pub fn ribbon(canvas: &mut Canvas, r: Ribbon) {
    let u = canvas.unit();
    let hair = 1.0 / u;
    canvas.shade(|x, y, c| {
        let (px, py) = (x / u, y / u);
        let fade = smoothstep(r.span.0, r.span.0 + 0.35, px)
            * (1.0 - smoothstep(r.span.1 - 0.35, r.span.1, px));
        if fade <= 0.0 {
            return c;
        }
        let pinch = 0.5 + 0.5 * (r.pinch.0 * px + r.pinch.1).sin();
        let th = r.thickness * (0.08 + 0.92 * pinch * pinch) + hair;
        let d = (py - r.center(px)) / th;
        let ad = d.abs();
        if ad > 2.5 {
            return c;
        }
        // The band: brighter toward its upper edge, like light catching a curved sheet.
        let body = smoothstep(1.0 + hair / th, 1.0 - hair / th, ad)
            * (0.18 + 0.32 * smoothstep(1.0, -1.0, d));
        // Bright hairlines along both edges, the top one stronger.
        let edge_w = (1.4 * hair) / th;
        let top = (-((d + 1.0) / edge_w).powi(2)).exp() * 0.9;
        let bottom = (-((d - 1.0) / edge_w).powi(2)).exp() * 0.45;
        let glow = (-(ad - 1.0).max(0.0) * 5.0).exp() * 0.06;
        c.screen(r.color, (body + top + bottom + glow) * r.alpha * fade)
    });
}

/// Faint stars, denser and brighter toward the top.
pub fn stars(canvas: &mut Canvas, seed: u64, floor: f32) {
    let h = canvas.height as f32;
    let cell = (canvas.unit() / 140.0).max(3.0);
    canvas.shade(|x, y, c| {
        let (cx, cy) = ((x / cell).floor(), (y / cell).floor());
        let n = hash2(cx as i32, cy as i32, seed ^ 0x57A8);
        if n < 0.965 {
            return c;
        }
        let ox = hash2(cx as i32, cy as i32, seed ^ 0x51) * cell;
        let oy = hash2(cx as i32, cy as i32, seed ^ 0x52) * cell;
        let (dx, dy) = (x - (cx * cell + ox), y - (cy * cell + oy));
        let size = 0.5 + (n - 0.965) * 30.0;
        let star =
            (-(dx * dx + dy * dy) / (size * size)).exp() * (1.0 - smoothstep(0.0, floor, y / h));
        c.screen(Rgb::new(0.85, 0.92, 1.0), star * (0.4 + (n - 0.965) * 18.0))
    });
}

/// Aurora curtains: folds of light hanging from a wavering line, rays rising from it.
pub fn aurora(canvas: &mut Canvas, rng: &mut Rng, curtains: usize, colors: [Rgb; 3], amount: f32) {
    let u = canvas.unit();
    let [low, mid, high] = colors;
    let seed = rng.next_u64();
    let folds: Vec<(f32, f32, f32, f32, f32)> = (0..curtains)
        .map(|i| {
            let i = i as f32;
            (
                rng.range(0.32, 0.42) + i * 0.08,
                rng.range(0.05, 0.12),
                rng.range(1.0, 2.2),
                rng.angle(),
                rng.range(0.6, 1.0),
            )
        })
        .collect();
    canvas.shade(|x, y, c| {
        let (px, py) = (x / u, y / u);
        let mut out = c;
        for (k, &(base, amp, freq, phase, strength)) in folds.iter().enumerate() {
            let k = k as u64;
            let wander = fbm(px * 0.9, k as f32 * 3.0, seed ^ k, 4) - 0.5;
            let line = base + amp * (freq * px + phase).sin() + 0.12 * wander;
            let dy = py - line;
            let fall =
                if dy > 0.0 { (-dy / 0.018).exp() } else { (dy / (0.15 + 0.08 * wander)).exp() };
            // Curtains come and go along the sky rather than spanning it.
            let presence = smoothstep(
                0.3,
                0.56,
                fbm(px * 0.7 + 11.0, k as f32 * 7.0 + 1.0, seed ^ 0xB0 ^ k, 3),
            );
            let warp = fbm(px * 2.0, 0.5 + k as f32, seed ^ 0xF0 ^ k, 3) * 3.0;
            let striae = value(px * 34.0 + warp * 6.0, k as f32 * 5.0, seed ^ 0xA1 ^ k);
            let rays = 0.2 + 0.8 * striae * striae;
            let height = (-dy).max(0.0);
            let color = low
                .mix(mid, smoothstep(0.02, 0.14, height))
                .mix(high, smoothstep(0.12, 0.34, height));
            let core = (-(dy / 0.008).powi(2)).exp() * 0.3;
            out = out.plus(color.scale((fall * rays + core) * presence * strength * amount));
        }
        out
    });
}
