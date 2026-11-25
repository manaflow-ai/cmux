//! The moods: which layers each draws, in what colours, and how a seed varies them.

use crate::canvas::{Canvas, Rgb};
use crate::glass::{OrbPlan, bloom, bokeh_field, orb, plan_orbs, sparkle, vignette};
use crate::ground::{Grass, Hill, grass, hill, lagoon, mirror};
use crate::noise::Rng;
use crate::sky::{Ribbon, Sun, aurora, clouds, rays, ribbon, sky, stars, streaks};

const SKY_DEEP: u32 = 0x007FC4;
const SKY_PALE: u32 = 0xAACBF0;

fn hex(rgb: u32) -> Rgb {
    Rgb::hex(rgb)
}

/// Draws the orbs `plan` places, each refracting the picture as it was before any glass, and a
/// glint on the larger ones.
fn glass(canvas: &mut Canvas, rng: &mut Rng, plan: &OrbPlan) {
    let orbs = plan_orbs(rng, plan);
    let behind = canvas.clone();
    for o in &orbs {
        orb(canvas, &behind, *o);
    }
    for o in orbs.iter().filter(|o| o.r > 0.045) {
        sparkle(canvas, o.x - o.r * 0.3, o.y - o.r * 0.55, o.r * 0.9, 0.55);
    }
}

fn finish(canvas: &mut Canvas, rng: &mut Rng, glints: usize, bloom_at: f32) {
    let aspect = canvas.width as f32 / canvas.unit();
    let height = canvas.height as f32 / canvas.unit();
    for _ in 0..glints {
        let (x, y) = (rng.range(aspect * 0.35, aspect * 0.98), rng.range(0.05, height * 0.9));
        sparkle(canvas, x, y, rng.range(0.015, 0.04), rng.range(0.25, 0.6));
    }
    bloom(canvas, bloom_at, 0.55);
    vignette(canvas, 0.10);
}

/// The colours of an open-sky scene: the sky by height, the sun, the swooshes, bokeh and glass.
struct SkyLook {
    stops: [(f32, Rgb); 4],
    sun: Rgb,
    clouds: f32,
    ribbon: Rgb,
    bokeh: [Rgb; 3],
    tints: Vec<Rgb>,
}

/// An open sky: gradient and sun, cloud wisps, rays and streaks, glossy swooshes and glass.
fn open_sky(canvas: &mut Canvas, rng: &mut Rng, look: &SkyLook) {
    let aspect = canvas.width as f32 / canvas.unit();
    let height = canvas.height as f32 / canvas.unit();
    let sun = Sun {
        x: rng.range(0.12, 0.4),
        y: rng.range(-0.08, 0.06),
        color: look.sun,
        core: 0.9,
        halo: 0.35,
    };
    sky(canvas, &look.stops, sun);
    clouds(canvas, rng.next_u64(), look.clouds, 0.95, 1.0);
    rays(canvas, sun, rng.next_u64(), 0.22);
    streaks(canvas, sun, rng, 4, 0.18);
    for (base, thick, alpha) in [(0.78, 0.09, 1.0), (0.87, 0.06, 0.85), (0.70, 0.035, 0.7)] {
        ribbon(canvas, Ribbon::random(rng, base * height, thick, look.ribbon, alpha, aspect));
    }
    bokeh_field(canvas, rng, 18, &look.bokeh, (0.01, 0.05), (0.05, 0.18), aspect * 0.3);
    let plan = OrbPlan {
        hero_x: aspect * rng.range(0.68, 0.78),
        hero_y: height * rng.range(0.4, 0.5),
        hero_r: rng.range(0.17, 0.21),
        companions: 4,
        bubbles: 34,
        tints: look.tints.clone(),
        aspect,
        floor: height * 0.97,
    };
    glass(canvas, rng, &plan);
    finish(canvas, rng, 5, 0.72);
}

/// A clear Aero sky: deep blue to pale, cloud wisps, rays, white swooshes and a drift of glass.
pub fn sky_mood(canvas: &mut Canvas, rng: &mut Rng) {
    let look = SkyLook {
        stops: [
            (0.0, hex(0x005A9E)),
            (0.4, hex(SKY_DEEP)),
            (0.82, hex(SKY_PALE)),
            (1.0, hex(0xD2E8FA)),
        ],
        sun: hex(0xFFF8E6),
        clouds: 0.8,
        ribbon: Rgb::WHITE,
        bokeh: [Rgb::WHITE, hex(0xBDF3FF), hex(0xD7FFF0)],
        tints: vec![hex(0x7FE3FF), hex(0xBFEFFF), hex(0x5BC8F5), hex(0xC9FF8A)],
    };
    open_sky(canvas, rng, &look);
}

