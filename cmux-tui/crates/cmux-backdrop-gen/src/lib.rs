//! Frutiger Aero 2027: seeded, procedural window backdrops in the spirit of the glossy
//! mid-2000s desktop, made modern with liquid glass (Leo, 2026-11-19: "make our own generatable
//! Frutiger Aero type stuff ... but 2027").
//!
//! Everything is drawn on the CPU from a seed: sky gradients, clouds, rays and light streaks,
//! glossy ribbons, lagoon water with caustics, aurora curtains, rolling hills and grass, bokeh,
//! and glass orbs that refract what is behind them. No stock image is used. A mood and a seed
//! always give the same picture at a given size.
//!
//! The shipped backdrops (`art/manifest.json`, ids in `SHIPPED`) are rendered with
//! `cargo run -p cmux-backdrop-gen --release -- --shipped OUT_DIR`; any other seed with
//! `cargo run -p cmux-backdrop-gen --release -- --mood aero-lagoon --seed 7 --out lagoon.png`.

mod canvas;
mod glass;
mod ground;
mod moods;
mod noise;
mod sky;

pub use canvas::{Canvas, Rgb};

/// A look: which scene is drawn and in which colours.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mood {
    /// Deep #007FC4 to pale #AACBF0 sky, white swooshes, a drift of glass orbs.
    Sky,
    /// Aqua sky over a turquoise lagoon with caustics and the sun's glitter.
    Lagoon,
    /// Navy night with aurora curtains over a still mirror, glowing glass.
    Aurora,
    /// Blue sky over glossy lime-green hills, grass and leaf bokeh.
    Meadow,
    /// The maximal Aero dusk: violet to magenta to blush pink, pink swooshes and lilac glass.
    Orchid,
}

impl Mood {
    pub const ALL: [Mood; 5] = [Mood::Sky, Mood::Lagoon, Mood::Aurora, Mood::Meadow, Mood::Orchid];

    /// The backdrop id (`appearance.background`) the shipped render of this mood carries.
    pub fn id(self) -> &'static str {
        match self {
            Mood::Sky => "aero-sky",
            Mood::Lagoon => "aero-lagoon",
            Mood::Aurora => "aero-aurora",
            Mood::Meadow => "aero-meadow",
            Mood::Orchid => "aero-orchid",
        }
    }

    /// The mood an id or short name (`aero-sky` or `sky`) names.
    pub fn parse(name: &str) -> Option<Mood> {
        let short = name.strip_prefix("aero-").unwrap_or(name);
        Mood::ALL.into_iter().find(|mood| mood.id().strip_prefix("aero-") == Some(short))
    }
}

/// The seed each shipped backdrop was rendered with (`art/manifest.json` records it too).
pub const SHIPPED: [(Mood, u64); 5] = [
    (Mood::Sky, 2027),
    (Mood::Lagoon, 7),
    (Mood::Aurora, 3),
    (Mood::Meadow, 2009),
    (Mood::Orchid, 2007),
];

/// The size the shipped backdrops are rendered at (the art pipeline's full image).
pub const SHIPPED_SIZE: (usize, usize) = (1600, 1000);

/// Renders `mood` from `seed` at `width` × `height` pixels.
pub fn render(mood: Mood, seed: u64, width: usize, height: usize) -> Canvas {
    let mut canvas = Canvas::new(width, height);
    let mut rng = noise::Rng::new(seed.wrapping_mul(0x2545_F491_4F6C_DD1D) ^ mood as u64);
    match mood {
        Mood::Sky => moods::sky_mood(&mut canvas, &mut rng),
        Mood::Lagoon => moods::lagoon_mood(&mut canvas, &mut rng),
        Mood::Aurora => moods::aurora_mood(&mut canvas, &mut rng),
        Mood::Meadow => moods::meadow_mood(&mut canvas, &mut rng),
        Mood::Orchid => moods::orchid_mood(&mut canvas, &mut rng),
    }
    canvas
}

/// The canvas as an 8-bit sRGB PNG (dithered with `seed`, so it too is deterministic).
pub fn encode_png(canvas: &Canvas, seed: u64) -> Result<Vec<u8>, png::EncodingError> {
    let mut out = Vec::new();
    {
        let width = u32::try_from(canvas.width).unwrap_or(u32::MAX);
        let height = u32::try_from(canvas.height).unwrap_or(u32::MAX);
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_source_srgb(png::SrgbRenderingIntent::Perceptual);
        let mut writer = encoder.write_header()?;
        writer.write_image_data(&canvas.to_srgb8(seed))?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests;
