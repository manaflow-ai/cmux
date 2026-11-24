//! The glass: orbs and bubbles that refract what is behind them, with a glossy top, a fresnel
//! rim and light focused at the bottom; soft bokeh discs; star sparkles; and a bloom pass.

use crate::canvas::{Canvas, Rgb, smoothstep};
use crate::noise::Rng;

/// A glass sphere or soap bubble, in units of the short side.
#[derive(Clone, Copy, Debug)]
pub struct Orb {
    pub x: f32,
    pub y: f32,
    pub r: f32,
    pub tint: Rgb,
    /// 0 a thin soap bubble (clear, iridescent rim), 1 a tinted glass marble.
    pub body: f32,
    /// How far out of focus, 0 sharp.
    pub blur: f32,
}

/// Where the orbs go: one hero sphere near (`hero_x`, `hero_y`), a few companions around it and a
/// drift of small bubbles, most of them on the hero's side so the other side stays quiet.
pub struct OrbPlan {
    pub hero_x: f32,
    pub hero_y: f32,
    pub hero_r: f32,
    pub companions: usize,
    pub bubbles: usize,
    pub tints: Vec<Rgb>,
    /// The picture's width in units, so bubbles stay on canvas.
    pub aspect: f32,
    /// The lowest a bubble may sit, in units (above a horizon or the grass).
    pub floor: f32,
}

pub fn plan_orbs(rng: &mut Rng, plan: &OrbPlan) -> Vec<Orb> {
    let tint = |rng: &mut Rng| rng.pick(&plan.tints).copied().unwrap_or(Rgb::WHITE);
    let mut orbs = vec![Orb {
        x: plan.hero_x,
        y: plan.hero_y,
        r: plan.hero_r,
        tint: tint(rng),
        body: 1.0,
        blur: 0.0,
    }];
    let fits = |orbs: &[Orb], x: f32, y: f32, r: f32| {
        orbs.iter().all(|o| ((o.x - x).powi(2) + (o.y - y).powi(2)).sqrt() > o.r + r + 0.015)
    };
    let mut tries = 0;
    while orbs.len() < 1 + plan.companions && tries < 400 {
        tries += 1;
        let r = plan.hero_r * rng.range(0.22, 0.5);
        let angle = rng.angle();
        let reach = plan.hero_r + r + rng.range(0.03, 0.22);
        let (x, y) = (plan.hero_x + angle.cos() * reach * 1.3, plan.hero_y + angle.sin() * reach);
        if x - r > 0.2
            && x + r < plan.aspect - 0.02
            && y - r > 0.03
            && y + r < plan.floor
            && fits(&orbs, x, y, r)
        {
            orbs.push(Orb { x, y, r, tint: tint(rng), body: rng.range(0.45, 0.85), blur: 0.0 });
        }
    }
    tries = 0;
    let wanted = orbs.len() + plan.bubbles;
    while orbs.len() < wanted && tries < 3000 {
        tries += 1;
        let r = 0.006 + 0.03 * rng.unit().powf(2.2);
        // Most bubbles drift on the hero's side.
        let x = plan.aspect * (1.0 - rng.unit().powf(1.6) * 0.85);
        let y = rng.range(0.04, plan.floor - r);
        if fits(&orbs, x, y, r) {
            let blur = if rng.unit() < 0.3 { rng.range(0.15, 0.5) } else { 0.0 };
            orbs.push(Orb { x, y, r, tint: tint(rng), body: rng.range(0.0, 0.35), blur });
        }
    }
    // Small and far first, so the big ones lie on top.
    orbs.sort_by(|a, b| a.r.total_cmp(&b.r));
    orbs
}