/// The maximal Aero dusk: violet to magenta to blush pink, pink-white swooshes, lilac glass.
pub fn orchid_mood(canvas: &mut Canvas, rng: &mut Rng) {
    let look = SkyLook {
        stops: [
            (0.0, hex(0x2A1260)),
            (0.38, hex(0x7A2E9E)),
            (0.75, hex(0xD263B4)),
            (1.0, hex(0xFFC2DF)),
        ],
        sun: hex(0xFFE6F4),
        clouds: 0.3,
        ribbon: hex(0xFFE3F3),
        bokeh: [Rgb::WHITE, hex(0xFFB8E6), hex(0xC9B8FF)],
        tints: vec![hex(0xFF9BDC), hex(0xC7A6FF), hex(0x8FE6FF), hex(0xFFD1F0)],
    };
    open_sky(canvas, rng, &look);
}

/// A tropical lagoon: aqua sky over turquoise water, caustics in the shallows, the sun's glitter.
pub fn lagoon_mood(canvas: &mut Canvas, rng: &mut Rng) {
    let aspect = canvas.width as f32 / canvas.unit();
    let height = canvas.height as f32 / canvas.unit();
    let horizon = rng.range(0.5, 0.56);
    let sun = Sun {
        x: aspect * rng.range(0.55, 0.72),
        y: rng.range(0.08, 0.16),
        color: hex(0xFFFBEA),
        core: 0.55,
        halo: 0.22,
    };
    let stops = [
        (0.0, hex(0x0086CC)),
        (0.3, hex(0x22A9E2)),
        (horizon * 0.95, hex(0xC8F2FF)),
        (1.0, hex(0xFFFFFF)),
    ];
    sky(canvas, &stops, sun);
    clouds(canvas, rng.next_u64(), 0.45, horizon, 1.3);
    rays(canvas, sun, rng.next_u64(), 0.15);
    let water =
        [(0.0, hex(0x9FEAF2)), (0.12, hex(0x2CC4D6)), (0.45, hex(0x0098BD)), (1.0, hex(0x27D3CB))];
    lagoon(canvas, horizon, &water, sun.x, rng.next_u64());
    ribbon(canvas, Ribbon::random(rng, horizon * height - 0.04, 0.05, hex(0xE6FFFB), 0.8, aspect));
    ribbon(
        canvas,
        Ribbon::random(rng, horizon * height + 0.25, 0.035, hex(0xC9FFF4), 0.55, aspect),
    );
    bokeh_field(
        canvas,
        rng,
        14,
        &[Rgb::WHITE, hex(0xA8FFF0), hex(0xE2FF9E)],
        (0.01, 0.04),
        (0.06, 0.18),
        aspect * 0.3,
    );
    let plan = OrbPlan {
        hero_x: aspect * rng.range(0.7, 0.8),
        hero_y: height * rng.range(0.42, 0.52),
        hero_r: rng.range(0.16, 0.2),
        companions: 4,
        bubbles: 30,
        tints: vec![hex(0x4FF0E0), hex(0x8CF7FF), hex(0xB8FF6E), hex(0x3DD6F5)],
        aspect,
        floor: height * 0.98,
    };
    glass(canvas, rng, &plan);
    finish(canvas, rng, 6, 0.75);
}

