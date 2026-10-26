//! CI guard: fails when the daemon protocol changed in a way that can break
//! an older or newer peer and no compat rule covers it.
//!
//! Two checks run on every invocation:
//!
//! - JSON shape: the flattened `spec/sdk-schema.json` surface against
//!   `spec/api-compat.surface.json` and the revision rules.
//! - Wire ids: the families, `method_id`/`event_id`, priorities and binary
//!   layouts of `spec/sdk-schema.json` and `spec/resource-operations-v2.json`
//!   against the append-only ledger `spec/api-compat.wire.json`.
//!
//! Run from `cmux-tui/`:
//!
//! ```text
//! cargo run -p cmux-api-compat --bin api-compat-check --locked            # check
//! cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write # refresh the snapshot and ledger
//! ```
//!
//! `--write` refuses while a breaking change lacks a rule or a wire rule
//! refuses a change.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use cmux_api_compat::Schema;
use cmux_api_compat::coverage::{Snapshot, Verdict, check, surface_from_sdk_schema};
use cmux_api_compat::fixtures::{Fixtures, check_fixtures};
use cmux_api_compat::wire::{
    RESOURCE_OPERATIONS, SDK_SCHEMA, WireLedgers, check_all, ids_from_resource_operations,
    ids_from_sdk_schema,
};

const HELP: &str = "\
How to fix: add a revision to spec/api-compat.json with one rule per break
(rename, move, add, remove, retype, rename_value, fill; paths are JSON pointers
on the message line, results sit under /data). Then run
  cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write";

const WIRE_HELP: &str = "\
Wire ids are append-only: never reuse or renumber a method_id, event_id or
family byte. To remove a name, keep its entry in spec/api-compat.wire.json
and add \"removed\": \"<why>\" to it. A priority change needs a
new `priority_changed_reason` beside the priority; a binary layout change needs
a higher `layout_version`.";

const WRITE_HINT: &str =
    "  cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write";

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

fn read_json(path: &Path) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    Ok(serde_json::from_slice(&std::fs::read(path)?)?)
}

fn run(root: &Path, write: bool) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let spec = root.join("spec");
    let sdk = read_json(&spec.join(SDK_SCHEMA))?;
    let operations = read_json(&spec.join(RESOURCE_OPERATIONS))?;
    let compat = Schema::from_json(&std::fs::read(spec.join("api-compat.json"))?)?;
    let ledger_path = spec.join("api-compat.wire.json");
    let recorded = WireLedgers::from_json(&std::fs::read(&ledger_path)?)?;
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

    let files = BTreeMap::from([
        (SDK_SCHEMA.to_owned(), ids_from_sdk_schema(&sdk)?),
        (RESOURCE_OPERATIONS.to_owned(), ids_from_resource_operations(&operations)?),
    ]);
    let wire = check_all(&recorded, &files);
    if !wire.problems.is_empty() {
        eprintln!("api-compat-check: {} refused wire id change(s):", wire.problems.len());
        for (file, problem) in &wire.problems {
            eprintln!("  - spec/{file}: {problem}");
        }
        eprintln!("{WIRE_HELP}");
        return Ok(ExitCode::FAILURE);
    }

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
    let stale_ledger = wire.is_stale(&recorded);
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
                "api-compat-check: the schema files give out wire ids, priorities or layouts spec/api-compat.wire.json does not record yet."
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
        write_pretty(&ledger_path, &wire.ledgers)?;
        println!("api-compat-check: spec/api-compat.wire.json refreshed");
    }
    Ok(ExitCode::SUCCESS)
}

fn write_pretty(
    path: &Path,
    value: &impl serde::Serialize,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut bytes = serde_json::to_vec_pretty(value)?;
    bytes.push(b'\n');
    std::fs::write(path, bytes)?;
    Ok(())
}
