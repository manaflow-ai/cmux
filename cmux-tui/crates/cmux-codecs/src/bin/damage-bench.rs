//! `damage-bench`: what "encode only the damaged region" saves OpenH264, one JSON row per run.
//! Idea ledger w47-29 (goal screen-share-linux-pairs). Measurement only: no host links this.
//!
//!   damage-bench --rect 640x32 --mode full|crop|skip [--content typing|page] [--frames 300]
//!                [--threads 4] [--size 1920x1080] [--dump DIR] [--json FILE]
//!
//! Every frame is the same static base screen with one rectangle (at the bottom left for typing,
//! centered for page) showing new content, so the damage is exactly that rectangle:
//! - `full`: the whole frame is coded, as shipped today;
//! - `crop`: only the rectangle is coded, by an encoder opened at the rectangle's size (the cost
//!   floor of a sub-picture stream; a viewer would paste the decoded rectangle over its screen);
//! - `skip`: the whole frame is coded, but with the openh264-damage.patch every macroblock outside
//!   the rectangle is forced to P_Skip (needs a build with that patch; `CMUX_OH264_DAMAGE`).
//! `--dump DIR` writes the coded pictures as raw I420 so x264 codes the very same frames.
use cmux_codecs::bench::scene::{PAGE_FRAMES, Scene, SceneKind};
use cmux_codecs::{H264Decoder, H264Impl, open_h264, psnr_y};
use cmux_encode::{EncCfg, I420, VideoDecoder};
use serde_json::json;
use std::io::Write;
use std::time::Instant;

fn arg<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn dims(s: &str) -> Res<(usize, usize)> {
    let (w, h) = s.split_once('x').ok_or("expected WxH")?;
    Ok((w.parse()?, h.parse()?))
}

fn crop(p: &I420, x: usize, y: usize, w: usize, h: usize) -> I420 {
    let mut o = I420::new(w, h);
    let (cw, pcw) = (w / 2, p.width / 2);
    for r in 0..h {
        o.y[r * w..(r + 1) * w].copy_from_slice(&p.y[(y + r) * p.width + x..][..w]);
    }
    for r in 0..h / 2 {
        o.u[r * cw..(r + 1) * cw].copy_from_slice(&p.u[(y / 2 + r) * pcw + x / 2..][..cw]);
        o.v[r * cw..(r + 1) * cw].copy_from_slice(&p.v[(y / 2 + r) * pcw + x / 2..][..cw]);
    }
    o
}

fn paste(dst: &mut I420, src: &I420, x: usize, y: usize, h: usize) {
    let (w, dcw, cw) = (src.width, dst.width / 2, src.width / 2);
    for r in 0..h {
        dst.y[(y + r) * dst.width + x..][..w].copy_from_slice(&src.y[r * w..(r + 1) * w]);
    }
    for r in 0..h / 2 {
        dst.u[(y / 2 + r) * dcw + x / 2..][..cw].copy_from_slice(&src.u[r * cw..(r + 1) * cw]);
        dst.v[(y / 2 + r) * dcw + x / 2..][..cw].copy_from_slice(&src.v[r * cw..(r + 1) * cw]);
    }
}

