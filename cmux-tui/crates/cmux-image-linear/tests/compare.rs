//! Before and after, one harness: the old acpmux model-copy downscale (area average of
//! 8-bit sRGB codes) against `cmux_image_linear`, on black and white detail and a real
//! screenshot, written as PNGs, and both timed on a 6K screenshot-sized image.
//! Run: `GAMMA_OUT=DIR cargo test --release -p cmux-image-linear --test compare -- --ignored --nocapture`.

use std::path::{Path, PathBuf};
use std::time::Instant;

/// The downscale acpmux's model copies used before (#gamma): each input pixel to one output
/// pixel by integer position, sRGB codes summed, weighted by alpha. RGB in, RGB out.
fn srgb_box(src: &[u8], w: u32, h: u32, out_w: u32, out_h: u32) -> Vec<u8> {
    let mut sums = vec![[0u64; 4]; out_w as usize];
    let mut pixels = Vec::with_capacity((out_w * out_h * 3) as usize);
    let flush = |sums: &mut [[u64; 4]], pixels: &mut Vec<u8>| {
        for sum in sums.iter_mut() {
            let weight = sum[3];
            pixels.extend(sum[..3].iter().map(|v| v.checked_div(weight).unwrap_or(0) as u8));
            *sum = [0; 4];
        }
    };
    let mut target = 0u32;
    for y in 0..h {
        let ty = (u64::from(y) * u64::from(out_h) / u64::from(h)) as u32;
        if ty != target {
            flush(&mut sums, &mut pixels);
            target = ty;
        }
        let row = &src[(y * w * 3) as usize..((y + 1) * w * 3) as usize];
        for (x, px) in row.chunks_exact(3).enumerate() {
            let tx = (x as u64 * u64::from(out_w) / u64::from(w)) as usize;
            for (s, v) in sums[tx].iter_mut().zip(px) {
                *s += u64::from(*v) * 255;
            }
            sums[tx][3] += 255;
        }
    }
    flush(&mut sums, &mut pixels);
    pixels
}

fn write_png(path: &Path, w: u32, h: u32, rgb: &[u8]) {
    let file = std::fs::File::create(path).unwrap();
    let mut e = png::Encoder::new(std::io::BufWriter::new(file), w, h);
    e.set_color(png::ColorType::Rgb);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().unwrap().write_image_data(rgb).unwrap();
}

fn read_png_rgb(path: &Path) -> Option<(u32, u32, Vec<u8>)> {
    let mut d = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).ok()?));
    d.set_transformations(png::Transformations::normalize_to_color8());
    let mut r = d.read_info().ok()?;
    let mut buf = vec![0; r.output_buffer_size()];
    let info = r.next_frame(&mut buf).ok()?;
    buf.truncate(info.buffer_size());
    let rgb = match info.color_type {
        png::ColorType::Rgb => buf,
        png::ColorType::Rgba => buf
            .chunks_exact(4)
            .flat_map(|p| {
                let a = u32::from(p[3]);
                let on = |c: u8| ((u32::from(c) * a + 255 * (255 - a)) / 255) as u8;
                [on(p[0]), on(p[1]), on(p[2])]
            })
            .collect(),
        png::ColorType::Grayscale => buf.iter().flat_map(|g| [*g; 3]).collect(),
        _ => return None,
    };
    Some((info.width, info.height, rgb))
}

fn pattern(n: u32, checker: bool) -> Vec<u8> {
    (0..n * n)
        .flat_map(|i| {
            let (x, y) = (i % n, i / n);
            let on = if checker { (x + y) % 2 == 0 } else { y % 2 == 0 };
            [if on { 255 } else { 0 }; 3]
        })
        .collect()
}

fn mean(rgb: &[u8]) -> f64 {
    rgb.iter().map(|v| f64::from(*v)).sum::<f64>() / rgb.len() as f64
}

/// Milliseconds of the fastest of `runs`.
fn best_ms(runs: usize, mut f: impl FnMut() -> Vec<u8>) -> f64 {
    (0..runs)
        .map(|_| {
            let t = Instant::now();
            std::hint::black_box(f());
            t.elapsed().as_secs_f64() * 1000.0
        })
        .fold(f64::INFINITY, f64::min)
}

#[test]
#[ignore = "writes before/after PNGs and timings; run by hand"]
fn before_and_after() {
    let out = PathBuf::from(std::env::var("GAMMA_OUT").unwrap_or_else(|_| "gamma-out".into()));
    std::fs::create_dir_all(&out).unwrap();
    let n = 1024;
    for (name, checker) in [("checker", true), ("lines", false)] {
        let src = pattern(n, checker);
        write_png(&out.join(format!("{name}-source.png")), n, n, &src);
        for factor in [2, 4] {
            let m = n / factor;
            let before = srgb_box(&src, n, n, m, m);
            let after = cmux_image_linear::downscale(&src, 3, n, n, m, m);
            write_png(&out.join(format!("{name}-{factor}x-before.png")), m, m, &before);
            write_png(&out.join(format!("{name}-{factor}x-after.png")), m, m, &after);
            println!(
                "{name} {factor}x: before mean {:.1}, after mean {:.1}",
                mean(&before),
                mean(&after)
            );
        }
    }
    let shot = std::env::var("GAMMA_SCREENSHOT").map(PathBuf::from).unwrap_or_else(|_| {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../docs/assets/screenshot.png")
    });
    match read_png_rgb(&shot) {
        Some((w, h, rgb)) => {
            for edge in [1568, 800] {
                let (ow, oh) = cmux_image_linear::fit(w, h, edge);
                let before = srgb_box(&rgb, w, h, ow, oh);
                let after = cmux_image_linear::downscale(&rgb, 3, w, h, ow, oh);
                write_png(&out.join(format!("screenshot-{edge}-before.png")), ow, oh, &before);
                write_png(&out.join(format!("screenshot-{edge}-after.png")), ow, oh, &after);
                println!(
                    "screenshot {w}x{h} -> {ow}x{oh}: before mean {:.1}, after mean {:.1}",
                    mean(&before),
                    mean(&after)
                );
            }
        }
        None => println!("no screenshot at {}", shot.display()),
    }
    // A 6K Retina screenshot's size, noisy, to Claude's 1568 edge.
    let (w, h) = (5344u32, 3044u32);
    let mut seed = 0x9e37_79b9_u32;
    let big: Vec<u8> = (0..w * h * 3)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed as u8
        })
        .collect();
    let (ow, oh) = cmux_image_linear::fit(w, h, 1568);
    let before = best_ms(5, || srgb_box(&big, w, h, ow, oh));
    let after = best_ms(5, || cmux_image_linear::downscale(&big, 3, w, h, ow, oh));
    println!("timing {w}x{h} -> {ow}x{oh}, best of 5: before {before:.1} ms, after {after:.1} ms");
}
