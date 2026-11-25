//! cmux-follow-cut: a vertical (9:16, 4:5 or 1:1) cut of a landscape screen
//! recording whose crop follows what the person on screen does, moved by
//! the same follow camera the iPhone viewer's Follow mode uses.
//!
//!   cmux-follow-cut IN.mp4 OUT.mp4 [--aspect 9:16|4:5|1:1] [--width 1080]
//!       [--trace SIGNALS.jsonl] [--no-damage] [--zoom 1] [--fps 30]
//!       [--path-out PATH.jsonl] [--ffmpeg PATH]
//!
//! Frames come from ffmpeg as YUV4MPEG2 (4:4:4) and go back to it the same
//! way for H.264; the input's audio is copied over. Damage and scene cuts
//! come from the frames themselves (`damage`), merged with the signals of
//! `--trace` when the recording has them (times in microseconds from the
//! video's start; a `source` event scales the trace to the video). Needs
//! ffmpeg with libx264: on PATH, `--ffmpeg` or `CMUX_FFMPEG`.

use std::io::{BufRead, BufReader, BufWriter, Read, Write};
use std::process::ExitCode;

use cmux_process::{Child, Command, Stdio};

use cmux_follow_cam::damage::{DamageConfig, FrameDiff, thumbnail, thumbnail_size};
use cmux_follow_cam::video::{Aspect, Y4mHeader, crop_plane, fit_trace};
use cmux_follow_cam::{Camera, Config, Event, Frame, read_trace};

/// The damage thumbnail's width.
const THUMB_W: usize = 320;

struct Args {
    input: String,
    output: String,
    aspect: Aspect,
    width: u32,
    trace: Option<String>,
    damage: bool,
    zoom: f64,
    fps: f64,
    path_out: Option<String>,
    ffmpeg: String,
}

const USAGE: &str = "usage: cmux-follow-cut IN OUT [--aspect 9:16|4:5|1:1] [--width 1080] \
[--trace SIGNALS.jsonl] [--no-damage] [--zoom 1] [--fps 30] [--path-out PATH.jsonl] [--ffmpeg PATH]";

