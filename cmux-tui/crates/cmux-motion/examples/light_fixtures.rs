//! Paints the three wallpapers of the wallpaper lighting gallery
//! (`webviews/src/ui/glass/WallpaperLight.gallery.tsx`) and writes, next to
//! them, the light field `light_field` reads from each, so the gallery draws
//! exactly what the app computes: dusk (a warm sun at the upper right of an
//! indigo sky), aurora (a green band over a night sea at the upper left) and
//! day (a bright low sun at the lower left of a pale sky). The pictures are
//! painted in linear light and encoded to sRGB once, like the field's math.
//!
//! `cargo run -p cmux-motion --example light_fixtures -- ../webviews/src/gallery/fixtures`

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

use cmux_motion::{LightField, LightStyle, light_field, light_point, light_style};

const WIDTH: usize = 960;
const HEIGHT: usize = 600;
/// What the app decodes: 64 px on the long side (`BackdropImageStore.decode(maxPixelSize: 64)`).
const SAMPLE_WIDTH: usize = 64;
const SAMPLE_HEIGHT: usize = 40;

type Paint = fn(f64, f64) -> [f64; 3];

fn mix(a: [f64; 3], b: [f64; 3], t: f64) -> [f64; 3] {
    let t = t.clamp(0., 1.);
    [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
}

fn add(a: [f64; 3], b: [f64; 3], k: f64) -> [f64; 3] {
    [a[0] + b[0] * k, a[1] + b[1] * k, a[2] + b[2] * k]
}

/// A soft round light at `(cx, cy)` (unit space, aspect corrected), `r` wide.
fn glow(u: f64, v: f64, cx: f64, cy: f64, r: f64) -> f64 {
    let d = (((u - cx) * 1.6).powi(2) + (v - cy).powi(2)).sqrt();
    (-(d / r).powi(2)).exp()
}

fn dusk(u: f64, v: f64) -> [f64; 3] {
    let sky = mix([0.010, 0.006, 0.060], [0.32, 0.05, 0.16], v.powf(1.3));
    let sky = add(sky, [1.0, 0.45, 0.12], 0.55 * glow(u, v, 0.78, 0.22, 0.28));
    add(sky, [1.0, 0.82, 0.55], 3.0 * glow(u, v, 0.78, 0.22, 0.045))
}

fn aurora(u: f64, v: f64) -> [f64; 3] {
    let night = mix([0.002, 0.008, 0.020], [0.004, 0.030, 0.050], v);
    // A curtain along a sine, brightest at the left, fading to the right.
    let band = (-((v - 0.30 - 0.08 * (u * 7.0).sin()) / 0.07).powi(2)).exp() * (1.0 - u).powf(1.4);
    let night = add(night, [0.10, 0.85, 0.42], 0.9 * band);
    add(night, [0.30, 0.10, 0.70], 0.25 * glow(u, v, 0.85, 0.12, 0.25))
}

fn day(u: f64, v: f64) -> [f64; 3] {
    let sky = mix([0.30, 0.52, 0.85], [0.80, 0.78, 0.70], v);
    let sky = add(sky, [1.0, 0.9, 0.7], 0.5 * glow(u, v, 0.18, 0.78, 0.30));
    add(sky, [1.0, 1.0, 0.95], 2.0 * glow(u, v, 0.18, 0.78, 0.05))
}

fn encode(c: f64) -> u8 {
    let c = c.clamp(0., 1.);
    let s = if c <= 0.003_130_8 { c * 12.92 } else { 1.055 * c.powf(1. / 2.4) - 0.055 };
    (s * 255.).round() as u8
}

/// The picture as opaque RGBA8 sRGB, `w` by `h`, each pixel the linear mean of
/// a few samples across it (a box filter, the way a downscale averages).
fn paint(f: Paint, w: usize, h: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(w * h * 4);
    let steps = if w < WIDTH { 6 } else { 1 };
    for y in 0..h {
        for x in 0..w {
            let mut sum = [0.; 3];
            for sy in 0..steps {
                for sx in 0..steps {
                    let u = (x as f64 + (sx as f64 + 0.5) / steps as f64) / w as f64;
                    let v = (y as f64 + (sy as f64 + 0.5) / steps as f64) / h as f64;
                    sum = add(sum, f(u, v), 1.);
                }
            }
            let n = (steps * steps) as f64;
            out.extend_from_slice(&[
                encode(sum[0] / n),
                encode(sum[1] / n),
                encode(sum[2] / n),
                255,
            ]);
        }
    }
    out
}

fn write_png(path: &Path, rgba: &[u8], w: usize, h: usize) {
    let file = BufWriter::new(File::create(path).expect("create png"));
    let mut encoder = png::Encoder::new(file, w as u32, h as u32);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Best);
    let rgb: Vec<u8> = rgba.chunks(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
    encoder.write_header().expect("png header").write_image_data(&rgb).expect("png data");
}

fn color(c: [f64; 3]) -> String {
    format!("[{:.4}, {:.4}, {:.4}]", c[0], c[1], c[2])
}

/// The style of a 1100 by 700 window centered on a 1728 by 1080 screen the
/// picture fills: what the gallery's stage stands for.
fn style(f: &LightField) -> LightStyle {
    let (sw, sh) = (1728.0, 1080.0);
    let (lx, ly) = light_point(f, WIDTH as f64 / HEIGHT as f64, sw, sh);
    let (w, h) = (1100.0, 700.0);
    light_style(f, lx, ly, (sw - w) / 2.0, (sh - h) / 2.0, w, h, (sw * sw + sh * sh).sqrt())
        .expect("a window has a style")
}

fn json(name: &str, f: &LightField) -> String {
    let dominant: Vec<String> = (0..f.dominant_count)
        .map(|i| {
            format!(
                "{{\"color\": {}, \"weight\": {:.4}}}",
                color(f.dominant[i]),
                f.dominant_weight[i]
            )
        })
        .collect();
    let s = style(f);
    format!(
        "  \"{name}\": {{\n    \"style\": {{\"dx\": {:.4}, \"dy\": {:.4}, \"rimAlpha\": {:.4}, \"bloomAlpha\": {:.4}, \"tintShare\": {:.4}}},\n    \"ambient\": {},\n    \"ambientLuminance\": {:.4},\n    \"key\": {},\n    \"keyX\": {:.4},\n    \"keyY\": {:.4},\n    \"keyStrength\": {:.4},\n    \"keySpread\": {:.4},\n    \"dominant\": [{}],\n    \"rim\": {},\n    \"bloom\": {},\n    \"tint\": {}\n  }}",
        s.dx,
        s.dy,
        s.rim_alpha,
        s.bloom_alpha,
        s.tint_share,
        color(f.ambient),
        f.ambient_luminance,
        color(f.key),
        f.key_x,
        f.key_y,
        f.key_strength,
        f.key_spread,
        dominant.join(", "),
        color(f.rim),
        color(f.bloom),
        color(f.tint),
    )
}

fn main() {
    let out = PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| ".".into()));
    let assets = out.join("assets");
    std::fs::create_dir_all(&assets).expect("assets folder");
    let pictures: [(&str, Paint); 3] = [("dusk", dusk), ("aurora", aurora), ("day", day)];
    let mut entries = Vec::new();
    for (name, f) in pictures {
        write_png(
            &assets.join(format!("wallpaper-light-{name}.png")),
            &paint(f, WIDTH, HEIGHT),
            WIDTH,
            HEIGHT,
        );
        let small = paint(f, SAMPLE_WIDTH, SAMPLE_HEIGHT);
        let field = light_field(&small, SAMPLE_WIDTH, SAMPLE_HEIGHT, SAMPLE_WIDTH * 4)
            .expect("a light field");
        entries.push(json(name, &field));
    }
    let mut file = File::create(out.join("wallpaperLight.json")).expect("create json");
    writeln!(
        file,
        "{{\n  \"//\": \"Generated by cargo run -p cmux-motion --example light_fixtures; do not edit.\",\n{}\n}}",
        entries.join(",\n")
    )
    .expect("write json");
}
