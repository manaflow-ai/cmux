//! cmux-backdrop-gen: renders a Frutiger Aero 2027 backdrop to PNG.
//!
//!   cmux-backdrop-gen --mood aero-lagoon --seed 7 [--size 1600x1000] --out lagoon.png
//!   cmux-backdrop-gen --shipped OUT_DIR     (every shipped backdrop at its seed, OUT_DIR/<id>.png)

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use cmux_backdrop_gen::{Mood, SHIPPED, SHIPPED_SIZE, encode_png, render};

const USAGE: &str = "usage: cmux-backdrop-gen --mood aero-sky|aero-lagoon|aero-aurora|aero-meadow|aero-orchid --seed N [--size WxH] --out FILE.png\n       cmux-backdrop-gen --shipped OUT_DIR";

fn write(mood: Mood, seed: u64, (width, height): (usize, usize), out: &Path) -> Result<(), String> {
    let canvas = render(mood, seed, width, height);
    let png = encode_png(&canvas, seed).map_err(|e| format!("encoding {}: {e}", out.display()))?;
    std::fs::write(out, png).map_err(|e| format!("writing {}: {e}", out.display()))?;
    println!("{} seed {seed} {width}x{height} -> {}", mood.id(), out.display());
    Ok(())
}

fn parse_size(text: &str) -> Option<(usize, usize)> {
    let (w, h) = text.split_once('x')?;
    Some((w.parse().ok()?, h.parse().ok()?))
}

fn run(args: &[String]) -> Result<(), String> {
    let (mut mood, mut seed, mut size, mut out, mut shipped) =
        (None, None, SHIPPED_SIZE, None, None);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let mut value =
            || it.next().cloned().ok_or_else(|| format!("{flag} needs a value\n{USAGE}"));
        match flag.as_str() {
            "--mood" => {
                let name = value()?;
                mood = Some(
                    Mood::parse(&name).ok_or_else(|| format!("unknown mood {name}\n{USAGE}"))?,
                );
            }
            "--seed" => seed = Some(value()?.parse::<u64>().map_err(|e| format!("--seed: {e}"))?),
            "--size" => {
                size = parse_size(&value()?).ok_or_else(|| format!("--size wants WxH\n{USAGE}"))?;
            }
            "--out" => out = Some(PathBuf::from(value()?)),
            "--shipped" => shipped = Some(PathBuf::from(value()?)),
            "-h" | "--help" => {
                println!("{USAGE}");
                return Ok(());
            }
            other => return Err(format!("unknown argument {other}\n{USAGE}")),
        }
    }
    if let Some(dir) = shipped {
        std::fs::create_dir_all(&dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;
        for (mood, seed) in SHIPPED {
            write(mood, seed, size, &dir.join(format!("{}.png", mood.id())))?;
        }
        return Ok(());
    }
    match (mood, seed, out) {
        (Some(mood), Some(seed), Some(out)) => write(mood, seed, size, &out),
        _ => Err(USAGE.to_string()),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}
