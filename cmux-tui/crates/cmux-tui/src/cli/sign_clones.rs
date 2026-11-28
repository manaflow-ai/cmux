//! `cmux sign-clones sweep [--dry-run] [--json]`: one full pass now over the
//! Chromium code-sign clones that cmux apps left in this user's temp folder
//! (cmux-sign-clone-sweep; the app runs the same pass, bounded, at idle).
//!
//! Each clone is one row: what the pass did (`removed`, `would-remove`,
//! `in-use`, `unknown`, `foreign`, `too-new`, `remove-failed`), its bytes (the
//! blocks of its entries with no other name), the bundle id its cloned
//! `Info.plist` names, its path, and the owner's liveness with the evidence
//! (the open executable that keeps it, or why it may go: `superseded` when an
//! update replaced its build, else `leftover`). `--dry-run` removes nothing
//! and counts the same bytes the real pass would. Clones made in the last
//! `MIN_AGE` (10 minutes) are kept: an instance that is starting may not have
//! started a helper from its clone yet. A folder that cannot be read is an
//! `unknown` row, never taken for an empty one.
//!
//! Exit codes: 0 done, 1 a clone could not be removed or the temp folder could
//! not be read, 2 usage.

use std::path::Path;

use cmux_sign_clone_sweep::{Report, Row, Verdict};
use serde_json::{Value, json};

use super::OutputMode;

const USAGE: &str = "usage: cmux sign-clones sweep [--dry-run] [--json]\n\n  Removes the copies of cmux apps that the built-in browser leaves in your temp folder\n  (its code-sign clones), once nothing runs from them. Every cmux app (release, NIGHTLY,\n  dev builds) is covered; other apps' clones are never touched. Copies made in the\n  last 10 minutes are kept.\n  --dry-run: list each clone, whether its app still runs from it and why, and its\n             bytes; remove nothing.\n  --json:    print the rows and totals as JSON.";

/// `cmux [global options] sign-clones ...`; `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (scope, rest) = command_args.split_first()?;
    if scope != "sign-clones" {
        return None;
    }
    let mut output = global.output;
    let mut dry_run = false;
    let mut verb = None;
    for word in rest {
        match word.as_str() {
            "-h" | "--help" => {
                println!("{USAGE}");
                return Some(0);
            }
            "--json" => output = OutputMode::Json,
            "--dry-run" => dry_run = true,
            "sweep" if verb.is_none() => verb = Some(()),
            _ => return Some(super::app::failure("usage.invalid", USAGE, output, 2)),
        }
    }
    if verb.is_none() {
        println!("{USAGE}");
        return Some(if rest.is_empty() { 0 } else { 2 });
    }
    Some(sweep(output, dry_run))
}

#[cfg(target_os = "macos")]
fn sweep(output: OutputMode, dry_run: bool) -> i32 {
    let now = std::time::SystemTime::now();
    let started = cmux_sign_clone_sweep::cutoff(now, now);
    let unlimited = cmux_sign_clone_sweep::Budget::UNLIMITED;
    let Some((rows, report)) = cmux_sign_clone_sweep::host::run_pass(started, unlimited, dry_run)
    else {
        let message = "cmux: could not find your temp folder, so no copies were checked";
        return super::app::failure("sign_clones.no_temp_dir", message, output, 1);
    };
    print_pass(output, dry_run, cmux_sign_clone_sweep::host::x_dir().as_deref(), &rows, &report)
}

#[cfg(not(target_os = "macos"))]
fn sweep(output: OutputMode, dry_run: bool) -> i32 {
    print_pass(output, dry_run, None, &[], &Report::default())
}

/// The bundle id a row names: its `Info.plist`'s, which for every row but a
/// foreign one is its root's id.
fn bundle_id(row: &Row) -> Option<&str> {
    match &row.verdict {
        Verdict::Foreign { found } => found.as_deref(),
        _ => Some(row.root_id.as_str()),
    }
}

fn reason(row: &Row) -> Option<&'static str> {
    match &row.verdict {
        Verdict::Removed { reason, .. } => Some(reason.as_str()),
        _ => None,
    }
}

