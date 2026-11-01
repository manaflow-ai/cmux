//! `cmux link seed pull --socket PATH LOCAL REMOTE [--base-head SHA
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
//! Output: one JSON line on stdout, the engine's `{"ok":true,"unchanged",
//! "written","deleted","bytes","bundle_bytes","fast_forwarded","staged",
//! "head","base":{"head","index","work"},"left_out"}`, exit 0. A conflict is
//! `{"ok":false,"error","error_code":"sync_conflict","conflicts":[paths]}`
//! with nothing changed here; any other failure `{"ok":false,"error",
//! "error_code"}`: `seed.no_previous` when there is no base to merge
//! against, `sync_no_base` when this repository lacks the base's commits,
//! `machine_outdated` for a machine without `fs-v1` and
//! `git-seed-export-v1`. Both exit 1.

use std::path::Path;

use serde_json::{Value, json};

use super::record::{self, Kept, Record};
use super::{SeedError, machine_gate, sync_cli};
use sync_cli::{SeedBase, SeedPulled};

/// What the machine must serve.
const NEEDED: [&str; 2] =
    [cmux_tui_core::fs_ops::FS_CAPABILITY, cmux_tui_core::git_seed::GIT_SEED_EXPORT_CAPABILITY];

/// The pull (module docs): its answer, or the failure line.
pub(super) fn pull(
    socket: &Path,
    local: &Path,
    remote: &str,
    flags: Option<SeedBase>,
) -> Result<Value, Value> {
    let Some(identity) = machine_gate::identify(socket) else {
        let why = format!("the machine at {} did not answer", socket.display());
        return Err(SeedError::new("sync_failed", why).line());
    };
    if let Some(outdated) = machine_gate::outdated_identity(&identity, &NEEDED) {
        return Err(outdated.line());
    }
    let machine = identity.get("session_id").and_then(Value::as_str).map(str::to_owned);
    let local = std::fs::canonicalize(local).map_err(|error| {
        SeedError::new("sync_failed", format!("cannot open {}: {error}", local.display())).line()
    })?;
    let kept = record::load(&local, remote);
    let base = match flags {
        Some(base) => base,
        None => {
            let kept = kept
                .as_ref()
                .map_err(|error| SeedError::new("seed.no_previous", format!("{error:#}")).line())?;
            base_of(kept.as_ref(), machine.as_deref()).map_err(|error| error.line())?
        }
    };
    match sync_cli::seed_pull(socket, &local, remote, &base) {
        Ok(SeedPulled::Done(summary)) => {
            let url = kept.ok().flatten().and_then(|record| record.url);
            keep(&local, remote, machine, url, &summary);
            Ok(summary)
        }
        Ok(SeedPulled::Conflict(conflicts, reasons)) => {
            let mut error = format!(
                "{} changed both here and on the machine; nothing was brought back",
                conflicts.join(", ")
            );
            if !reasons.is_empty() {
                error = format!("{error} ({})", reasons.join("; "));
            }
            Err(json!({ "ok": false, "error": error, "error_code": "sync_conflict",
                        "conflicts": conflicts }))
        }
        Err(error) => Err(json!({ "ok": false, "error": format!("{error:#}"),
                                  "error_code": sync_cli::seed_pull_failure_code(&error) })),
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
    let sha = |key: &str| summary["base"][key].as_str().map(str::to_owned);
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
    use super::{Kept, Record, base_of};

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
