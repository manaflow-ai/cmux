//! `codec-bench`: every codec in this build through every scene at each loss
//! rate, one JSON line per row (`--json FILE`) and a Markdown table on stdout.
//!
//!   codec-bench [--codecs h264,vp9,av1] [--scenes scroll,drag,video,typing,noise]
//!               [--loss 0,2] [--rtt-ms 50] [--link-mbps 30] [--seconds 10]
//!               [--size 1920x1080] [--fps 30] [--threads 4] [--on-time-ms 100]
//!               [--deadline-ms 200] [--seed N] [--json FILE]

use std::io::Write;

use cmux_codecs::bench::scene::SceneKind;
use cmux_codecs::bench::{RowCfg, run_row};
use cmux_encode::Codec;

fn arg<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args: Vec<String> = std::env::args().collect();
    let list = |name: &str, default: &str| -> Vec<String> {
        arg(&args, name).unwrap_or(default).split(',').map(|s| s.trim().to_owned()).collect()
    };
    let num = |name: &str, default: f64| -> f64 {
        arg(&args, name).and_then(|v| v.parse().ok()).unwrap_or(default)
    };
    let codecs: Vec<Codec> = list("--codecs", "h264,vp9,av1")
        .iter()
        .map(|c| Codec::parse(c).ok_or(format!("unknown codec {c}")))
        .collect::<Result<_, _>>()?;
    let scenes: Vec<SceneKind> = list("--scenes", "scroll,drag,video,typing,noise")
        .iter()
        .map(|s| SceneKind::parse(s).ok_or(format!("unknown scene {s}")))
        .collect::<Result<_, _>>()?;
    let losses: Vec<f64> =
        list("--loss", "0,2").iter().map(|l| l.parse()).collect::<Result<_, _>>()?;
    let (width, height) = arg(&args, "--size")
        .unwrap_or("1920x1080")
        .split_once('x')
        .map(|(w, h)| (w.parse().unwrap_or(1920), h.parse().unwrap_or(1080)))
        .unwrap_or((1920, 1080));
    let mut json = arg(&args, "--json").map(std::fs::File::create).transpose()?;

    println!(
        "| codec | scene | loss | on-time fps | shown fps | p50/p95 latency ms | PSNR-Y dB (mean/min) | encode ms p50/p95 | decode ms p50/p95 | keyframes | wire Mbps |"
    );
    println!("|---|---|---|---|---|---|---|---|---|---|---|");
    for &scene in &scenes {
        for &loss in &losses {
            for &codec in &codecs {
                let cfg = RowCfg {
                    codec,
                    scene,
                    loss_pct: loss,
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
                        eprintln!("{} {} {loss}%: {e}", codec.wire_name(), scene.name());
                        continue;
                    }
                };
                if let Some(f) = json.as_mut() {
                    writeln!(f, "{row}")?;
                }
                let f =
                    |v: &serde_json::Value| v.as_f64().map_or("-".into(), |x| format!("{x:.1}"));
                println!(
                    "| {} | {} | {}% | {} | {} | {}/{} | {}/{} | {}/{} | {}/{} | {} | {} |",
                    codec.wire_name(),
                    scene.name(),
                    loss,
                    f(&row["on_time_fps"]),
                    f(&row["shown_fps"]),
                    f(&row["latency_ms"]["p50"]),
                    f(&row["latency_ms"]["p95"]),
                    f(&row["psnr_y_db"]["mean"]),
                    f(&row["psnr_y_db"]["min"]),
                    f(&row["encode_ms"]["p50"]),
                    f(&row["encode_ms"]["p95"]),
                    f(&row["decode_ms"]["p50"]),
                    f(&row["decode_ms"]["p95"]),
                    row["keyframes"],
                    f(&row["wire_mbps"]),
                );
                std::io::stdout().flush()?;
            }
        }
    }
    Ok(())
}