/// Bytes as a person reads them: `812.4 MB`.
fn size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit + 1 < UNITS.len() {
        value /= 1000.0;
        unit += 1;
    }
    let name = UNITS.get(unit).copied().unwrap_or("B");
    if unit == 0 { format!("{bytes} B") } else { format!("{value:.1} {name}") }
}

fn row_json(row: &Row) -> Value {
    json!({
        "path": row.path,
        "bundle_id": bundle_id(row),
        "verdict": row.verdict.word(),
        "reason": reason(row),
        "evidence": row.verdict.evidence(),
        "reclaimable_bytes": row.reclaimable_bytes,
    })
}

fn totals_json(report: &Report) -> Value {
    json!({
        "removed": report.removed,
        "removed_superseded": report.removed_superseded,
        "kept_in_use": report.kept_in_use,
        "kept_foreign": report.kept_foreign,
        "reclaimed_bytes": report.reclaimed_bytes,
        "free_space_delta_bytes": report.free_space_delta_bytes,
    })
}

/// Prints the rows and the totals; 1 when a clone could not be removed.
fn print_pass(
    output: OutputMode,
    dry_run: bool,
    x: Option<&Path>,
    rows: &[Row],
    report: &Report,
) -> i32 {
    let failed = rows.iter().any(|row| matches!(row.verdict, Verdict::RemoveFailed { .. }));
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            let clones: Vec<Value> = rows.iter().map(row_json).collect();
            let body = json!({
                "dry_run": dry_run,
                "folder": x,
                "clones": clones,
                "total": totals_json(report),
            });
            println!("{body}");
        }
        OutputMode::Quiet => {}
        OutputMode::Human => {
            for row in rows {
                println!(
                    "{:<13} {:>9}  {}  {}  ({})",
                    row.verdict.word(),
                    size(row.reclaimable_bytes),
                    bundle_id(row).unwrap_or("-"),
                    row.path.display(),
                    row.verdict.evidence(),
                );
            }
            let verb = if dry_run { "would remove" } else { "removed" };
            println!(
                "total: {verb} {} clone(s) ({} superseded), {}; kept {} in use, {} foreign{}",
                report.removed,
                report.removed_superseded,
                size(report.reclaimed_bytes),
                report.kept_in_use,
                report.kept_foreign,
                if dry_run || report.removed == 0 {
                    String::new()
                } else {
                    format!("; free space {:+} bytes", report.free_space_delta_bytes)
                },
            );
        }
    }
    i32::from(failed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_sign_clone_sweep::Reason;
    use std::path::PathBuf;

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().copied().map(str::to_owned).collect()
    }

    #[test]
    fn sign_clones_claims_only_its_command() {
        assert_eq!(run_if_requested(&args(&["status"])), None);
        assert_eq!(run_if_requested(&args(&["sign-clones", "--help"])), Some(0));
        assert_eq!(run_if_requested(&args(&["sign-clones", "sweep", "--bogus"])), Some(2));
    }

    #[test]
    fn sign_clones_rows_name_the_bundle_reason_and_evidence() {
        let removed = Row {
            path: PathBuf::from("/x/a.code_sign_clone/code_sign_clone.abcdef"),
            root_id: "com.cmuxterm.app.nightly".into(),
            verdict: Verdict::Removed { reason: Reason::Superseded, dry_run: true },
            reclaimable_bytes: 812_400_000,
        };
        let row = row_json(&removed);
        assert_eq!(row.get("verdict"), Some(&json!("would-remove")));
        assert_eq!(row.get("reason"), Some(&json!("superseded")));
        assert_eq!(row.get("bundle_id"), Some(&json!("com.cmuxterm.app.nightly")));
        assert_eq!(row.get("reclaimable_bytes"), Some(&json!(812_400_000u64)));
        let foreign = Row {
            verdict: Verdict::Foreign { found: Some("org.example.Browser".into()) },
            ..removed
        };
        assert_eq!(bundle_id(&foreign), Some("org.example.Browser"));
        assert_eq!(size(812_400_000), "812.4 MB");
        assert_eq!(size(512), "512 B");
    }
}
