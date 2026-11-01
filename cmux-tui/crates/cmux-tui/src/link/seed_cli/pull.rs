//! `cmux link seed pull --socket PATH LOCAL REMOTE [--or-copy | --base-head SHA
//! --base-index SHA --base-work SHA]`: brings a seeded Cloud folder's changes
//! back to this Mac as a diff, never a folder copy (leo-workspace
//! `design/cloud.md`, "Getting the project onto the machine", rule 6; the
//! engine is [`sync_cli::seed_pull`]).
//!
//! The base it merges against is this Mac's [`record`] of the folder: the
//! seed the last `cmux link seed push` sent, or what the last pull brought
//! back. The three `--base-*` flags, all or none, override it. Every pull
//! that brings the folder up to the machine's state keeps the machine's
//! HEAD, INDEX and WORK as the new record, so the next pull and the next
//! `cmux link seed push --since-last` build on it.
//!
//! `--or-copy` is Bring Back Local's pull ([`bring_back`], which `cmux link
//! agent move --sync pull` runs too): a folder with no seed to merge against
//! (no record, a record of a copy or of another machine) is pulled as `cmux
//! link sync pull` pulls a copy, a three-way merge against that copy's own
//! record. Nothing else falls back: a seed pull that fails or conflicts is
//! the answer, and a seeded folder on a machine without
//! `git-seed-export-v1` (checked in its capabilities, whatever its build) is
//! `machine_outdated`, so the app offers Update Machine.
//!
//! Output: one JSON line on stdout, the engine's `{"ok":true,"unchanged",
//! "written","deleted","bytes","bundle_bytes","fast_forwarded","staged",
//! "head","base":{"head","index","work"},"left_out"}` with `"mode":"seed"`
//! (or the copy's own summary with `"mode":"copy"`), exit 0. A conflict is
//! `{"ok":false,"error","error_code":"sync_conflict","conflicts":[paths]}`
//! with nothing changed here; any other failure `{"ok":false,"error",
//! "error_code"}`: `seed.no_previous` when there is no base to merge
//! against, `sync_no_base` when this repository lacks the base's commits,
//! `machine_outdated` for a machine without `fs-v1`, or without
//! `git-seed-export-v1` for a seeded folder. Both exit 1.

use std::path::Path;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::record::{self, Kept, Record};
use super::{SeedError, machine_gate, sync_cli};
use sync_cli::{Back, SeedBase, SeedPulled};

/// What a pull merges against.
pub(super) enum Base {
    /// The `--base-*` flags.
    Given(SeedBase),
    /// This Mac's record; none is `seed.no_previous`.
    Record,
    /// This Mac's record; none (or a machine without the export) pulls the
    /// copy ([`bring_back`]).
    RecordOrCopy,
}

/// The CLI's pull (module docs): its line and exit code.
pub(super) fn run(socket: &Path, local: &Path, remote: &str, base: Base) -> (Value, i32) {
    match pull(socket, local, remote, base) {
        Back::Done(summary) => (summary, 0),
        Back::Conflict(conflicts, reasons) => {
            let mut error = format!(
                "{} changed both here and on the machine; nothing was brought back",
                conflicts.join(", ")
            );
            if !reasons.is_empty() {
                error = format!("{error} ({})", reasons.join("; "));
            }
            let line = json!({ "ok": false, "error": error, "error_code": "sync_conflict",
                               "conflicts": conflicts });
            (line, 1)
        }
        Back::Failed { code, error } => {
            (json!({ "ok": false, "error": error, "error_code": code }), 1)
        }
    }
}

/// Bring Back Local's pull of `remote` into `local`: the seed's diff, or the
/// copy's pull when the folder was not seeded there (module docs).
pub(in crate::link) fn bring_back(socket: &Path, local: &Path, remote: &str) -> Back {
    pull(socket, local, remote, Base::RecordOrCopy)
}

