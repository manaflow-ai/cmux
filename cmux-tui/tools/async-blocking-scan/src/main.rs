//! `async-blocking-scan --root DIR [--root DIR ...] [--kind K[,K]] [--json]
//! [--diff BASE] [--rules FILE] [--show-exempt] [--check]`
//!
//! Exit status: 0 after a report, 1 with `--check` when a finding (or an
//! unparsed file) is reported, 2 on a usage or input error.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::ExitCode;

use async_blocking_scan::config::Config;
use async_blocking_scan::finding::{Kind, UnknownKind};
use async_blocking_scan::report::{json_report, text_report};
use async_blocking_scan::{Request, run};

const USAGE: &str = "\
usage: async-blocking-scan --root DIR [DIR ...] [--root DIR ...] [options]

Scans the production Rust files under each root (tests/, benches/, examples/,
#[cfg(test)] and #[test] items are skipped) for the stability queues:
  blocking   (Q11) blocking call in async code; std lock guard held over .await
  spawn      (Q12) dropped tokio JoinHandle; thread started outside a supervisor
  pre_exec   (Q20) call between fork and exec that is not async-signal-safe
  child      (Q20) spawned Child never awaited, waited, stored or kill_on_drop
  unbounded  (Q20) unbounded channel

options:
  --kind K[,K]     only these kinds (default: all)
  --json           one JSON document on stdout
  --diff BASE      only findings that are not at git revision BASE
  --rules FILE     rules file instead of the built-in blocking-paths.toml
  --show-exempt    also list findings an allow comment exempts
  --check          exit 1 when a finding or an unparsed file is reported

An allow comment on the line, or in the comment lines above it or above its
statement, exempts one finding: `// blocking-allow: <why>`, `// supervise-allow:`,
`// pre-exec-allow:`, `// child-allow:`, `// unbounded-allow:`.
";

#[derive(Debug)]
struct Args {
    request: Request,
    json: bool,
    rules: Option<PathBuf>,
    show_exempt: bool,
    check: bool,
}

#[derive(Debug)]
enum ArgError {
    Help,
    Missing(&'static str),
    Unknown(String),
    Kind(UnknownKind),
}

impl std::fmt::Display for ArgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ArgError::Help => Ok(()),
            ArgError::Missing(flag) => write!(f, "{flag} needs a value"),
            ArgError::Unknown(arg) => write!(f, "unknown argument `{arg}`"),
            ArgError::Kind(e) => e.fmt(f),
        }
    }
}

fn parse_args(args: impl IntoIterator<Item = String>) -> Result<Args, ArgError> {
    let mut roots = Vec::new();
    let mut kinds = BTreeSet::new();
    let mut parsed = Args {
        request: Request { roots: Vec::new(), kinds: BTreeSet::new(), diff_base: None },
        json: false,
        rules: None,
        show_exempt: false,
        check: false,
    };
    let mut args = args.into_iter().peekable();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => return Err(ArgError::Help),
            "--root" => {
                let first = args.next().ok_or(ArgError::Missing("--root"))?;
                roots.push(PathBuf::from(first));
                while let Some(next) = args.next_if(|a| !a.starts_with("--")) {
                    roots.push(PathBuf::from(next));
                }
            }
            "--kind" => {
                let list = args.next().ok_or(ArgError::Missing("--kind"))?;
                for name in list.split(',').filter(|n| !n.trim().is_empty()) {
                    kinds.insert(name.parse::<Kind>().map_err(ArgError::Kind)?);
                }
            }
            "--diff" => {
                parsed.request.diff_base = Some(args.next().ok_or(ArgError::Missing("--diff"))?);
            }
            "--rules" => {
                parsed.rules =
                    Some(PathBuf::from(args.next().ok_or(ArgError::Missing("--rules"))?));
            }
            "--json" => parsed.json = true,
            "--show-exempt" => parsed.show_exempt = true,
            "--check" => parsed.check = true,
            _ => return Err(ArgError::Unknown(arg)),
        }
    }
    if kinds.is_empty() {
        kinds.extend(Kind::ALL);
    }
    parsed.request.roots = roots;
    parsed.request.kinds = kinds;
    Ok(parsed)
}

fn main() -> ExitCode {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(args) => args,
        Err(ArgError::Help) => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("async-blocking-scan: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let config = match &args.rules {
        Some(path) => std::fs::read_to_string(path)
            .map_err(|e| format!("{}: {e}", path.display()))
            .and_then(|text| Config::parse(&text).map_err(|e| e.to_string())),
        None => Config::default_rules().map_err(|e| e.to_string()),
    };
    let config = match config {
        Ok(config) => config,
        Err(e) => {
            eprintln!("async-blocking-scan: {e}");
            return ExitCode::from(2);
        }
    };
    let outcome = match run(&config, &args.request) {
        Ok(outcome) => outcome,
        Err(e) => {
            eprintln!("async-blocking-scan: {e}");
            return ExitCode::from(2);
        }
    };
    if args.json {
        match serde_json::to_string_pretty(&json_report(&args.request, &outcome)) {
            Ok(text) => println!("{text}"),
            Err(e) => {
                eprintln!("async-blocking-scan: JSON: {e}");
                return ExitCode::from(2);
            }
        }
    } else {
        print!("{}", text_report(&args.request, &outcome, args.show_exempt));
    }
    let failed = !outcome.reported().is_empty() || !outcome.head.parse_errors.is_empty();
    if args.check && failed { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args, ArgError> {
        parse_args(list.iter().map(|s| (*s).to_string()))
    }

    #[test]
    fn several_roots_after_one_flag_and_repeated_flags() {
        let parsed = args(&["--root", "a", "b", "--json", "--root", "c"]);
        let parsed = parsed.map_err(|e| e.to_string());
        assert!(matches!(&parsed, Ok(a) if a.json && a.request.roots.len() == 3));
    }

    #[test]
    fn kinds_are_a_comma_list_and_default_to_all() {
        let some = args(&["--root", "a", "--kind", "pre_exec,child,unbounded"]);
        assert!(matches!(&some, Ok(a) if a.request.kinds.len() == 3
            && !a.request.kinds.contains(&Kind::Blocking)));
        let all = args(&["--root", "a"]);
        assert!(matches!(&all, Ok(a) if a.request.kinds.len() == Kind::ALL.len()));
        assert!(matches!(args(&["--kind", "nope"]), Err(ArgError::Kind(_))));
    }

    #[test]
    fn diff_takes_a_revision() {
        let parsed = args(&["--root", "a", "--diff", "origin/main"]);
        assert!(matches!(&parsed, Ok(a) if a.request.diff_base.as_deref() == Some("origin/main")));
        assert!(matches!(args(&["--diff"]), Err(ArgError::Missing("--diff"))));
    }
}
