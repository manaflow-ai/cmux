//! Prints a scene wallpaper's packed uniforms for a list of frames, so the
//! gallery (design/live-wallpapers-gallery) runs the scene engine on exactly
//! what Rust hands the GPU instead of re-implementing the scene in JS.
//!
//! ```text
//! cargo run -p cmux-wallpaper --example scene_frames -- FOLDER [options]
//!   --size WxH           rendered pixels (default 960x540)
//!   --backing S          rendered pixels per point (default 2)
//!   --theme INK,PAPER    sRGB hex colors (default the gallery's dark theme)
//!   --accent HEX         (default the manifest's first variant's, else #3D7BFF)
//!   --times T,T,...      seconds; or
//!   --fps N --duration S every 1/N s from 0 to S
//!   --last 1             print only the last frame (a still after the run up)
//!   --pointer T:X:Y:D;.. pointer events: from T seconds the pointer is at
//!                        (X, Y), fractions of the size, button down when D is 1
//! ```
//!
//! Output, one JSON object: `glsl` (the engine's GLSL ES 3.00), `loop`
//! (seconds), and `frames`: for each time, `t`, `frame` (the 40 floats of
//! `Frame`) and `scene` (the 512 floats of `Scene`). Frames are evaluated in
//! order, so physics steps through them as in the app.

use cmux_wallpaper::{
    FrameInput, Manifest, Player, SCENE_ENGINE_GLSL, SCENE_FLOATS, pack_frame, scene,
    srgb_to_linear,
};
use serde_json::{Value, json};
use std::process::ExitCode;

struct Event {
    t: f32,
    x: f32,
    y: f32,
    down: bool,
}

fn hex(s: &str) -> Result<[f32; 3], String> {
    let h = s.trim().trim_start_matches('#');
    let n = u32::from_str_radix(h.get(..6).ok_or(format!("bad color {s:?}"))?, 16)
        .map_err(|e| format!("bad color {s:?}: {e}"))?;
    let c = |shift: u32| {
        srgb_to_linear(f32::from(u8::try_from((n >> shift) & 255).unwrap_or(0)) / 255.0)
    };
    Ok([c(16), c(8), c(0)])
}

fn floats(s: &str) -> Result<Vec<f32>, String> {
    s.split([',', ':'])
        .filter(|p| !p.is_empty())
        .map(|p| p.trim().parse::<f32>().map_err(|e| format!("bad number {p:?}: {e}")))
        .collect()
}

fn run() -> Result<Value, String> {
    let mut args = std::env::args().skip(1);
    let folder = args.next().ok_or("usage: scene_frames FOLDER [options]")?;
    let (mut width, mut height, mut backing) = (960.0_f32, 540.0_f32, 2.0_f32);
    let (mut ink, mut paper) = (hex("#ECEBE6")?, hex("#111214")?);
    let mut accent = None;
    let mut times = Vec::new();
    let (mut fps, mut duration) = (0.0_f32, 0.0_f32);
    let mut events = Vec::new();
    let mut last_only = false;
    while let Some(flag) = args.next() {
        let value = args.next().ok_or(format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--size" => {
                let v = floats(&value.replace('x', ","))?;
                let [w, h] = v.as_slice() else { return Err("--size is WxH".into()) };
                (width, height) = (*w, *h);
            }
            "--backing" => backing = value.parse().map_err(|e| format!("--backing: {e}"))?,
            "--theme" => {
                let (i, p) = value.split_once(',').ok_or("--theme is INK,PAPER")?;
                (ink, paper) = (hex(i)?, hex(p)?);
            }
            "--accent" => accent = Some(hex(&value)?),
            "--times" => times = floats(&value)?,
            "--last" => last_only = value == "1",
            "--fps" => fps = value.parse().map_err(|e| format!("--fps: {e}"))?,
            "--duration" => duration = value.parse().map_err(|e| format!("--duration: {e}"))?,
            "--pointer" => {
                for e in value.split(';').filter(|e| !e.trim().is_empty()) {
                    let v = floats(e)?;
                    let [t, x, y, d] = v.as_slice() else { return Err(format!("bad event {e:?}")) };
                    events.push(Event { t: *t, x: *x, y: *y, down: *d > 0.5 });
                }
            }
            _ => return Err(format!("unknown option {flag}")),
        }
    }
    if fps > 0.0 {
        let n = (duration * fps).ceil().max(1.0);
        let mut i = 0.0;
        while i < n {
            times.push(i / fps);
            i += 1.0;
        }
    }
    if times.is_empty() {
        times.push(0.0);
    }

    let dir = std::path::Path::new(&folder);
    let read = |name: &str| {
        std::fs::read(dir.join(name)).map_err(|e| format!("{}: {e}", dir.join(name).display()))
    };
    let manifest_bytes = read("wallpaper.json")?;
    let manifest = Manifest::parse(&manifest_bytes).map_err(|e| format!("wallpaper.json: {e}"))?;
    let file = manifest
        .scene
        .clone()
        .or_else(|| manifest.lottie.clone())
        .ok_or("the manifest names no scene or lottie file")?;
    let parsed = scene::load(&manifest, &read(&file)?).map_err(|e| format!("{file}: {e}"))?;
    let accent = match accent {
        Some(a) => a,
        None => {
            let v: Value = serde_json::from_slice(&manifest_bytes).unwrap_or(Value::Null);
            hex(v.pointer("/variants/0/accent").and_then(Value::as_str).unwrap_or("#3D7BFF"))?
        }
    };
    let loop_s = parsed.loop_seconds();
    let mut player = Player::new(parsed);
    let mut out = [0.0_f32; SCENE_FLOATS];
    let mut frames = Vec::with_capacity(times.len());
    let mut last = 0.0_f32;
    for (n, &t) in times.iter().enumerate() {
        let event = events.iter().rfind(|e| e.t <= t);
        let input = FrameInput {
            time: t,
            delta: (t - last).max(1.0 / 60.0),
            frame_number: f32::from(u16::try_from(n).unwrap_or(u16::MAX)),
            width,
            height,
            backing_scale: backing,
            seed: 0.37,
            pointer_x: event.map_or(width * 0.5, |e| e.x * width),
            pointer_y: event.map_or(height * 0.5, |e| e.y * height),
            presence: if event.is_some() { 1.0 } else { 0.0 },
            button_down: event.is_some_and(|e| e.down),
            dark: paper.iter().sum::<f32>() < 1.5,
            ink,
            paper,
            accent,
            ..FrameInput::default()
        };
        last = t;
        player.evaluate(&input, &mut out);
        if last_only && n + 1 < times.len() {
            continue;
        }
        frames.push(json!({ "t": t, "frame": pack_frame(&input).to_vec(), "scene": out.to_vec() }));
    }
    Ok(json!({ "glsl": SCENE_ENGINE_GLSL, "loop": loop_s, "frames": frames }))
}

fn main() -> ExitCode {
    match run() {
        Ok(v) => {
            println!("{v}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("scene_frames: {e}");
            ExitCode::FAILURE
        }
    }
}
