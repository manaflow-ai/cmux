//! `cmux-rd encode-selftest`: encode synthetic 4:2:0 frames through the `H264Encoder` trait
//! with no capture and no network, and report the per-frame encode cost and size. The
//! `marker` workload changes a 640x32 corner per frame; `text` scrolls a full screen of
//! glyph-like blocks by 13 rows per frame (a terminal scroll); `type` draws one 8x12 glyph
//! per frame at a moving cursor (a person typing: a few dozen bytes of change). Each frame
//! also converts a BGRX rectangle of the damaged size to I420 (`convert_ms`), the step the
//! X11 capture runs before the encode. `--threads N` sets the encoder's threads and slices
//! and `--convert-threads N` the converter's (both default to the shipped choice for this
//! machine's cores); `--openh264-options` takes the bench's `key=value` list. The output is
//! checked for Annex-B structure: SPS and PPS before the first IDR, then non-IDR slices.

use crate::args::Opts;
use crate::clock::{now_ns, Rng};
use crate::encoder::{self, EncCfg};
use crate::Res;
use cmux_encode::{bgrx_rect_to_i420, I420};
use serde_json::json;

fn draw_text(pic: &mut I420, offset: usize, seed: u64) {
    let w = pic.width;
    let h = pic.y.len() / w;
    for row in 0..h {
        let line = (row + offset) / 16;
        let in_glyph = (row + offset) % 16 < 12;
        let mut rng = Rng::new(seed ^ (line as u64).wrapping_mul(0x9e37_79b9));
        let base = row * w;
        let mut col = 0;
        while col < w {
            let glyph = in_glyph && rng.range(0, 10) < 7;
            let v = if glyph { 30 } else { 230 };
            let end = (col + 8).min(w);
            pic.y[base + col..base + end].fill(v);
            col = end;
        }
    }
    pic.u.fill(128);
    pic.v.fill(128);
}

fn draw_marker(pic: &mut I420, counter: u32) {
    let w = pic.width;
    for cell in 0..20usize {
        let bit = if cell < 16 { (counter >> cell) & 1 == 1 } else { cell % 2 == 0 };
        let v = if bit { 235 } else { 16 };
        for row in 0..32 {
            let start = row * w + cell * 32;
            pic.y[start..start + 32].fill(v);
        }
    }
}

/// One glyph at the `i`th cell of a text grid of 8x16 cells, its ink alternating each
/// pass over the screen so every frame changes. Returns the damaged rect (x, y, w, h).
fn draw_typed(pic: &mut I420, i: usize) -> (usize, usize, usize, usize) {
    let w = pic.width;
    let (cols, rows) = (w / 8, pic.y.len() / w / 16);
    let (x, y) = ((i % cols) * 8, ((i / cols) % rows) * 16);
    let v = if (i / (cols * rows)).is_multiple_of(2) { 30 } else { 230 };
    for row in y + 2..y + 14 {
        pic.y[row * w + x..row * w + x + 8].fill(v);
    }
    (x, y, 8, 16)
}

/// NAL unit types in an Annex-B access unit.
fn nal_types(au: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 3 < au.len() {
        if au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1 {
            out.push(au[i + 3] & 0x1f);
            i += 3;
        } else {
            i += 1;
        }
    }
    out
}

fn pct(xs: &mut [f64]) -> serde_json::Value {
    if xs.is_empty() {
        return json!(null);
    }
    xs.sort_by(f64::total_cmp);
    let q = |p: f64| xs[((p / 100.0) * (xs.len() - 1) as f64).round() as usize];
    json!({"n": xs.len(), "p50": q(50.0), "p95": q(95.0), "p99": q(99.0), "max": xs[xs.len() - 1]})
}

pub fn run(opts: &Opts) -> Res<()> {
    let width: u32 = opts.num_or("width", 1920)?;
    let height: u32 = opts.num_or("height", 1080)?;
    let frames: usize = opts.num_or("frames", 300)?;
    let codec = opts.str_or("codec", "videotoolbox");
    let workload = opts.str_or("workload", "marker");
    let kbps: u32 = opts.num_or("kbps", 8000)?;
    let profile = opts.str_or("profile", "high");
    let threads: u16 = opts.num_or("threads", encoder::default_threads())?;
    let convert_threads: usize = opts.num_or("convert-threads", cmux_encode::convert_threads())?;
    if width < 640 || height < 64 || width % 2 == 1 || height % 2 == 1 {
        return Err("encode-selftest needs an even size of at least 640x64".into());
    }
    let cfg = EncCfg {
        width,
        height,
        fps: 60,
        kbps,
        threads,
        codec: &codec,
        screen_content: true,
        preset: "ultrafast",
        profile: &profile,
        openh264_lib: opts.get("openh264-lib"),
    };
    let mut enc = encoder::open_with(&cfg, opts.get("openh264-options"))?;
    let (w, h) = (width as usize, height as usize);
    let mut pic = I420::new(w, h);
    draw_text(&mut pic, 0, 7);
    let mut au = Vec::new();
    // The capture's readback of the damaged rect, converted into a picture of its own.
    let bgrx: Vec<u8> = (0..w * h * 4).map(|i| (i * 37) as u8).collect();
    let mut converted = I420::new(w, h);
    let (mut encode_ms, mut convert_ms, mut sizes) = (Vec::new(), Vec::new(), Vec::new());
    let (mut idrs, mut empty) = (0usize, 0usize);
    let mut structure_ok = true;
    for i in 0..frames {
        let (dx, dy, dw, dh) = match workload.as_str() {
            "text" => {
                draw_text(&mut pic, i * 13, 7);
                (0, 0, w, h)
            }
            "type" => draw_typed(&mut pic, i),
            _ => {
                draw_marker(&mut pic, i as u32);
                (0, 0, 640, 32)
            }
        };
        let t0 = now_ns();
        bgrx_rect_to_i420(&bgrx[..dw * dh * 4], &mut converted, dx, dy, dw, dh, convert_threads);
        convert_ms.push((now_ns() - t0) as f64 / 1e6);
        let t0 = now_ns();
        // Capture time in microseconds at 60 fps.
        let idr = enc.encode(&pic, i == 0, i as i64 * 16_667, &mut au)?;
        encode_ms.push((now_ns() - t0) as f64 / 1e6);
        if au.is_empty() {
            empty += 1;
            continue;
        }
        sizes.push(au.len() as f64);
        let types = nal_types(&au);
        if idr {
            idrs += 1;
            structure_ok &= types.contains(&7) && types.contains(&8) && types.contains(&5);
        } else {
            structure_ok &= types.contains(&1) || types.contains(&5);
        }
        if i == 0 {
            structure_ok &= idr;
        }
    }
    let total_bytes: f64 = sizes.iter().sum();
    println!(
        "{}",
        json!({
            "encoder": enc.name(),
            "workload": workload,
            "size": format!("{width}x{height}"),
            "frames": frames,
            "cores": std::thread::available_parallelism().map_or(1, |n| n.get()),
            "threads": threads,
            "convert_threads": convert_threads,
            "convert_ms": pct(&mut convert_ms),
            "encode_ms": pct(&mut encode_ms),
            "bytes_per_frame": pct(&mut sizes),
            "kbit_per_s_at_60": total_bytes * 8.0 / 1000.0 / (frames as f64 / 60.0),
            "idr_frames": idrs,
            "empty_frames": empty,
            "annexb_structure_ok": structure_ok,
        })
    );
    if !structure_ok {
        return Err("encoder output failed the Annex-B structure check".into());
    }
    Ok(())
}