fn pull(socket: &Path, local: &Path, remote: &str, base: Base) -> Back {
    let failed = |error: SeedError| Back::Failed { code: error.code, error: error.message };
    let Some(identity) = machine_gate::identify(socket) else {
        let why = format!("the machine at {} did not answer", socket.display());
        return failed(SeedError::new("sync_failed", why));
    };
    let fs = [cmux_tui_core::fs_ops::FS_CAPABILITY];
    if let Some(outdated) = machine_gate::outdated_identity(&identity, &fs) {
        return failed(SeedError::new(machine_gate::OUTDATED, outdated.message()));
    }
    let or_copy = matches!(base, Base::RecordOrCopy);
    // The capability itself, whatever the machine's build (an `identify`
    // with no list serves none).
    let export = cmux_tui_core::git_seed::GIT_SEED_EXPORT_CAPABILITY;
    let exports = machine_gate::served(&identity).is_some_and(|served| served.contains(&export));
    let outdated = || {
        let build = machine_gate::build_id(&identity).map(str::to_owned);
        let outdated = machine_gate::Outdated { missing: vec![export.to_owned()], build };
        SeedError::new(machine_gate::OUTDATED, outdated.message())
    };
    let machine = identity.get("session_id").and_then(Value::as_str).map(str::to_owned);
    let local_root = match std::fs::canonicalize(local) {
        Ok(path) => path,
        Err(error) => {
            let why = format!("cannot open {}: {error}", local.display());
            return failed(SeedError::new("sync_failed", why));
        }
    };
    let kept = record::load(&local_root, remote);
    let found = match base {
        Base::Given(base) => Ok(base),
        Base::Record | Base::RecordOrCopy => kept
            .as_ref()
            .map_err(|error| SeedError::new("seed.no_previous", format!("{error:#}")))
            .and_then(|kept| base_of(kept.as_ref(), machine.as_deref())),
    };
    let base = match route(found, exports, or_copy) {
        Route::Seed(base) => base,
        Route::Copy => return copy(socket, local, remote),
        Route::Fail(error) => return failed(error),
        Route::Outdated => return failed(outdated()),
    };
    match sync_cli::seed_pull(socket, &local_root, remote, &base) {
        Ok(SeedPulled::Done(mut summary)) => {
            let url = kept.ok().flatten().and_then(|record| record.url);
            keep(&local_root, remote, machine, url, &summary);
            summary.set("mode", json!("seed"));
            Back::Done(summary)
        }
        Ok(SeedPulled::Conflict(conflicts, reasons)) => Back::Conflict(conflicts, reasons),
        Err(error) => Back::Failed {
            code: sync_cli::seed_pull_failure_code(&error),
            error: format!("{error:#}"),
        },
    }
}

/// Which pull runs.
#[derive(Debug)]
enum Route {
    Seed(SeedBase),
    /// `cmux link sync pull`'s, for a folder that was copied.
    Copy,
    Fail(SeedError),
    /// The machine lacks `git-seed-export-v1`: `machine_outdated`, so the
    /// app offers Update Machine.
    Outdated,
}

/// The pull for the base `found`, on a machine that `exports` or not, with
/// `--or-copy` or not. Only a folder with no seed to merge against takes
/// the copy's pull: a seeded folder on a machine without the export has no
/// copy record there either (`sync_no_base`), so it asks for the update.
fn route(found: Result<SeedBase, SeedError>, exports: bool, or_copy: bool) -> Route {
    match found {
        Err(error) if or_copy && error.code == "seed.no_previous" => Route::Copy,
        Err(error) => Route::Fail(error),
        Ok(_) if !exports => Route::Outdated,
        Ok(base) => Route::Seed(base),
    }
}

/// `cmux link sync pull`'s pull of the copy, its summary marked `copy`.
fn copy(socket: &Path, local: &Path, remote: &str) -> Back {
    match sync_cli::pull_into(socket, local, remote) {
        Back::Done(mut summary) => {
            summary.set("mode", json!("copy"));
            Back::Done(summary)
        }
        other => other,
    }
}

