//! CI guard: fails when the daemon protocol changed in a way that can break
//! an older or newer peer and no compat rule covers it.
//!
//! Two checks run on every invocation:
//!
//! - JSON shape: the flattened `spec/sdk-schema.json` surface against
//!   `spec/api-compat.surface.json` and the revision rules.
//! - Wire ids: the families, `method_id`/`event_id`, priorities and binary
//!   layouts of `spec/sdk-schema.json` and `spec/resource-operations-v2.json`
//!   against the append-only ledger `spec/api-compat.wire.json`. With
//!   `--base REV` the rules start from the ledger at `REV` (CI passes the
//!   pull request's base), so a ledger entry dropped or edited by hand is
//!   refused.
//!
//! Run from `cmux-tui/`:
//!
//! ```text
//! cargo run -p cmux-api-compat --bin api-compat-check --locked                                  # check
//! cargo run -p cmux-api-compat --bin api-compat-check --locked -- --base origin/feat-cmux-next  # check as CI does
//! cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write                       # refresh the snapshot and ledger
//! ```
//!
//! `--write` refuses while a breaking change lacks a rule or a wire rule
//! refuses a change. With `--base` it also puts back ledger entries edited
//! by hand.

#![forbid(unsafe_code)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use cmux_api_compat::Schema;
use cmux_api_compat::coverage::{Snapshot, Verdict, check, surface_from_sdk_schema};
use cmux_api_compat::fixtures::{Fixtures, check_fixtures, check_vectors};
use cmux_api_compat::wire::{
    LEDGER_FILE, RESOURCE_OPERATIONS, SDK_SCHEMA, WireLedgers, WireReport, check_against_base,
    check_all, ids_from_resource_operations, ids_from_sdk_schema,
};

const HELP: &str = "\
How to fix: add a revision to spec/api-compat.json with one rule per break
(rename, move, add, remove, retype, rename_value, fill; paths are JSON pointers
on the message line, results sit under /data). Then run
  cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write";

const WRITE_HINT: &str =
    "  cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write";

const USAGE: &str = "usage: api-compat-check [--root DIR] [--base REV] [--write]";

fn wire_help() -> String {
    format!(
        "Wire ids are append-only: never reuse or renumber a method_id, event_id or
family byte, and keep each schema file's ids in its own range. To remove a
name, keep its entry in spec/{LEDGER_FILE} and add \"removed\": \"<why>\"
to it; never delete or edit an entry otherwise. A priority change needs a new
`priority_changed_reason` beside the priority; a binary layout change needs a
higher `layout_version`."
    )
}

fn main() -> ExitCode {
    let mut root = PathBuf::from(".");
    let mut base = None;
    let mut write = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--write" => write = true,
            "--root" => root = args.next().map(PathBuf::from).unwrap_or(root),
            "--base" => match args.next() {
                Some(rev) if !rev.starts_with('-') => base = Some(rev),
                _ => {
                    eprintln!("--base needs a revision; {USAGE}");
                    return ExitCode::from(2);
                }
            },
            other => {
                eprintln!("unknown argument {other}; {USAGE}");
                return ExitCode::from(2);
            }
        }
    }
    match run(&root, base.as_deref(), write) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("api-compat-check: {error}");
            ExitCode::from(2)
        }
    }
}

type Error = Box<dyn std::error::Error>;

fn read_json(path: &Path) -> Result<serde_json::Value, Error> {
    Ok(serde_json::from_slice(&std::fs::read(path)?)?)
}