fn parse_args() -> Result<Args, String> {
    let mut positional = Vec::new();
    let mut args = Args {
        input: String::new(),
        output: String::new(),
        aspect: Aspect::Tall,
        width: 1080,
        trace: None,
        damage: true,
        zoom: 1.0,
        fps: 30.0,
        path_out: None,
        ffmpeg: std::env::var("CMUX_FFMPEG").unwrap_or_else(|_| "ffmpeg".into()),
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        let mut value = |name: &str| it.next().ok_or(format!("{name} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Err(USAGE.into()),
            "--aspect" => args.aspect = value("--aspect")?.parse()?,
            "--width" => {
                args.width = value("--width")?.parse().map_err(|e| format!("--width: {e}"))?;
            }
            "--trace" => args.trace = Some(value("--trace")?),
            "--no-damage" => args.damage = false,
            "--zoom" => args.zoom = value("--zoom")?.parse().map_err(|e| format!("--zoom: {e}"))?,
            "--fps" => args.fps = value("--fps")?.parse().map_err(|e| format!("--fps: {e}"))?,
            "--path-out" => args.path_out = Some(value("--path-out")?),
            "--ffmpeg" => args.ffmpeg = value("--ffmpeg")?,
            flag if flag.starts_with("--") => return Err(format!("unknown flag {flag}\n{USAGE}")),
            _ => positional.push(arg),
        }
    }
    let [input, output] = <[String; 2]>::try_from(positional).map_err(|_| USAGE.to_string())?;
    if !(args.fps > 0.0 && args.zoom >= 1.0 && args.width >= 2) {
        return Err("--fps must be over 0, --zoom at least 1, --width at least 2".into());
    }
    args.input = input;
    args.output = output;
    Ok(args)
}

fn spawn(ffmpeg: &str, argv: &[&str], stdin: Stdio, stdout: Stdio) -> Result<Child, String> {
    Command::new(ffmpeg)
        .args(["-nostdin", "-hide_banner", "-loglevel", "error"])
        .args(argv)
        .stdin(stdin)
        .stdout(stdout)
        .spawn()
        .map_err(|e| format!("cannot run {ffmpeg} ({e}): install ffmpeg or pass --ffmpeg PATH"))
}

/// A child's pipe that `spawn` asked for.
fn piped<T>(pipe: Option<T>) -> Result<T, String> {
    pipe.ok_or_else(|| "ffmpeg started without its pipe".to_string())
}

fn run(args: &Args) -> Result<(), String> {
    let trace = match &args.trace {
        Some(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
            let mut events = read_trace(&text).map_err(|e| format!("{path}: {e}"))?;
            events.sort_by_key(|e| e.t_us);
            events
        }
        None => Vec::new(),
    };

    let rate = format!("fps={}", args.fps);
    let mut decoder = spawn(
        &args.ffmpeg,
        &["-i", &args.input, "-an", "-vf", &rate, "-pix_fmt", "yuv444p", "-f", "yuv4mpegpipe", "-"],
        Stdio::null(),
        Stdio::piped(),
    )?;
    let mut frames_in = BufReader::with_capacity(1 << 20, piped(decoder.stdout.take())?);
    let mut line = String::new();
    frames_in.read_line(&mut line).map_err(|e| format!("reading frames: {e}"))?;
    if line.is_empty() {
        let _ = decoder.wait();
        return Err(format!("ffmpeg decoded no frames from {}", args.input));
    }
    let header = Y4mHeader::parse(line.trim_end())?;
    if !header.chroma.starts_with("444") {
        return Err(format!("expected 4:4:4 frames from ffmpeg, got {}", header.chroma));
    }
    let (w, h) = (header.w, header.h);
    if w == 0 || h == 0 {
        return Err(format!("ffmpeg gave {w}x{h} frames"));
    }
    let frame_bytes = header.frame_bytes()?;
    let (ow, oh) = args.aspect.output_size(args.width);
    let (ow, oh) = (ow as usize, oh as usize);

    let out_header =
        format!("YUV4MPEG2 W{ow} H{oh} F{}:{} Ip A1:1 C444\n", header.fps_num, header.fps_den);
    let mut encoder = spawn(
        &args.ffmpeg,
        &[
            "-y",
            "-f",
            "yuv4mpegpipe",
            "-i",
            "-",
            "-i",
            &args.input,
            "-map",
            "0:v:0",
            "-map",
            "1:a?",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            "-movflags",
            "+faststart",
            &args.output,
        ],
        Stdio::piped(),
        Stdio::null(),
    )?;
    let mut frames_out = BufWriter::with_capacity(1 << 20, piped(encoder.stdin.take())?);
    frames_out.write_all(out_header.as_bytes()).map_err(|e| format!("encoder: {e}"))?;

    let config = Config { aspect: args.aspect.ratio(), zoom: args.zoom, ..Config::default() };
    let mut camera = Camera::new(config, w as f64, h as f64);
    let trace = fit_trace(&trace, w as f64, h as f64);
    let mut trace = trace.iter().peekable();
    let (thumb_w, thumb_h) = thumbnail_size(w, h, THUMB_W);
    let scale = (w as f64 / thumb_w as f64, h as f64 / thumb_h as f64);
    let mut diff = FrameDiff::new(DamageConfig::default(), thumb_w, thumb_h);

    let mut frame = vec![0u8; frame_bytes];
    let mut out = vec![0u8; ow * oh * 3];
    let mut path = Vec::new();
    let (mut cuts, mut damage) = (0usize, 0usize);
    for index in 0u64.. {
        line.clear();
        if frames_in.read_line(&mut line).map_err(|e| format!("reading frames: {e}"))? == 0 {
            break;
        }
        if !line.starts_with("FRAME") {
            return Err(format!("bad frame header {line:?}"));
        }
        frames_in.read_exact(&mut frame).map_err(|e| format!("short frame {index}: {e}"))?;
        let t_us = header.frame_time_us(index);
        while let Some(event) = trace.next_if(|e| e.t_us <= t_us) {
            camera.push(*event);
        }
        if args.damage {
            let luma = frame.get(..w * h).unwrap_or_default();
            let (gray, _) = thumbnail(luma, w, h, THUMB_W);
            for signal in diff.push(&gray, scale) {
                match signal {
                    cmux_follow_cam::Signal::Cut => cuts += 1,
                    _ => damage += 1,
                }
                camera.push(Event { t_us, signal });
            }
        }
        let rect = camera.advance(t_us);
        path.push(Frame { t_us, rect });
        for (src, dst) in frame.chunks_exact(w * h).zip(out.chunks_exact_mut(ow * oh)) {
            crop_plane(src, w, h, rect, dst, ow, oh);
        }
        frames_out
            .write_all(b"FRAME\n")
            .and_then(|()| frames_out.write_all(&out))
            .map_err(|e| format!("encoder stopped at frame {index}: {e}"))?;
    }
    drop(frames_out);
    let decoded = decoder.wait().map_err(|e| e.to_string())?;
    let encoded = encoder.wait().map_err(|e| e.to_string())?;
    if !decoded.success() || !encoded.success() {
        return Err(format!("ffmpeg failed: decode {decoded}, encode {encoded}"));
    }
    if let Some(path_out) = &args.path_out {
        let mut text = String::new();
        for frame in &path {
            text += &serde_json::to_string(frame).map_err(|e| format!("{path_out}: {e}"))?;
            text.push('\n');
        }
        std::fs::write(path_out, text).map_err(|e| format!("{path_out}: {e}"))?;
    }
    eprintln!(
        "cmux-follow-cut: {} frames {w}x{h} -> {ow}x{oh} {}, {damage} damage rects, {cuts} cuts",
        path.len(),
        args.output
    );
    Ok(())
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(args) => args,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("cmux-follow-cut: {message}");
            ExitCode::FAILURE
        }
    }
}
