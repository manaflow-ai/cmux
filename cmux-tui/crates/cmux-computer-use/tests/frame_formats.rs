//! Bytes, encode time and fidelity of every screenshot encoding the engine
//! could send, on real screens from the repo (terminals, the app window, a
//! browser, a table) and a synthetic photo-like gradient. Run it in release:
//!
//! ```text
//! cargo test --release -p cmux-computer-use --test frame_formats -- --ignored --nocapture
//! ```
//!
//! Every input first goes through `frame::downscale`, so the sizes are the
//! ones the agent would receive.

use std::path::{Path, PathBuf};
use std::time::Instant;

use cmux_computer_use::desktop::{Point, RawFrame};
use cmux_computer_use::frame;

const FIXTURES: &[&str] = &[
    "docs/assets/screenshot.png",
    "plans/cmux-next/evidence/terminal-after-cli-input.png",
    "plans/cmux-next/spec-proposals/visuals/images/window/dark-default.png",
    "plans/cmux-next/spec-proposals/visuals/images/window/light-browser.png",
    "markdown-obsidian-parity/screenshots/table-chromium-light.png",
    "webviews/src/gallery/fixtures/assets/chief-wallpaper-reference.png",
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn load_png(path: &Path) -> Option<(u32, u32, Vec<u8>)> {
    let mut decoder = png::Decoder::new(std::fs::File::open(path).ok()?);
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    let px = &buf[..info.buffer_size()];
    let rgba = match info.color_type {
        png::ColorType::Rgba => px.to_vec(),
        png::ColorType::Rgb => px.chunks(3).flat_map(|c| [c[0], c[1], c[2], 255]).collect(),
        png::ColorType::Grayscale => px.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::GrayscaleAlpha => {
            px.chunks(2).flat_map(|c| [c[0], c[0], c[0], c[1]]).collect()
        }
        png::ColorType::Indexed => return None,
    };
    Some((info.width, info.height, rgba))
}

/// A smooth photo-like frame: two gradients, a ripple and grain.
fn gradient(w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity((w * h * 4) as usize);
    let mut seed = 0x2545_f491_u32;
    for y in 0..h {
        for x in 0..w {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            let grain = (seed % 9) as f64 - 4.0;
            let fx = x as f64 / w as f64;
            let fy = y as f64 / h as f64;
            let ripple = 20.0 * ((fx * 31.0).sin() * (fy * 17.0).cos());
            let r = 40.0 + 180.0 * fx + ripple + grain;
            let g = 60.0 + 120.0 * fy - ripple * 0.5 + grain;
            let b = 200.0 - 150.0 * fx * fy + grain;
            out.extend([r, g, b].map(|v| v.clamp(0.0, 255.0) as u8));
            out.push(255);
        }
    }
    out
}

fn luma(rgb: &[u8], stride: usize) -> Vec<f64> {
    rgb.chunks(stride)
        .map(|p| 0.299 * p[0] as f64 + 0.587 * p[1] as f64 + 0.114 * p[2] as f64)
        .collect()
}

/// Mean SSIM over 8x8 windows of luma.
fn ssim(a: &[f64], b: &[f64], w: usize, h: usize) -> f64 {
    let (c1, c2) = ((0.01f64 * 255.0).powi(2), (0.03f64 * 255.0).powi(2));
    let (mut total, mut n) = (0.0, 0.0);
    for by in (0..h.saturating_sub(7)).step_by(8) {
        for bx in (0..w.saturating_sub(7)).step_by(8) {
            let (mut ma, mut mb) = (0.0, 0.0);
            for y in by..by + 8 {
                for x in bx..bx + 8 {
                    ma += a[y * w + x];
                    mb += b[y * w + x];
                }
            }
            ma /= 64.0;
            mb /= 64.0;
            let (mut va, mut vb, mut cov) = (0.0, 0.0, 0.0);
            for y in by..by + 8 {
                for x in bx..bx + 8 {
                    let (da, db) = (a[y * w + x] - ma, b[y * w + x] - mb);
                    va += da * da;
                    vb += db * db;
                    cov += da * db;
                }
            }
            va /= 63.0;
            vb /= 63.0;
            cov /= 63.0;
            total += ((2.0 * ma * mb + c1) * (2.0 * cov + c2))
                / ((ma * ma + mb * mb + c1) * (va + vb + c2));
            n += 1.0;
        }
    }
    total / n.max(1.0)
}

/// PSNR (dB) of luma on text strokes only: pixels whose horizontal or
/// vertical luma step in the original is over 48, where JPEG ringing shows.
fn edge_psnr(a: &[f64], b: &[f64], w: usize, h: usize) -> f64 {
    let (mut se, mut n) = (0.0, 0.0);
    for y in 1..h {
        for x in 1..w {
            let i = y * w + x;
            if (a[i] - a[i - 1]).abs() > 48.0 || (a[i] - a[i - w]).abs() > 48.0 {
                se += (a[i] - b[i]).powi(2);
                n += 1.0;
            }
        }
    }
    if n == 0.0 {
        return f64::NAN;
    }
    let mse = se / n;
    if mse == 0.0 { f64::INFINITY } else { 10.0 * (255.0f64 * 255.0 / mse).log10() }
}

fn median_ms(mut f: impl FnMut() -> Vec<u8>) -> (Vec<u8>, f64) {
    let mut out = f(); // warm
    let mut times = Vec::new();
    for _ in 0..7 {
        let t = Instant::now();
        out = f();
        times.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    (out, times[times.len() / 2])
}

fn decode_jpeg(bytes: &[u8]) -> Vec<u8> {
    jpeg_decoder::Decoder::new(bytes).decode().expect("decode jpeg")
}

/// The fixtures, downscaled as the engine would, plus the gradient.
fn inputs() -> Vec<(String, u32, u32, Vec<u8>)> {
    let mut inputs: Vec<(String, u32, u32, Vec<u8>)> = Vec::new();
    for rel in FIXTURES {
        let path = repo_root().join(rel);
        let Some((w, h, rgba)) = load_png(&path) else {
            println!("skip {rel}: not readable");
            continue;
        };
        let raw =
            RawFrame { width: w, height: h, rgba, scale: 1.0, origin: Point { x: 0.0, y: 0.0 } };
        let (w, h, px) = frame::downscale(&raw, frame::DEFAULT_MAX_EDGE);
        let name = Path::new(rel).file_stem().unwrap().to_string_lossy().into_owned();
        inputs.push((name, w, h, px));
    }
    inputs.push(("gradient".into(), 1456, 910, gradient(1456, 910)));
    inputs
}

#[test]
#[ignore = "measurement: run with --release -- --ignored --nocapture"]
fn frame_formats_table() {
    let inputs = inputs();

    println!("| frame | size | encoding | bytes | vs png | encode ms | SSIM | edge PSNR dB |");
    println!("|---|---|---|---:|---:|---:|---:|---:|");
    let mut sums: Vec<(String, f64, f64, f64, f64)> = Vec::new();
    for (name, w, h, px) in &inputs {
        let (w, h) = (*w, *h);
        let orig = luma(px, 4);
        let (png, png_ms) = median_ms(|| frame::encode_png(w, h, px).unwrap());
        let mut rows: Vec<(String, usize, f64, f64, f64)> =
            vec![("png (today)".into(), png.len(), png_ms, 1.0, f64::INFINITY)];
        for q in [70u8, 80, 85, 90] {
            for (label, sampling) in [
                ("4:2:0", jpeg_encoder::SamplingFactor::R_4_2_0),
                ("4:4:4", jpeg_encoder::SamplingFactor::R_4_4_4),
            ] {
                let (jpg, ms) = median_ms(|| {
                    let mut out = Vec::new();
                    let mut enc = jpeg_encoder::Encoder::new(&mut out, q);
                    enc.set_sampling_factor(sampling);
                    enc.encode(px, w as u16, h as u16, jpeg_encoder::ColorType::Rgba).unwrap();
                    out
                });
                let back = luma(&decode_jpeg(&jpg), 3);
                rows.push((
                    format!("jpeg q{q} {label}"),
                    jpg.len(),
                    ms,
                    ssim(&orig, &back, w as usize, h as usize),
                    edge_psnr(&orig, &back, w as usize, h as usize),
                ));
            }
        }
        let (shipped, ms) = median_ms(|| frame::encode(w, h, px, false).unwrap().1);
        let (mime, _) = frame::encode(w, h, px, false).unwrap();
        let (s, p) = if mime == "image/jpeg" {
            let back = luma(&decode_jpeg(&shipped), 3);
            (
                ssim(&orig, &back, w as usize, h as usize),
                edge_psnr(&orig, &back, w as usize, h as usize),
            )
        } else {
            (1.0, f64::INFINITY)
        };
        rows.push((format!("shipped ({mime})"), shipped.len(), ms, s, p));
        for (label, bytes, ms, s, p) in rows {
            println!(
                "| {name} | {w}x{h} | {label} | {bytes} | {:.0}% | {ms:.1} | {s:.4} | {p:.1} |",
                100.0 * bytes as f64 / png.len() as f64
            );
            sums.push((label, bytes as f64, ms, s, p));
        }
    }
    println!("\nMeans over {} frames:", inputs.len());
    println!("| encoding | mean bytes | mean ms | mean SSIM | min edge PSNR dB |");
    println!("|---|---:|---:|---:|---:|");
    let mut labels: Vec<String> = sums.iter().map(|r| r.0.clone()).collect();
    labels.dedup();
    labels.sort();
    labels.dedup();
    for label in labels {
        let rows: Vec<_> = sums.iter().filter(|r| r.0 == label).collect();
        let n = rows.len() as f64;
        let min_p = rows.iter().map(|r| r.4).fold(f64::INFINITY, f64::min);
        println!(
            "| {label} | {:.0} | {:.1} | {:.4} | {:.1} |",
            rows.iter().map(|r| r.1).sum::<f64>() / n,
            rows.iter().map(|r| r.2).sum::<f64>() / n,
            rows.iter().map(|r| r.3).sum::<f64>() / n,
            min_p
        );
    }
}