/// Draws `orb` over `canvas`, refracting `behind` (the picture before any glass was drawn).
pub fn orb(canvas: &mut Canvas, behind: &Canvas, orb: Orb) {
    let u = canvas.unit();
    let (cx, cy, r) = (orb.x * u, orb.y * u, (orb.r * u).max(1.0));
    let soft = 0.75 + orb.blur * r * 0.35;
    let reach = r * 1.25 + soft + 2.0;
    let (x0, y0) = ((cx - reach).max(0.0) as usize, (cy - reach).max(0.0) as usize);
    let (x1, y1) = ((cx + reach).max(0.0) as usize + 1, (cy + reach).max(0.0) as usize + 1);
    let rim_tint = orb.tint.mix(Rgb::WHITE, 0.3);
    canvas.shade_rect(x0, y0, x1, y1, |x, y, c| {
        let (qx, qy) = ((x - cx) / r, (y - cy) / r);
        let d = (qx * qx + qy * qy).sqrt();
        let inside_px = (1.0 - d) * r;
        // A faint halo of tinted light around the glass.
        let halo = (-(d - 1.0).max(0.0) * 14.0).exp()
            * 0.10
            * (1.0 - orb.blur)
            * smoothstep(1.24, 1.05, d);
        let cover = smoothstep(-soft, soft, inside_px);
        if cover <= 0.0 {
            return c.screen(rim_tint, halo);
        }
        let z = (1.0 - (d * d).min(1.0)).sqrt();
        let edge = 1.0 - z;
        // A lens: toward the rim it shows what is nearer the centre, magnified, colours parting.
        let lens = |k: f32| behind.sample(cx + qx * r * k, cy + qy * r * k);
        let bend = 0.55 * edge.powf(1.4);
        let refracted =
            Rgb::new(lens(1.0 - bend).r, lens(1.0 - bend * 1.08).g, lens(1.0 - bend * 1.16).b);
        let mut col = refracted
            .times(Rgb::WHITE.mix(orb.tint, 0.35 + 0.5 * orb.body))
            .scale(1.0 + 0.15 * orb.body);
        // Light gathers in the lower half, as in a marble held up to the sky.
        let gather = smoothstep(-0.1, 0.9, qy) * (1.0 - edge) * 0.35 * orb.body;
        col = col.screen(orb.tint.mix(Rgb::WHITE, 0.4), gather);
        // The fresnel rim: the glass turns to reflected light at grazing angles.
        let film = if orb.body < 0.4 {
            let a = qy.atan2(qx) * 2.0 + qy * 3.0;
            Rgb::new(
                0.6 + 0.4 * a.sin(),
                0.75 + 0.25 * (a + 2.1).sin(),
                0.8 + 0.2 * (a + 4.2).sin(),
            )
            .mix(rim_tint, 0.4)
        } else {
            rim_tint
        };
        col = col.mix(film, edge.powf(3.0) * 0.8);
        // A crisp, slightly darker line at the very edge gives the glass its outline.
        let outline = (-((inside_px - 0.9) / (0.9 + r * 0.012)).powi(2)).exp();
        col = col.mix(orb.tint.scale(0.45), outline * (0.25 + 0.2 * orb.body));
        // The gloss: a broad white sheen over the top, fading downward (the Aero highlight).
        let (ex, ey) = ((qx + 0.02) / 0.74, (qy + 0.43) / 0.47);
        let e = ex * ex + ey * ey;
        let sheen = smoothstep(1.0, 0.72, e) * 0.92 * smoothstep(0.75, -0.95, ey).powf(1.6);
        col = col.screen(Rgb::WHITE, sheen * (0.5 + 0.3 * orb.body));
        // A hot spot and the light focused in a crescent opposite it.
        let hot = (-((qx + 0.3).powi(2) + (qy + 0.55).powi(2)) / 0.004).exp();
        let crescent = (-((d - 0.91) / 0.055).powi(2)).exp() * smoothstep(0.35, 0.95, qy) * 0.55;
        col = col.screen(Rgb::WHITE, hot).screen(orb.tint.mix(Rgb::WHITE, 0.55), crescent);
        c.mix(col, cover * (1.0 - orb.blur * 0.45)).screen(rim_tint, halo)
    });
}

/// A soft disc of out-of-focus light.
pub fn bokeh(canvas: &mut Canvas, x: f32, y: f32, r: f32, color: Rgb, alpha: f32) {
    let u = canvas.unit();
    let (cx, cy, pr) = (x * u, y * u, (r * u).max(1.0));
    let soft = pr * 0.18 + 1.0;
    let reach = pr + soft * 2.0;
    let (x0, y0) = ((cx - reach).max(0.0) as usize, (cy - reach).max(0.0) as usize);
    let (x1, y1) = ((cx + reach).max(0.0) as usize + 1, (cy + reach).max(0.0) as usize + 1);
    canvas.shade_rect(x0, y0, x1, y1, |px, py, c| {
        let d = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt();
        let disc = smoothstep(pr + soft, pr - soft, d);
        let ring = (-((d - pr * 0.9) / (pr * 0.1 + 0.5)).powi(2)).exp() * 0.35;
        c.screen(color, (disc * 0.8 + ring) * alpha)
    });
}

