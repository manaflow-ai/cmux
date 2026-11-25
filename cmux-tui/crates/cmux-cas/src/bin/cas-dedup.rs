//! `cas-dedup --root LABEL=PATH [--root ...] [--sample-every K] [--level N] [--threads T]`: what the
//! roots would keep as `cas/1` chunks against the bytes they hold, as one JSON object
//! ([`cmux_cas::dedup`]). The fleet measurement under hq `docs/design/cold-storage-and-shared-tier.md`.

use cmux_cas::dedup::{Options, measure};
use std::path::PathBuf;

fn main() {
    let mut roots = Vec::new();
    let mut opts = Options::default();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let v = args.next().unwrap_or_else(|| usage(&a));
        match a.as_str() {
            "--root" => {
                let (l, p) = v.split_once('=').unwrap_or_else(|| usage(&v));
                roots.push((l.to_string(), PathBuf::from(p)));
            }
            "--sample-every" => opts.sample_every = v.parse().unwrap_or_else(|_| usage(&v)),
            "--level" => opts.zstd_level = v.parse().unwrap_or_else(|_| usage(&v)),
            "--threads" => opts.threads = v.parse().unwrap_or_else(|_| usage(&v)),
            _ => usage(&a),
        }
    }
    if roots.is_empty() || roots.len() > 64 {
        usage("--root (1 to 64)");
    }
    let report = measure(&roots, &opts);
    println!("{}", serde_json::to_string_pretty(&report).unwrap_or_default());
}

fn usage(bad: &str) -> ! {
    eprintln!(
        "cas-dedup: bad argument {bad}\nusage: cas-dedup --root LABEL=PATH [--root ...] [--sample-every K] [--level N] [--threads T]"
    );
    std::process::exit(2)
}
