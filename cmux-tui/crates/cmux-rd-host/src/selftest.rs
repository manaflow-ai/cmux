//! `cmux-rd encode-selftest`: encode synthetic 4:2:0 frames through the `H264Encoder` trait
//! with no capture and no network, and report the per-frame encode cost and size. The
//! `marker` workload changes a 640x32 corner per frame; `text` scrolls a full screen of
//! glyph-like blocks by 13 rows per frame (a terminal scroll). The output is checked for
//! Annex-B structure: SPS and PPS before the first IDR, then non-IDR slices.

use crate::args::Opts;
use crate::clock::{now_ns, Rng};
use crate::encoder::{self, EncCfg};
use crate::marker;
use crate::Res;
use cmux_encode::I420;
use serde_json::json;

fn draw_text(pic: &mut I420, offset: usize, seed: u64) {
    // `run` checked the width (at least 640), so every row is one whole chunk.
    let w = pic.width;
    for (row, pixels) in pic.y.chunks_exact_mut(w).enumerate() {
        let line = (row + offset) / 16;
        let in_glyph = (row + offset) % 16 < 12;
        let mut rng = Rng::new(seed ^ (line as u64).wrapping_mul(0x9e37_79b9));
        for glyph_cell in pixels.chunks_mut(8) {
            let glyph = in_glyph && rng.range(0, 10) < 7;
            glyph_cell.fill(if glyph { 30 } else { 230 });
        }
    }
    pic.u.fill(128);
    pic.v.fill(128);
}

/// The glass-to-glass marker (`marker::cells`) in luma: 20 cells of 32x32 at (0,0). `run`
/// checked that the picture holds them (at least 640x64).
fn draw_marker(pic: &mut I420, counter: u32) {
    let cells = marker::cells(counter);
    let w = pic.width;
    for pixels in pic.y.chunks_exact_mut(w).take(marker::CELL as usize) {
        for (span, &white) in pixels.chunks_mut(marker::CELL as usize).zip(&cells) {
            span.fill(if white { 235 } else { 16 });
        }
    }
}

/// NAL unit types in an Annex-B access unit.
fn nal_types(au: &[u8]) -> Vec<u8> {
    // No start code begins inside another one's first three bytes (00 00 01), so every
    // window can be tested.
    au.windows(4)
        .filter_map(|window| match *window {
            [0, 0, 1, header] => Some(header & 0x1f),
            _ => None,
        })
        .collect()
}

fn pct(xs: &mut [f64]) -> serde_json::Value {
    xs.sort_by(f64::total_cmp);
    let Some(&max) = xs.last() else {
        return json!(null);
    };
    let last = xs.len() - 1;
    let q = |p: f64| xs.get(((p / 100.0) * last as f64).round() as usize).copied();
    json!({"n": xs.len(), "p50": q(50.0), "p95": q(95.0), "p99": q(99.0), "max": max})
}

pub fn run(opts: &Opts) -> Res<()> {
    let width: u32 = opts.num_or("width", 1920)?;
    let height: u32 = opts.num_or("height", 1080)?;
    let frames: usize = opts.num_or("frames", 300)?;
    let codec = opts.str_or("codec", "videotoolbox");
    let workload = opts.str_or("workload", "marker");
    let kbps: u32 = opts.num_or("kbps", 8000)?;
    let profile = opts.str_or("profile", "high");
    if width < 640 || height < 64 || width % 2 == 1 || height % 2 == 1 {
        return Err("encode-selftest needs an even size of at least 640x64".into());
    }
    let mut enc = encoder::open(&EncCfg {
        width,
        height,
        fps: 60,
        kbps,
        threads: 2,
        codec: &codec,
        screen_content: true,
        preset: "ultrafast",
        profile: &profile,
        openh264_lib: opts.get("openh264-lib"),
    })?;
    let mut pic = I420::new(width as usize, height as usize);
    draw_text(&mut pic, 0, 7);
    let mut au = Vec::new();
    let (mut encode_ms, mut sizes) = (Vec::new(), Vec::new());
    let (mut idrs, mut empty) = (0usize, 0usize);
    let mut structure_ok = true;
    for i in 0..frames {
        match workload.as_str() {
            "text" => draw_text(&mut pic, i * 13, 7),
            _ => draw_marker(&mut pic, i as u32),
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nal_types_reads_every_start_code() {
        let au = [0, 0, 0, 1, 0x67, 9, 0, 0, 1, 0x68, 0, 0, 1, 0x65, 1, 2, 0, 0, 1];
        assert_eq!(nal_types(&au), vec![7, 8, 5]);
        assert!(nal_types(&[0, 0, 1]).is_empty());
        assert!(nal_types(&[]).is_empty());
    }

    #[test]
    fn the_marker_workload_draws_the_marker_cells() {
        let mut pic = I420::new(640, 64);
        draw_marker(&mut pic, 0b10);
        let luma = |pic: &I420, x: usize, y: usize| pic.y[y * 640 + x];
        assert_eq!((luma(&pic, 16, 16), luma(&pic, 48, 16), luma(&pic, 48, 31)), (16, 235, 235));
        // Guard cells 16..19 are 1,0,1,0; the row under the marker is untouched.
        assert_eq!((luma(&pic, 16 * 32, 0), luma(&pic, 17 * 32, 0)), (235, 16));
        assert_eq!(luma(&pic, 48, 32), 16);
        draw_text(&mut pic, 13, 7);
        assert!(pic.y.iter().all(|&v| v == 30 || v == 230));
    }

    #[test]
    fn pct_of_nothing_is_null() {
        assert_eq!(pct(&mut []), json!(null));
        assert_eq!(pct(&mut [3.0, 1.0, 2.0])["max"], json!(3.0));
    }
}
