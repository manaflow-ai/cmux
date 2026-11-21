//! `cmux-path-doctor`: reads this machine's link and prints one line on what
//! to change, or the whole reading as JSON.
//!
//! ```text
//! cmux-path-doctor [--json] [--load] [--fix] [--pings N] [--peer NAME]...
//! cmux-path-doctor --diagnose FILE   # rules only, on observations as JSON (a phone's)
//! ```

use std::process::ExitCode;

use cmux_path_doctor::probe::{ProbeOptions, examine};
use cmux_path_doctor::{Observations, Report, Severity};

const USAGE: &str = "usage: cmux-path-doctor [--json] [--load] [--fix] [--pings N] [--peer NAME]... | --diagnose FILE|-";

fn main() -> ExitCode {
    let mut opts = ProbeOptions::default();
    let mut json = false;
    let mut diagnose: Option<String> = None;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--json" => json = true,
            "--load" => opts.load = true,
            "--fix" => opts.fix = true,
            "--pings" => match args.next().and_then(|n| n.parse().ok()) {
                Some(n) => opts.pings = n,
                None => return usage(),
            },
            "--peer" => match args.next() {
                Some(p) => opts.peers.push(p),
                None => return usage(),
            },
            "--diagnose" => match args.next() {
                Some(f) => diagnose = Some(f),
                None => return usage(),
            },
            "-h" | "--help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            _ => return usage(),
        }
    }
    let report = match diagnose {
        Some(file) => {
            let text = if file == "-" {
                std::io::read_to_string(std::io::stdin())
            } else {
                std::fs::read_to_string(&file)
            };
            let parsed = text
                .map_err(|e| e.to_string())
                .and_then(|t| serde_json::from_str::<Observations>(&t).map_err(|e| e.to_string()));
            match parsed {
                Ok(obs) => Report::new(obs),
                Err(e) => {
                    eprintln!("cmux-path-doctor: cannot read observations from {file}: {e}");
                    return ExitCode::from(2);
                }
            }
        }
        None => examine(&opts),
    };
    if json {
        match serde_json::to_string_pretty(&report) {
            Ok(s) => println!("{s}"),
            Err(e) => {
                eprintln!("cmux-path-doctor: {e}");
                return ExitCode::from(2);
            }
        }
    } else {
        println!("{}", report.headline());
        for f in report.findings.iter().skip(1).filter(|f| f.severity >= Severity::Info) {
            println!("  - {}", f.line);
        }
        for f in report.findings.iter().filter_map(|f| f.fixed.as_ref()) {
            println!("  fixed: {f}");
        }
        for s in &report.observations.skipped {
            println!("  (skipped {s})");
        }
    }
    let worst = report.findings.first().map_or(Severity::Ok, |f| f.severity);
    if worst >= Severity::Warn { ExitCode::from(1) } else { ExitCode::SUCCESS }
}

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::from(2)
}
