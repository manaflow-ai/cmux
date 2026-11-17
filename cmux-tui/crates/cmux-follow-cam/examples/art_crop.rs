//! Dev tool for the art-crop gallery (design/art-crop-gallery): reads a raw
//! RGB buffer (width * height * 3 bytes) and prints JSON.
//!
//!   cargo run -p cmux-follow-cam --example art_crop -- regions FILE.rgb W H [FX,FY,L,T,R,B]
//!       salient regions, the saliency map, and per aspect (21:9, 16:10,
//!       9:19.5, 1:1, 16:9) the centre crop and the art-aware `fit` crop,
//!       each with its report (kept share, enlargement); with a framing
//!       (focus FX,FY and bleed L,T,R,B, all 0..1; a focus of `-` is none)
//!       also the hand-framed crop
//!   cargo run -p cmux-follow-cam --example art_crop -- resize FILE.rgb W H [FPS]
//!       a simulated window dragged 16:10 -> 9:19.5 -> 21:9 over 8 s, the
//!       crop following through `Camera::set_viewport`, one frame per 1/FPS

use std::process::ExitCode;

use cmux_follow_cam::fit::Salient;
use cmux_follow_cam::{
    Bleed, Camera, Config, CropReport, Event, FitOptions, Framing, Rect, SaliencyOptions, Signal,
    Size, fit, fit_report, saliency,
};
use serde_json::{Value, json};

const ASPECTS: [(&str, f64); 5] = [
    ("21:9", 21.0 / 9.0),
    ("16:10", 16.0 / 10.0),
    ("9:19.5", 9.0 / 19.5),
    ("1:1", 1.0),
    ("16:9", 16.0 / 9.0),
];

fn rect(r: Rect) -> Value {
    json!({ "x": r.x, "y": r.y, "w": r.w, "h": r.h })
}

fn crop(r: CropReport) -> Value {
    json!({ "x": r.crop.x, "y": r.crop.y, "w": r.crop.w, "h": r.crop.h, "kept": r.kept, "enlargement": r.enlargement })
}

/// `FX,FY,L,T,R,B`; FX,FY may be `-,-` for no focus.
fn parse_framing(text: &str) -> Option<Framing> {
    let parts: Vec<&str> = text.split(',').collect();
    let [fx, fy, l, t, r, b] = parts.as_slice() else { return None };
    let num = |v: &str| v.parse::<f64>().ok();
    let focus = num(fx).zip(num(fy));
    Some(Framing {
        focus,
        bleed: Bleed { left: num(l)?, top: num(t)?, right: num(r)?, bottom: num(b)? },
    })
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(cmd), Some(file), Some(w), Some(h)) =
        (args.first(), args.get(1), args.get(2), args.get(3))
    else {
        eprintln!("usage: art_crop regions|resize FILE.rgb W H [FPS]");
        return ExitCode::FAILURE;
    };
    let (Ok(w), Ok(h)) = (w.parse::<usize>(), h.parse::<usize>()) else {
        eprintln!("W and H must be integers");
        return ExitCode::FAILURE;
    };
    let rgb = match std::fs::read(file) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("{file}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let options = SaliencyOptions::default();
    let started = std::time::Instant::now();
    let map = saliency::saliency_map(&rgb, 3, w, h, options);
    let regions = saliency::regions(&map, options);
    let saliency_us = started.elapsed().as_micros();
    let source = Size::new(w as f64, h as f64);
    let out = match cmd.as_str() {
        "regions" => {
            let framing = args.get(4).and_then(|t| parse_framing(t));
            let plain = FitOptions::default();
            let crops: Vec<Value> = ASPECTS
                .iter()
                .map(|(name, a)| {
                    let mut c = json!({
                        "name": name,
                        "aspect": a,
                        "center": crop(fit_report(source, *a, &[], plain)),
                        "fit": crop(fit_report(source, *a, &regions, plain)),
                    });
                    if let Some(f) = framing {
                        let opts = FitOptions { framing: Some(f), ..plain };
                        c["framed"] = crop(fit_report(source, *a, &regions, opts));
                    }
                    c
                })
                .collect();
            json!({
                "source": { "w": w, "h": h },
                "saliency_us": saliency_us,
                "regions": regions.iter().map(|r| json!({"x": r.x, "y": r.y, "w": r.w, "h": r.h, "weight": r.weight})).collect::<Vec<_>>(),
                "map": { "w": map.w, "h": map.h, "values": map.values.iter().map(|v| (v * 100.0).round() / 100.0).collect::<Vec<_>>() },
                "crops": crops,
                "framing": framing.map(|f| json!({
                    "focus": f.focus.map(|(x, y)| json!([x, y])),
                    "bleed": [f.bleed.left, f.bleed.top, f.bleed.right, f.bleed.bottom],
                })),
            })
        }
        "resize" => {
            let fps: f64 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(30.0);
            resize(source, &regions, fps)
        }
        _ => {
            eprintln!("unknown command {cmd}");
            return ExitCode::FAILURE;
        }
    };
    println!("{out}");
    ExitCode::SUCCESS
}

/// The window's size at `t` seconds: hold 16:10, drag to 9:19.5, hold, drag
/// to 21:9, hold. Width and height move with an ease-in-out, as a hand does.
fn window_at(t: f64) -> (f64, f64) {
    let a = (1280.0, 800.0);
    let b = (420.0, 910.0);
    let c = (1400.0, 600.0);
    let ease = |k: f64| {
        let k = k.clamp(0.0, 1.0);
        k * k * (3.0 - 2.0 * k)
    };
    let lerp =
        |p: (f64, f64), q: (f64, f64), k: f64| (p.0 + (q.0 - p.0) * k, p.1 + (q.1 - p.1) * k);
    match t {
        t if t < 0.8 => a,
        t if t < 3.3 => lerp(a, b, ease((t - 0.8) / 2.5)),
        t if t < 4.3 => b,
        t if t < 6.8 => lerp(b, c, ease((t - 4.3) / 2.5)),
        _ => c,
    }
}

fn resize(source: Size, regions: &[Salient], fps: f64) -> Value {
    let config = Config {
        aspect: 16.0 / 10.0,
        zoom: 1.0,
        dead_zone: 0.25,
        max_speed: 0.9,
        max_accel: 3.0,
        ..Config::default()
    };
    let mut camera = Camera::new(config, source.w, source.h);
    for r in regions {
        camera.push(Event {
            t_us: 0,
            signal: Signal::Salient { x: r.x, y: r.y, w: r.w, h: r.h, weight: r.weight },
        });
    }
    let frames = (8.0 * fps).round() as u64;
    let mut out = Vec::new();
    for i in 0..=frames {
        let t = i as f64 / fps;
        let (ww, wh) = window_at(t);
        let aspect = ww / wh;
        camera.set_viewport(aspect, 1.0);
        let crop = camera.advance((t * 1e6).round() as u64);
        out.push(json!({
            "t": t,
            "window": { "w": ww, "h": wh },
            "crop": rect(crop),
            "goal": rect(fit(source, aspect, regions)),
            "center": rect(fit(source, aspect, &[])),
        }));
    }
    json!({
        "source": { "w": source.w, "h": source.h },
        "fps": fps,
        "regions": regions.iter().map(|r| json!({"x": r.x, "y": r.y, "w": r.w, "h": r.h, "weight": r.weight})).collect::<Vec<_>>(),
        "frames": out,
    })
}
