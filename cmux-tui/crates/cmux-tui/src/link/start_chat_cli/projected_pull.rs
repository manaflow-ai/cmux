//! `cmux link start-chat project-pull --mount ID [--socket PATH] [--dry-run]`: brings what the
//! machine changed in a projected folder back to this Mac (`sync_cli::back`, which holds the
//! rules). It loads the mount's record and manifest copy from `projected/<mount>/`, and keeps
//! what each pull settled in `pulled.json` beside them, each path journaled the moment it is
//! settled ([`ledger`]), so a second pull applies only what changed on the machine since, also
//! after one that was killed partway. One pull of a mount runs at a time: it holds `pull.lock`
//! there from start to end, and another answers `busy` without changing anything.
//!
//! It prints one JSON line: `{"ok":true,"mount","dry_run","applied","created","deleted",
//! "unchanged","conflicts":[{"path","kept","beside"}],"refused":[{"path","reason"}],
//! "skipped_git","bytes","ms":{"upper","apply","total"}}`, or `{"ok":false,"code","message"}`
//! with exit 1. `--dry-run` decides the same and changes nothing (no file is read from the
//! machine; a conflict names the first free name it would take).

use std::path::{Path, PathBuf};

use cmux_projfs::Manifest;
use serde_json::{Value, json};

use super::super::super::sync_cli::back::{self, Back, Pulled};
use super::super::Flags;
use super::super::projected_serve::plain_id;
use super::{MANIFEST, RECORD, Record};

#[path = "projected_pull_ledger.rs"]
mod ledger;

/// The name of a mount's ledger of what pulls brought back.
pub(super) const PULLED: &str = "pulled.json";

fn failed(code: &str, message: impl std::fmt::Display) -> Value {
    json!({ "ok": false, "code": code, "message": message.to_string() })
}

/// `project-pull`; `None` on bad usage.
pub(super) fn cli(flags: &Flags, base: &Path) -> Option<Value> {
    let mount = flags.one("--mount").filter(|id| plain_id(id))?;
    let socket = match flags.all("--socket").as_slice() {
        [] => None,
        [socket] => Some(PathBuf::from(socket)),
        _ => return None,
    };
    let dry_run = match flags.all("--dry-run").as_slice() {
        [] => false,
        [_] => true,
        _ => return None,
    };
    Some(run(&base.join(mount), socket, dry_run))
}

/// One pull of the mount kept in `dir`.
pub(super) fn run(dir: &Path, socket: Option<PathBuf>, dry_run: bool) -> Value {
    run_until(dir, socket, dry_run, None)
}

/// One pull, stopped before the item after `stop_after` items when it is given (code
/// `stopped`, the journal as a kill there would leave it).
fn run_until(dir: &Path, socket: Option<PathBuf>, dry_run: bool, stop_after: Option<u64>) -> Value {
    let missing = |what: &str| {
        let message = format!("no projected folder is kept at {} ({what})", dir.display());
        failed("record_missing", message)
    };
    let Ok(record) = std::fs::read(dir.join(RECORD)) else { return missing("no record") };
    let Ok(record) = serde_json::from_slice::<Record>(&record) else {
        return missing("its record is unreadable");
    };
    let Ok(bytes) = std::fs::read(dir.join(MANIFEST)) else { return missing("no manifest") };
    let Ok(manifest) = Manifest::decode(&bytes) else {
        return missing("its manifest is unreadable");
    };
    let _held = match ledger::lock(dir) {
        Ok(held) => held,
        Err(ledger::Busy::Held) => {
            return failed("busy", "another pull of this projected folder is running");
        }
        Err(ledger::Busy::Io(error)) => return failed("pull_failed", format!("the lock: {error}")),
    };
    let mut ledger = match ledger::load(dir) {
        Ok(ledger) => ledger,
        Err(message) => return failed("ledger_unreadable", message),
    };
    let unwritable =
        |error: std::io::Error| failed("ledger_unwritable", format!("{PULLED}: {error}"));
    // What an earlier pull left in the journal goes into the snapshot first, so this pull's
    // lines start an empty journal.
    if !dry_run
        && ledger::has_journal(dir)
        && let Err(error) = ledger::save(dir, &ledger)
    {
        return unwritable(error);
    }
    let mut journal = if dry_run {
        None
    } else {
        match ledger::Journal::open(dir) {
            Ok(journal) => Some(journal),
            Err(error) => return unwritable(error),
        }
    };
    let mut keep = |path: &str, pulled: &Pulled| match journal.as_mut() {
        Some(journal) => journal.add(path, pulled),
        None => Ok(()),
    };
    let root = PathBuf::from(&record.local_root);
    let pull = Back {
        root: &root,
        machine_folder: &record.folder,
        state_dir: &record.state_dir,
        manifest: &manifest,
        dry_run,
        stop_after,
    };
    let socket = socket.unwrap_or_else(|| PathBuf::from(&record.socket));
    let before = ledger.clone();
    let result = back::pull(&pull, &socket, &mut ledger, &mut keep);
    if let Err(failure) = &result
        && failure.code == "stopped"
    {
        // Stopped as a kill would stop it: the journal holds what it settled.
        return failed(&failure.code, &failure.message);
    }
    // What was applied is kept, also when the pull stopped partway.
    if !dry_run
        && (ledger != before || ledger::has_journal(dir))
        && let Err(error) = ledger::save(dir, &ledger)
    {
        return unwritable(error);
    }
    match result {
        Ok(mut summary) => {
            summary["mount"] = json!(record.mount);
            summary
        }
        Err(failure) => failed(&failure.code, failure.message),
    }
}

#[cfg(test)]
#[path = "projected_pull_tests.rs"]
mod tests;
