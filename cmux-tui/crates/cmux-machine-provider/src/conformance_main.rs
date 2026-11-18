//! `cmux-machine-conformance`: the machine lifecycle conformance suite
//! (attach, connect, agent turn, pause, resume, detach) against one provider
//! profile, or a Cloud journey record imported as one run.
//!
//! ```text
//! cmux-machine-conformance run --profile FILE [--provider NAME] [--set NAME=VALUE]... [--iterations N] [--out DIR]
//! cmux-machine-conformance import-journey --provider NAME --journey FILE [--out DIR]
//! cmux-machine-conformance table FILE...
//! ```
//!
//! `run` and `import-journey` write `DIR/runs.json` and print the table;
//! `table` prints one table for every runs.json given. Exit 1 when a step
//! that ran did not pass.

use cmux_machine_provider::conformance::{self, Profile, Run};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok((table, green)) => {
            print!("{table}");
            if green { ExitCode::SUCCESS } else { ExitCode::from(1) }
        }
        Err(e) => {
            eprintln!("cmux-machine-conformance: {e}");
            ExitCode::from(2)
        }
    }
}

fn run(args: &[String]) -> Result<(String, bool), String> {
    let (verb, rest) = args.split_first().ok_or("usage: see --help")?;
    let runs = match verb.as_str() {
        "--help" | "-h" => return Ok((usage(), true)),
        "run" => {
            let (flags, sets, _) = parse(rest)?;
            let mut profile =
                Profile::load(Path::new(flags.get("profile").ok_or("--profile is required")?))?;
            if let Some(provider) = flags.get("provider") {
                profile.provider = provider.clone();
            }
            let iterations: u32 = flags.get("iterations").map_or(Ok(1), |n| {
                n.parse().map_err(|_| format!("--iterations {n}: not a number"))
            })?;
            let out = out_dir(&flags)?;
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let mut runs = Vec::new();
            for iteration in 1..=iterations {
                let mut values = sets.clone();
                values.insert("tag".into(), format!("conf-{stamp}-{iteration}"));
                let scratch = out.join(format!("run-{iteration}"));
                std::fs::create_dir_all(&scratch)
                    .map_err(|e| format!("{}: {e}", scratch.display()))?;
                let run = conformance::run_profile(&profile, &values, iteration, &scratch);
                eprintln!("{} run {iteration}/{iterations}: {}", profile.provider, summary(&run));
                runs.push(run);
            }
            write_runs(&out, &runs)?;
            runs
        }
        "import-journey" => {
            let (flags, _, _) = parse(rest)?;
            let provider = flags.get("provider").ok_or("--provider is required")?;
            let path = flags.get("journey").ok_or("--journey is required")?;
            let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
            let journey = serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))?;
            let runs = vec![conformance::import_journey(provider, &journey)?];
            write_runs(&out_dir(&flags)?, &runs)?;
            runs
        }
        "table" => {
            let (_, _, files) = parse(rest)?;
            let mut runs: Vec<Run> = Vec::new();
            for path in files {
                let text = std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
                let mut more: Vec<Run> =
                    serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))?;
                runs.append(&mut more);
            }
            runs
        }
        other => return Err(format!("unknown verb {other:?}; see --help")),
    };
    Ok((conformance::table(&runs), conformance::green(&runs)))
}

fn usage() -> String {
    include_str!("conformance_main.rs")
        .lines()
        .skip_while(|l| !l.starts_with("//! ```text"))
        .skip(1)
        .take_while(|l| !l.starts_with("//! ```"))
        .map(|l| l.trim_start_matches("//! "))
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

fn summary(run: &Run) -> String {
    run.steps
        .iter()
        .map(|s| format!("{:?}={:?}/{}ms", s.step, s.status, s.ms))
        .collect::<Vec<_>>()
        .join(" ")
}

type Parsed = (BTreeMap<String, String>, BTreeMap<String, String>, Vec<String>);

/// `--name value` flags, `--set NAME=VALUE` values, and bare arguments.
fn parse(args: &[String]) -> Result<Parsed, String> {
    let (mut flags, mut sets, mut bare) = (BTreeMap::new(), BTreeMap::new(), Vec::new());
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let Some(name) = arg.strip_prefix("--") else {
            bare.push(arg.clone());
            continue;
        };
        let value = it.next().ok_or_else(|| format!("--{name} needs a value"))?;
        if name == "set" {
            let (k, v) =
                value.split_once('=').ok_or_else(|| format!("--set {value}: want NAME=VALUE"))?;
            if k == "tag" {
                return Err("{tag} is set per run; pick another name".into());
            }
            sets.insert(k.to_owned(), v.to_owned());
        } else {
            flags.insert(name.to_owned(), value.clone());
        }
    }
    Ok((flags, sets, bare))
}

fn out_dir(flags: &BTreeMap<String, String>) -> Result<PathBuf, String> {
    let dir = flags.get("out").map_or_else(|| PathBuf::from("conformance-out"), PathBuf::from);
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    Ok(dir)
}

fn write_runs(dir: &Path, runs: &[Run]) -> Result<(), String> {
    let path = dir.join("runs.json");
    let text = serde_json::to_string_pretty(runs).map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))
}