fn pct(v: &mut [f64], q: f64) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    v[((v.len() - 1) as f64 * q) as usize]
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args: Vec<String> = std::env::args().collect();
    let (rw, rh) = dims(arg(&args, "--rect").unwrap_or("640x32"))?;
    let mode = arg(&args, "--mode").unwrap_or("full").to_owned();
    let content = arg(&args, "--content").unwrap_or("typing").to_owned();
    let frames: usize = arg(&args, "--frames").and_then(|s| s.parse().ok()).unwrap_or(300);
    let threads: u16 = arg(&args, "--threads").and_then(|s| s.parse().ok()).unwrap_or(4);
    let (w, h) = dims(arg(&args, "--size").unwrap_or("1920x1080"))?;
    let (rw, rh) = (rw.min(w), rh.min(h));
    let (rx, ry) = if content == "typing" {
        (0, (h - rh) / 16 * 16)
    } else {
        ((w - rw) / 32 * 16, (h - rh) / 32 * 16)
    };
    let kind = if content == "typing" { SceneKind::Typing } else { SceneKind::Page };
    // The distinct pictures the rectangle shows, one per frame (pages: PAGE_FRAMES ticks apart).
    let mut scene = Scene::new(kind, w, h, 1);
    let base = scene.picture().clone();
    let step = if kind == SceneKind::Page { PAGE_FRAMES } else { 1 };
    let mut pool = Vec::new();
    for _ in 0..frames {
        for _ in 0..step {
            scene.advance();
        }
        pool.push(scene.picture().clone());
    }
    let frame = |i: usize| {
        let mut f = base.clone();
        paste(&mut f, &crop(&pool[i], rx, ry, rw, rh), rx, ry, rh);
        f
    };
    if mode == "skip" {
        // SAFETY: single-threaded here, before the encoder exists; the patch reads it once.
        unsafe { std::env::set_var("CMUX_OH264_DAMAGE", format!("{rx},{ry},{rw},{rh}")) };
    }
    let (ew, eh) = if mode == "crop" { (rw, rh) } else { (w, h) };
    let cfg = EncCfg {
        width: ew as u32,
        height: eh as u32,
        fps: 30,
        kbps: 8_000,
        threads,
        screen_content: true,
    };
    let mut enc = open_h264(H264Impl::OpenH264, &cfg)?.ok_or("no encoder")?;
    let mut dec = H264Decoder::new()?;
    let mut shown = I420::new(0, 0);
    let mut viewer = base.clone();
    let mut dump = arg(&args, "--dump")
        .map(|d| {
            std::fs::File::create(format!("{d}/{content}-{rw}x{rh}-{mode}.yuv"))
                .map(std::io::BufWriter::new)
        })
        .transpose()?;
    let (mut ms, mut full_psnr, mut rect_psnr, mut bytes, mut coded) =
        (vec![], vec![], vec![], 0usize, 0usize);
    let mut au = Vec::new();
    for i in 0..=frames {
        // Frame 0 is the base screen alone (the IDR); frame i shows pool[i - 1] in the rectangle.
        let src = if i == 0 { base.clone() } else { frame(i - 1) };
        let pic = if mode == "crop" { crop(&src, rx, ry, rw, rh) } else { src.clone() };
        if let Some(d) = dump.as_mut() {
            d.write_all(&pic.y)?;
            d.write_all(&pic.u)?;
            d.write_all(&pic.v)?;
        }
        au.clear();
        let t = Instant::now();
        enc.encode(&pic, false, i as i64 * 33, &mut au)?;
        let dt = t.elapsed().as_secs_f64() * 1e3;
        let got = !au.is_empty() && dec.decode(&au, &mut shown)?;
        if got {
            if mode == "crop" {
                paste(&mut viewer, &shown, rx, ry, rh);
            } else {
                viewer = shown.clone();
            }
        }
        if i == 0 {
            continue;
        }
        ms.push(dt);
        if !au.is_empty() {
            coded += 1;
            bytes += au.len();
        }
        full_psnr.push(psnr_y(&src, &viewer).min(99.0));
        let (a, b) = (crop(&src, rx, ry, rw, rh), crop(&viewer, rx, ry, rw, rh));
        rect_psnr.push(psnr_y(&a, &b).min(99.0));
    }
    let mean = |v: &[f64]| v.iter().sum::<f64>() / v.len() as f64;
    let row = json!({
        "content": content, "rect": format!("{rw}x{rh}"), "mode": mode, "frames": frames,
        "tuning": std::env::var("CMUX_OPENH264_TUNING").unwrap_or_default(),
        "ablate": std::env::var("CMUX_OH264_ABLATE").unwrap_or_default(),
        "encode_ms_p50": pct(&mut ms.clone(), 0.5), "encode_ms_p90": pct(&mut ms.clone(), 0.9),
        "encode_ms_mean": mean(&ms), "psnr_full_db": mean(&full_psnr), "psnr_rect_db": mean(&rect_psnr),
        "kbps": bytes as f64 * 8.0 * 30.0 / frames as f64 / 1000.0, "frames_coded": coded,
    });
    println!("{row}");
    if let Some(f) = arg(&args, "--json") {
        writeln!(std::fs::OpenOptions::new().create(true).append(true).open(f)?, "{row}")?;
    }
    Ok(())
}
