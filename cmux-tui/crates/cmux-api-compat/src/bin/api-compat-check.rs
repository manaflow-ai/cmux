//! CI guard: fails when the daemon protocol changed in a way that can break
//! an older or newer peer and no compat rule covers it.
//!
//! Run from `cmux-tui/`:
//!
//! ```text
//! cargo run -p cmux-api-compat --bin api-compat-check --locked            # check
//! cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write # refresh the snapshot
//! ```
//!
//! `--write` refuses while a breaking change lacks a rule.

use std::path::PathBuf;
use std::process::ExitCode;

use cmux_api_compat::Schema;
use cmux_api_compat::coverage::{Snapshot, Verdict, check, surface_from_sdk_schema};

const HELP: &str = "\
How to fix: add a revision to spec/api-compat.json with one rule per break
(rename, move, add, remove, retype, rename_value, fill; paths are JSON pointers
on the message line, results sit under /data). Then run
  cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write";

fn main() -> ExitCode {
    let mut root = PathBuf::from(".");
    let mut write = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--write" => write = true,
            "--root" => root = args.next().map(PathBuf::from).unwrap_or(root),
            other => {
                eprintln!(
                    "unknown argument {other}; usage: api-compat-check [--root DIR] [--write]"
                );
                return ExitCode::from(2);
            }
        }
    }
    match run(&root, write) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("api-compat-check: {error}");
            ExitCode::from(2)
        }
    }
}

fn run(root: &std::path::Path, write: bool) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let spec = root.join("spec");
    let sdk: serde_json::Value =
        serde_json::from_slice(&std::fs::read(spec.join("sdk-schema.json"))?)?;
    let compat = Schema::from_json(&std::fs::read(spec.join("api-compat.json"))?)?;
    let snapshot_path = spec.join("api-compat.surface.json");
    let surface = surface_from_sdk_schema(&sdk);
    let snapshot: Snapshot = serde_json::from_slice(&std::fs::read(&snapshot_path)?)?;
    match check(&snapshot, &surface, &compat) {
        Verdict::Clean => {
            println!("api-compat-check: protocol surface matches revision {}", compat.current());
            Ok(ExitCode::SUCCESS)
        }
        Verdict::Uncovered(missing) => {
            eprintln!(
                "api-compat-check: {} breaking protocol change(s) without a compat rule:",
                missing.len()
            );
            for item in &missing {
                eprintln!("  - {item}");
            }
            eprintln!("{HELP}");
            Ok(ExitCode::FAILURE)
        }
        Verdict::StaleSnapshot { breaks } => {
            if write {
                let fresh = Snapshot { revision: compat.current(), surface };
                let mut bytes = serde_json::to_vec_pretty(&fresh)?;
                bytes.push(b'\n');
                std::fs::write(&snapshot_path, bytes)?;
                println!(
                    "api-compat-check: snapshot refreshed at revision {} ({} covered break(s))",
                    compat.current(),
                    breaks.len()
                );
                Ok(ExitCode::SUCCESS)
            } else {
                eprintln!(
                    "api-compat-check: the protocol changed and every break is covered, but spec/api-compat.surface.json is stale."
                );
                eprintln!(
                    "  cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write"
                );
                Ok(ExitCode::FAILURE)
            }
        }
    }
}
