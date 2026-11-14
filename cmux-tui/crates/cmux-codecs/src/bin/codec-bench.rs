//! `codec-bench`: every codec in this build through every scene at each loss
//! rate, one JSON line per row (`--json FILE`) and a Markdown table on stdout.
//!
//!   codec-bench [--codecs h264,vp9,av1] [--scenes scroll,drag,video,typing,noise]
//!               [--loss 0,2,2b] [--burst-len 8] [--match-h264 1,2]
//!               [--rtt-ms 50] [--link-mbps 30] [--seconds 10]
//!               [--size 1920x1080] [--fps 30] [--threads 4] [--on-time-ms 100]
//!               [--deadline-ms 200] [--seed N] [--json FILE]
//!
//! A loss written `2b` loses 2% on average in bursts of `--burst-len` datagrams.
//! `--match-h264 1,2` runs every other codec capped at 1x and 2x the media bitrate
//! H.264 used on the same scene and loss (H.264 runs first, uncapped); a factor of
//! 0 is an uncapped row.

use std::io::Write;

use cmux_codecs::bench::scene::SceneKind;
use cmux_codecs::bench::{RowCfg, run_row};
use cmux_encode::Codec;
use serde_json::Value;

fn arg<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

/// One `--loss` entry: percent and burst length (0 for independent loss).
fn parse_loss(s: &str, burst_len: f64) -> Result<(f64, f64), std::num::ParseFloatError> {
    match s.strip_suffix('b') {
        Some(pct) => Ok((pct.parse()?, burst_len)),
        None => Ok((s.parse()?, 0.0)),
    }
}

fn print_row(row: &Value, loss: &str) {
    let f = |v: &Value| v.as_f64().map_or("-".into(), |x| format!("{x:.1}"));
    let cap = row["max_kbps"].as_u64().map_or("-".into(), |k| k.to_string());
    println!(
        "| {} | {} | {loss}% | {cap} | {} | {} | {}/{} | {}/{} | {}/{} | {}/{} | {}/{} | {} | {} | {} |",
        row["codec"].as_str().unwrap_or("?"),
        row["scene"].as_str().unwrap_or("?"),
        f(&row["on_time_fps"]),
        f(&row["shown_fps"]),
        f(&row["latency_ms"]["p50"]),
        f(&row["latency_ms"]["p95"]),
        f(&row["psnr_y_db"]["mean"]),
        f(&row["psnr_y_db"]["min"]),
        f(&row["screen_psnr_y_db"]["mean"]),
        f(&row["screen_psnr_y_db"]["p5"]),
        f(&row["encode_ms"]["p50"]),
        f(&row["encode_ms"]["p95"]),
        f(&row["decode_ms"]["p50"]),
        f(&row["decode_ms"]["p95"]),
        row["keyframes"],
        f(&row["media_mbps"]),
        f(&row["wire_mbps"]),
    );
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args: Vec<String> = std::env::args().collect();
    let list = |name: &str, default: &str| -> Vec<String> {
        arg(&args, name)
            .unwrap_or(default)
            .split(',')
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
            .collect()
    };
    let num = |name: &str, default: f64| -> f64 {
        arg(&args, name).and_then(|v| v.parse().ok()).unwrap_or(default)
    };
    let mut codecs: Vec<Codec> = list("--codecs", "h264,vp9,av1")
        .iter()
        .map(|c| Codec::parse(c).ok_or(format!("unknown codec {c}")))
        .collect::<Result<_, _>>()?;
    let scenes: Vec<SceneKind> = list("--scenes", "scroll,drag,video,typing,noise")
        .iter()
        .map(|s| SceneKind::parse(s).ok_or(format!("unknown scene {s}")))
        .collect::<Result<_, _>>()?;
    let burst_len = num("--burst-len", 8.0);
    let losses: Vec<(String, f64, f64)> = list("--loss", "0,2")
        .into_iter()
        .map(|l| parse_loss(&l, burst_len).map(|(pct, burst)| (l, pct, burst)))
        .collect::<Result<_, _>>()?;
    let factors: Vec<f64> =
        list("--match-h264", "").iter().map(|x| x.parse()).collect::<Result<_, _>>()?;
    if !factors.is_empty() {
        // The H.264 row sets each scene's cap, so it runs first.
        codecs.retain(|&c| c != Codec::H264);
        codecs.insert(0, Codec::H264);
    }
    let (width, height) = arg(&args, "--size")
        .unwrap_or("1920x1080")
        .split_once('x')
        .map(|(w, h)| (w.parse().unwrap_or(1920), h.parse().unwrap_or(1080)))
        .unwrap_or((1920, 1080));
    let mut json = arg(&args, "--json").map(std::fs::File::create).transpose()?;

    println!(
        "| codec | scene | loss | cap kbps | on-time fps | shown fps | p50/p95 latency ms | PSNR-Y dB shown frames (mean/min) | screen PSNR-Y dB (mean/p5) | encode ms p50/p95 | decode ms p50/p95 | keyframes | media Mbps | wire Mbps |"
    );
    println!("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|");
    for &scene in &scenes {
        for (loss_name, loss, burst) in &losses {
            let mut h264_kbps: Option<f64> = None;
            for &codec in &codecs {
                let caps: Vec<Option<u32>> = match (codec, h264_kbps) {
                    (Codec::H264, _) => vec![None],
                    (_, Some(kbps)) if !factors.is_empty() => factors
                        .iter()
                        .map(|x| (*x > 0.0).then(|| (kbps * x).round().max(50.0) as u32))
                        .collect(),
                    _ => vec![None],
                };
                for max_kbps in caps {
                    let cfg = RowCfg {
                        codec,
                        scene,
                        loss_pct: *loss,
                        burst_len: *burst,
                        max_kbps,
                        rtt_ms: num("--rtt-ms", 50.0) as u64,
                        link_mbps: num("--link-mbps", 30.0),
                        seconds: num("--seconds", 10.0) as u64,
                        width,
                        height,
                        fps: num("--fps", 30.0) as u32,
                        threads: num("--threads", 4.0) as u16,
                        on_time_ms: num("--on-time-ms", 100.0) as u64,
                        deadline_ms: num("--deadline-ms", 200.0) as u64,
                        seed: num("--seed", 1.0) as u64,
                    };
                    let row = match run_row(&cfg) {
                        Ok(row) => row,
                        Err(e) => {
                            eprintln!("{} {} {loss_name}%: {e}", codec.wire_name(), scene.name());
                            continue;
                        }
                    };
                    if codec == Codec::H264 {
                        h264_kbps = row["media_mbps"].as_f64().map(|m| m * 1000.0);
                    }
                    if let Some(f) = json.as_mut() {
                        writeln!(f, "{row}")?;
                    }
                    print_row(&row, loss_name);
                    std::io::stdout().flush()?;
                }
            }
        }
    }
    Ok(())
}