/// The base a record gives a pull from the machine `machine`.
fn base_of(kept: Option<&Record>, machine: Option<&str>) -> Result<SeedBase, SeedError> {
    let no_previous = |why: &str| SeedError::new("seed.no_previous", why);
    let Some(kept) = kept else {
        return Err(no_previous(
            "this Mac never seeded this folder to that machine folder (or pass --base-head, \
             --base-index and --base-work)",
        ));
    };
    if let (Some(was), Some(now)) = (kept.machine.as_deref(), machine)
        && was != now
    {
        return Err(no_previous("the last seed of this folder went to another machine"));
    }
    if kept.mode == Kept::Copy {
        return Err(no_previous(
            "the last push of this folder was a copy, not a seed; bring it back with cmux link \
             sync pull",
        ));
    }
    match (&kept.head, &kept.index, &kept.work) {
        (Some(head), Some(index), Some(work)) => {
            Ok(SeedBase { head: head.clone(), index: index.clone(), work: work.clone() })
        }
        _ => Err(no_previous("the last seed's record is incomplete")),
    }
}

/// Keeps the machine's state, the answer's `base`, as this folder's record.
fn keep(local: &Path, remote: &str, machine: Option<String>, url: Option<String>, summary: &Value) {
    let base = summary.get("base");
    let sha =
        |key: &str| base.and_then(|base| base.get(key)).and_then(Value::as_str).map(str::to_owned);
    let (Some(head), Some(index), Some(work)) = (sha("head"), sha("index"), sha("work")) else {
        return;
    };
    let record = Record {
        mode: Kept::Seed,
        machine,
        url,
        head: Some(head),
        index: Some(index),
        work: Some(work),
    };
    // A record that could not be kept only makes the next pull merge from
    // the older base, where what came back already matches both sides.
    let _ = record::save(local, remote, &record);
}

#[cfg(test)]
mod tests {
    use super::{Kept, Record, Route, SeedBase, SeedError, base_of, route};

    #[test]
    fn only_a_folder_with_no_seed_falls_back_to_the_copy() {
        let base = || Ok(SeedBase { head: "h".into(), index: "i".into(), work: "w".into() });
        let none = || Err(SeedError::new("seed.no_previous", "no record"));
        assert!(matches!(route(base(), true, true), Route::Seed(_)));
        assert!(matches!(route(base(), true, false), Route::Seed(_)));
        // A seeded folder on a machine without the export: update it, never the copy.
        assert!(matches!(route(base(), false, true), Route::Outdated));
        assert!(matches!(route(base(), false, false), Route::Outdated));
        // No seed: the copy with --or-copy, whatever the machine serves.
        assert!(matches!(route(none(), false, true), Route::Copy));
        assert!(matches!(route(none(), true, true), Route::Copy));
        assert!(
            matches!(route(none(), true, false), Route::Fail(error) if error.code == "seed.no_previous")
        );
        let other = Err(SeedError::new("sync_failed", "x"));
        assert!(
            matches!(route(other, true, true), Route::Fail(error) if error.code == "sync_failed")
        );
    }

    fn seed(machine: Option<&str>) -> Record {
        Record {
            mode: Kept::Seed,
            machine: machine.map(str::to_owned),
            url: None,
            head: Some("h".into()),
            index: Some("i".into()),
            work: Some("w".into()),
        }
    }

    #[test]
    fn the_record_is_the_base_only_for_a_seed_to_the_same_machine() {
        let base = base_of(Some(&seed(Some("m"))), Some("m")).unwrap();
        assert_eq!((base.head.as_str(), base.index.as_str(), base.work.as_str()), ("h", "i", "w"));
        assert!(base_of(Some(&seed(None)), Some("m")).is_ok(), "an unknown machine");
        for (kept, why) in [
            (None, "no record"),
            (Some(seed(Some("other"))), "another machine"),
            (Some(Record { mode: Kept::Copy, ..seed(Some("m")) }), "a copy"),
            (Some(Record { work: None, ..seed(Some("m")) }), "incomplete"),
        ] {
            let error = base_of(kept.as_ref(), Some("m")).unwrap_err();
            assert_eq!(error.code, "seed.no_previous", "{why}");
        }
    }
}