/// A scatter of bokeh discs in `colors`, sizes `r_range` units, kept to x from `x_from` (units).
pub fn bokeh_field(
    canvas: &mut Canvas,
    rng: &mut Rng,
    count: usize,
    colors: &[Rgb],
    r_range: (f32, f32),
    alpha: (f32, f32),
    x_from: f32,
) {
    let aspect = canvas.width as f32 / canvas.unit();
    let height = canvas.height as f32 / canvas.unit();
    for _ in 0..count {
        let x = rng.range(x_from, aspect);
        let y = rng.range(0.0, height);
        let r = rng.range(r_range.0, r_range.1);
        let color = rng.pick(colors).copied().unwrap_or(Rgb::WHITE);
        let a = rng.range(alpha.0, alpha.1);
        bokeh(canvas, x, y, r, color, a);
    }
}

/// A four-pointed star glint of `size` units.
pub fn sparkle(canvas: &mut Canvas, x: f32, y: f32, size: f32, strength: f32) {
    let u = canvas.unit();
    let (cx, cy, s) = (x * u, y * u, (size * u).max(2.0));
    let (x0, y0) = ((cx - s).max(0.0) as usize, (cy - s).max(0.0) as usize);
    let (x1, y1) = ((cx + s).max(0.0) as usize + 1, (cy + s).max(0.0) as usize + 1);
    canvas.shade_rect(x0, y0, x1, y1, |px, py, c| {
        let (dx, dy) = ((px - cx).abs(), (py - cy).abs());
        let thin = s * 0.018 + 0.6;
        let arm = |along: f32, across: f32| {
            (-along / (s * 0.16)).exp() * (-(across / thin).powi(2)).exp()
        };
        let diag = |along: f32, across: f32| {
            (-along / (s * 0.07)).exp() * (-(across / thin).powi(2)).exp() * 0.4
        };
        let (p, q) = (
            (dx + dy) * std::f32::consts::FRAC_1_SQRT_2,
            (dx - dy).abs() * std::f32::consts::FRAC_1_SQRT_2,
        );
        let core = (-(dx * dx + dy * dy) / (s * s * 0.004)).exp();
        let light = arm(dx, dy) + arm(dy, dx) + diag(p, q) + core;
        c.screen(Rgb::WHITE, light * strength)
    });
}

/// Bloom: the brightest light spills softly into its surroundings.
pub fn bloom(canvas: &mut Canvas, threshold: f32, strength: f32) {
    let scale = 8;
    let (w, h) = ((canvas.width / scale).max(1), (canvas.height / scale).max(1));
    let mut small = Canvas::new(w, h);
    let source = canvas.clone();
    let sx = canvas.width as f32 / w as f32;
    let sy = canvas.height as f32 / h as f32;
    small.shade(|x, y, _| {
        let c = source.sample(x * sx, y * sy);
        let over = (c.luminance() - threshold).max(0.0) / (1.0 - threshold).max(1e-3);
        c.scale(over.min(1.5))
    });
    for _ in 0..3 {
        let copy = small.clone();
        small.shade(|x, y, _| {
            let mut sum = Rgb::default();
            for k in -3..=3 {
                sum = sum.plus(copy.sample(x + k as f32 * 1.5, y));
            }
            sum.scale(1.0 / 7.0)
        });
        let copy = small.clone();
        small.shade(|x, y, _| {
            let mut sum = Rgb::default();
            for k in -3..=3 {
                sum = sum.plus(copy.sample(x, y + k as f32 * 1.5));
            }
            sum.scale(1.0 / 7.0)
        });
    }
    canvas.shade(|x, y, c| c.screen(small.sample(x / sx, y / sy), strength));
}

/// Darkens the corners a touch so the eye stays in the picture.
pub fn vignette(canvas: &mut Canvas, amount: f32) {
    let (w, h) = (canvas.width as f32, canvas.height as f32);
    canvas.shade(|x, y, c| {
        let (dx, dy) = (x / w - 0.5, y / h - 0.5);
        c.scale(1.0 - amount * (dx * dx + dy * dy) * 2.0)
    });
}
