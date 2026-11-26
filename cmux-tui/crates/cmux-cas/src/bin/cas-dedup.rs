//! `cas-dedup --root LABEL=PATH [--root ...] [--sample-every K] [--level N] [--threads T] [--public-dir DIR]`: what the
//! roots would keep as `cas/1` chunks against the bytes they hold, as one JSON object
//! ([`cmux_cas::dedup`]). The fleet measurement under hq `docs/design/cold-storage-and-shared-tier.md`.

use cmux_cas::dedup::{Options, measure};
use cmux_cas::public::Public;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage: cas-dedup --root LABEL=PATH [--root ...] [--sample-every K] [--level N] [--threads T] [--public-dir DIR]";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(bad) => {
            eprintln!("cas-dedup: bad argument {bad}\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<(), String> {
    let mut roots = Vec::new();
    let mut opts = Options::default();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let v = args.next().ok_or_else(|| a.clone())?;
        let num = |v: &str| v.parse::<u64>().map_err(|_| v.to_string());
        match a.as_str() {
            "--root" => {
                let (l, p) = v.split_once('=').ok_or_else(|| v.clone())?;
                roots.push((l.to_string(), PathBuf::from(p)));
            }
            "--sample-every" => opts.sample_every = num(&v)?,
            "--level" => opts.zstd_level = v.parse().map_err(|_| v.clone())?,
            "--public-dir" => {
                let idx = Public::new(&v).index().map_err(|e| format!("{v}: {e}"))?;
                opts.public = Some(idx.prefixes());
            }
            "--threads" => opts.threads = usize::try_from(num(&v)?).map_err(|_| v.clone())?,
            _ => return Err(a),
        }
    }
    if roots.is_empty() || roots.len() > 64 {
        return Err("--root (1 to 64)".into());
    }
    let report = measure(&roots, &opts);
    println!("{}", serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?);
    Ok(())
}
