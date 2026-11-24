//! `cmux-resume-prefetch record PLAN [--max-pages N]` and `cmux-resume-prefetch run PLAN [--threads N]`:
//! the same record and prefetch cmux-host's cloud agent runs on a resume, as a standalone binary the
//! wake-echo harness (scripts/cmux-next/wake-echo-probe.py) uploads into a staging guest for its A/B
//! (hq#21300). Each prints one JSON line.

use std::time::Duration;

fn flag(args: &[String], name: &str) -> Option<u64> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).and_then(|v| v.parse().ok())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (Some(cmd), Some(path)) = (args.get(1), args.get(2)) else {
        eprintln!(
            "usage: cmux-resume-prefetch record|run PLAN [--max-pages N] [--threads N] [--deadline-ms N]"
        );
        std::process::exit(2);
    };
    match cmd.as_str() {
        "record" => {
            let plan = cmux_resume_prefetch::record(flag(&args, "--max-pages").unwrap_or(1 << 20));
            let text = plan.to_json().to_string();
            if let Err(e) = std::fs::write(path, text) {
                eprintln!("write {path}: {e}");
                std::process::exit(1);
            }
            println!("{}", serde_json::json!({"procs": plan.procs.len(), "pages": plan.pages()}));
        }
        "run" => {
            let plan = std::fs::read_to_string(path)
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
                .and_then(|v| cmux_resume_prefetch::Plan::from_json(&v));
            let Some(plan) = plan else {
                println!("{}", serde_json::json!({"error": "no plan"}));
                std::process::exit(1);
            };
            let threads = flag(&args, "--threads").unwrap_or(4) as usize;
            let deadline = Duration::from_millis(flag(&args, "--deadline-ms").unwrap_or(20_000));
            println!("{}", cmux_resume_prefetch::prefetch(&plan, threads, deadline).to_json());
        }
        _ => {
            eprintln!("unknown command {cmd}");
            std::process::exit(2);
        }
    }
}
