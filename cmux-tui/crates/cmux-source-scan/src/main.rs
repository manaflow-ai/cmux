//! `cmux-source-scan`: the source checks of this crate over a checkout.
//!
//! ```text
//! cmux-source-scan test-hooks [ACPMUX_CRATE_DIR]
//! cmux-source-scan timing-ratio CMUX_CHECKOUT [PATH ...]
//! ```
//!
//! `test-hooks` judges acpmux's `src` (default: this checkout's cmux-tui/crates/acpmux).
//! `timing-ratio` judges PATH (default: CMUX_CHECKOUT/cmux-tui/crates). Exit 0: no finding; 1:
//! findings, one line each; 2: a usage error, a directory or file the check could not read (it
//! names the path; a missing acpmux `src` too), or (timing-ratio) a missing checkout or scan
//! root, a root with no `.rs` file, or a nextest.toml that does not parse.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use cmux_source_scan::{test_hooks, timing_ratio};

const USAGE: &str = "usage: cmux-source-scan test-hooks [ACPMUX_CRATE_DIR]\n       cmux-source-scan timing-ratio CMUX_CHECKOUT [PATH ...]";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [command, rest @ ..] if command == "test-hooks" => {
            let dir = rest.first().map_or_else(
                || Path::new(env!("CARGO_MANIFEST_DIR")).join("../acpmux"),
                PathBuf::from,
            );
            let found = match test_hooks::judge_tree(&dir) {
                Ok(found) => found,
                Err(error) => {
                    eprintln!("error: {error}");
                    return ExitCode::from(2);
                }
            };
            if found.is_empty() {
                println!("process-wide test hooks: ok");
                return ExitCode::SUCCESS;
            }
            println!(
                "process-wide test hooks: a parallel test can replace or clear another's hook (cmux#41350):"
            );
            for finding in &found {
                println!("{finding}");
            }
            ExitCode::from(1)
        }
        [command, checkout, paths @ ..] if command == "timing-ratio" => {
            let checkout = PathBuf::from(checkout);
            let roots: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
            let scan = match timing_ratio::scan(&checkout, &roots) {
                Ok(scan) => scan,
                Err(error) => {
                    eprintln!("error: {error}");
                    return ExitCode::from(2);
                }
            };
            for file in &scan.unparsed {
                eprintln!("not judged (does not parse): {file}");
            }
            for finding in &scan.found {
                println!("{finding}");
            }
            eprintln!("{} files scanned", scan.files);
            if scan.found.is_empty() {
                return ExitCode::SUCCESS;
            }
            eprintln!(
                "\n{} wall-clock ratio or percentile assert(s) in the default test run. Keep a deterministic ordering or liveness check there and move the timing to an #[ignore]d test for its own run (cmux#41391; cmuxterm-hq docs/handbook/timing-on-a-busy-host.md, fix 7).",
                scan.found.len()
            );
            ExitCode::from(1)
        }
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}