fn run(root: &Path, base: Option<&str>, write: bool) -> Result<ExitCode, Error> {
    let spec = root.join("spec");
    let sdk = read_json(&spec.join(SDK_SCHEMA))?;
    let compat = Schema::from_json(&std::fs::read(spec.join("api-compat.json"))?)?;
    let snapshot_path = spec.join("api-compat.surface.json");
    let surface = surface_from_sdk_schema(&sdk);
    let snapshot: Snapshot = serde_json::from_slice(&std::fs::read(&snapshot_path)?)?;
    let fixtures: Fixtures =
        serde_json::from_slice(&std::fs::read(spec.join("api-compat-fixtures.json"))?)?;
    let fixture_problems = check_fixtures(&compat, &fixtures);
    if !fixture_problems.is_empty() {
        eprintln!("api-compat-check: spec/api-compat-fixtures.json does not match the rules:");
        for problem in &fixture_problems {
            eprintln!("  - {problem}");
        }
        eprintln!(
            "Every rule needs a fixture case crossing it in both directions; the cross-version matrix replays them."
        );
        return Ok(ExitCode::FAILURE);
    }
    let vector_problems = check_vectors(&fixtures);
    if !vector_problems.is_empty() {
        eprintln!("api-compat-check: spec/api-compat-fixtures.json has failing vectors:");
        for problem in &vector_problems {
            eprintln!("  - {problem}");
        }
        return Ok(ExitCode::FAILURE);
    }

    let Some(wire) = check_wire(root, &sdk, base)? else { return Ok(ExitCode::FAILURE) };

    let verdict = check(&snapshot, &surface, &compat);
    if let Verdict::Uncovered(missing) = &verdict {
        eprintln!(
            "api-compat-check: {} breaking protocol change(s) without a compat rule:",
            missing.len()
        );
        for item in missing {
            eprintln!("  - {item}");
        }
        eprintln!("{HELP}");
        return Ok(ExitCode::FAILURE);
    }
    let stale_surface = matches!(verdict, Verdict::StaleSnapshot { .. });
    let stale_ledger = wire.report.is_stale(&wire.ledger);
    if !stale_surface && !stale_ledger {
        println!(
            "api-compat-check: protocol surface and wire ids match revision {}",
            compat.current()
        );
        return Ok(ExitCode::SUCCESS);
    }
    if !write {
        if stale_surface {
            eprintln!(
                "api-compat-check: the protocol changed and every break is covered, but spec/api-compat.surface.json is stale."
            );
        }
        if stale_ledger {
            eprintln!(
                "api-compat-check: the schema files give out wire ids, priorities or layouts spec/{LEDGER_FILE} does not record yet."
            );
        }
        eprintln!("{WRITE_HINT}");
        return Ok(ExitCode::FAILURE);
    }
    if let Verdict::StaleSnapshot { breaks } = verdict {
        let fresh = Snapshot { revision: compat.current(), surface };
        write_pretty(&snapshot_path, &fresh)?;
        println!(
            "api-compat-check: snapshot refreshed at revision {} ({} covered break(s))",
            compat.current(),
            breaks.len()
        );
    }
    if stale_ledger {
        write_pretty(&wire.path, &wire.report.ledgers)?;
        println!("api-compat-check: spec/{LEDGER_FILE} refreshed");
    }
    Ok(ExitCode::SUCCESS)
}

/// The wire id check and the ledger file it ran on.
struct Wire {
    path: PathBuf,
    ledger: WireLedgers,
    report: WireReport,
}

/// Runs the wire rules; `None` after printing what they refused. Ledger
/// edits refuse only without `--write`, which puts the entries back.
fn check_wire(
    root: &Path,
    sdk: &serde_json::Value,
    base: Option<&str>,
) -> Result<Option<Wire>, Error> {
    let spec = root.join("spec");
    let operations = read_json(&spec.join(RESOURCE_OPERATIONS))?;
    let path = spec.join(LEDGER_FILE);
    let ledger = WireLedgers::from_json(&std::fs::read(&path)?)?;
    let files = BTreeMap::from([
        (SDK_SCHEMA.to_owned(), ids_from_sdk_schema(sdk)?),
        (RESOURCE_OPERATIONS.to_owned(), ids_from_resource_operations(&operations)?),
    ]);
    let report = match base.map(|rev| base_ledger(root, rev)).transpose()?.flatten() {
        Some(base) => check_against_base(&base, &ledger, &files)?,
        None => check_all(&ledger, &files),
    };
    if !report.problems.is_empty() {
        eprintln!("api-compat-check: {} refused wire id change(s):", report.problems.len());
        for (file, problem) in &report.problems {
            eprintln!("  - spec/{file}: {problem}");
        }
    }
    if !report.edits.is_empty() {
        eprintln!(
            "api-compat-check: {} hand edit(s) of spec/{LEDGER_FILE} against the base ledger; --write puts them back:",
            report.edits.len()
        );
        for (file, edit) in &report.edits {
            eprintln!("  - {file}: {edit}");
        }
    }
    if !report.problems.is_empty() {
        eprintln!("{}", wire_help());
        return Ok(None);
    }
    Ok(Some(Wire { path, ledger, report }))
}

/// The ledger file at `rev`, or `None` when `rev` has none yet.
fn base_ledger(root: &Path, rev: &str) -> Result<Option<WireLedgers>, Error> {
    let git = |args: &[&str]| Command::new("git").arg("-C").arg(root).args(args).output();
    let commit = format!("{rev}^{{commit}}");
    if !git(&["rev-parse", "--verify", "--quiet", &commit])?.status.success() {
        return Err(format!("--base {rev} is not a commit in this repository").into());
    }
    let object = format!("{rev}:./spec/{LEDGER_FILE}");
    if !git(&["cat-file", "-e", &object])?.status.success() {
        println!("api-compat-check: {rev} has no spec/{LEDGER_FILE}; checking the ledger as is");
        return Ok(None);
    }
    let shown = git(&["show", &object])?;
    if !shown.status.success() {
        return Err(format!("git show {object}: {}", String::from_utf8_lossy(&shown.stderr)).into());
    }
    let ledger = WireLedgers::from_json(&shown.stdout)
        .map_err(|error| format!("spec/{LEDGER_FILE} at {rev}: {error}"))?;
    Ok(Some(ledger))
}

fn write_pretty(path: &Path, value: &impl serde::Serialize) -> Result<(), Error> {
    let mut bytes = serde_json::to_vec_pretty(value)?;
    bytes.push(b'\n');
    std::fs::write(path, bytes)?;
    Ok(())
}