/// A polar night in glass: navy to blue, aurora curtains in green and cyan, a still mirror below.
pub fn aurora_mood(canvas: &mut Canvas, rng: &mut Rng) {
    let aspect = canvas.width as f32 / canvas.unit();
    let height = canvas.height as f32 / canvas.unit();
    let horizon = rng.range(0.72, 0.78);
    let sun = Sun {
        x: aspect * rng.range(0.25, 0.5),
        y: horizon * height,
        color: hex(0x3FD8FF),
        core: 0.25,
        halo: 0.25,
    };
    let stops = [
        (0.0, hex(0x020B2A)),
        (0.35, hex(0x062C6E)),
        (0.62, hex(0x08498F)),
        (horizon, hex(0x3AB4E0)),
        (1.0, hex(0x0A3B7A)),
    ];
    sky(canvas, &stops, sun);
    stars(canvas, rng.next_u64(), horizon * 0.9);
    let colors = [hex(0x6BFFB8), hex(0x2EE6D6), hex(0x8A7CFF)];
    aurora(canvas, rng, 4, colors, 0.8);
    ribbon(
        canvas,
        Ribbon::random(rng, horizon * height - 0.05, 0.035, hex(0x9FF6FF), 0.55, aspect),
    );
    mirror(canvas, horizon, hex(0x9FD8FF), rng.next_u64());
    bokeh_field(
        canvas,
        rng,
        16,
        &[hex(0x7DFFD0), hex(0x7FD4FF), hex(0xB9A8FF)],
        (0.008, 0.035),
        (0.08, 0.22),
        aspect * 0.3,
    );
    let plan = OrbPlan {
        hero_x: aspect * rng.range(0.68, 0.78),
        hero_y: height * rng.range(0.42, 0.5),
        hero_r: rng.range(0.15, 0.19),
        companions: 3,
        bubbles: 26,
        tints: vec![hex(0x63FFD0), hex(0x6FD6FF), hex(0xA99BFF)],
        aspect,
        floor: horizon * height - 0.01,
    };
    glass(canvas, rng, &plan);
    finish(canvas, rng, 4, 0.6);
}

/// A spring meadow: blue sky over glossy lime hills, grass in the foreground, leaf-green bokeh.
pub fn meadow_mood(canvas: &mut Canvas, rng: &mut Rng) {
    let aspect = canvas.width as f32 / canvas.unit();
    let height = canvas.height as f32 / canvas.unit();
    let sun = Sun {
        x: rng.range(0.15, 0.45),
        y: rng.range(-0.05, 0.08),
        color: hex(0xFFF6D8),
        core: 1.0,
        halo: 0.4,
    };
    let stops =
        [(0.0, hex(0x006CB0)), (0.3, hex(SKY_DEEP)), (0.6, hex(SKY_PALE)), (1.0, hex(0xF0FAFF))];
    sky(canvas, &stops, sun);
    clouds(canvas, rng.next_u64(), 0.85, 0.7, 0.8);
    rays(canvas, sun, rng.next_u64(), 0.2);
    streaks(canvas, sun, rng, 3, 0.15);
    let hills = [
        (0.66, hex(0x9CE07A), hex(0x58B06A), 0.6),
        (0.76, hex(0x84D628), hex(0x3E9E22), 0.9),
        (0.88, hex(0x74CC1C), hex(0x2B8A1C), 1.0),
    ];
    for (base, top, bottom, gloss) in hills {
        hill(canvas, Hill::random(rng, base * height, top, bottom, gloss));
    }
    let seed = rng.next_u64();
    grass(
        canvas,
        Grass {
            ground: height * 1.02,
            height: 0.13,
            spacing: 0.009,
            blur: 0.5,
            base: hex(0x2E8F22),
            tip: hex(0xC6F25A),
            seed,
        },
    );
    let plan = OrbPlan {
        hero_x: aspect * rng.range(0.68, 0.78),
        hero_y: height * rng.range(0.36, 0.44),
        hero_r: rng.range(0.15, 0.19),
        companions: 4,
        bubbles: 28,
        tints: vec![hex(0xB6FF5C), hex(0x7FE3FF), hex(0xE8FF9A), hex(0x9CF0C8)],
        aspect,
        floor: height * 0.85,
    };
    glass(canvas, rng, &plan);
    let seed = rng.next_u64();
    grass(
        canvas,
        Grass {
            ground: height * 1.04,
            height: 0.2,
            spacing: 0.02,
            blur: 4.0,
            base: hex(0x1F6E18),
            tip: hex(0x9EE03A),
            seed,
        },
    );
    bokeh_field(
        canvas,
        rng,
        24,
        &[hex(0xC8FF6A), hex(0xF4FF9C), Rgb::WHITE, hex(0x8FF0C0)],
        (0.012, 0.06),
        (0.08, 0.26),
        0.0,
    );
    finish(canvas, rng, 4, 0.75);
}
