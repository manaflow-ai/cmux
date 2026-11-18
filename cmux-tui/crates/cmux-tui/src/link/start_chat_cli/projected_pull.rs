//! `cmux link start-chat project-pull --mount ID [--socket PATH] [--dry-run]`: brings what the
//! machine changed in a projected folder back to this Mac (`sync_cli::back`, which holds the
//! rules). It loads the mount's record and manifest copy from `projected/<mount>/`, and keeps
//! what each pull settled in `pulled.json` beside them (written whole, renamed into place), so a
//! second pull applies only what changed on the machine since.
//!
//! It prints one JSON line: `{"ok":true,"mount","dry_run","applied","created","deleted",
//! "unchanged","conflicts":[{"path","kept","beside"}],"refused":[{"path","reason"}],
//! "skipped_git","bytes","ms":{"upper","apply","total"}}`, or `{"ok":false,"code","message"}`
//! with exit 1. `--dry-run` decides the same and changes nothing (no file is read from the
//! machine; a conflict names the first free name it would take).

use std::path::{Path, PathBuf};

use cmux_projfs::Manifest;
use serde_json::{Value, json};

use super::super::super::sync_cli::back::{self, Back, Ledger};
use super::super::Flags;
use super::super::projected_serve::plain_id;
use super::{MANIFEST, RECORD, Record, write_private};

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
    let mut ledger = match std::fs::read(dir.join(PULLED)) {
        Ok(bytes) => match serde_json::from_slice::<Ledger>(&bytes) {
            Ok(ledger) => ledger,
            Err(error) => return failed("ledger_unreadable", format!("{PULLED}: {error}")),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ledger::default(),
        Err(error) => return failed("ledger_unreadable", format!("{PULLED}: {error}")),
    };
    let root = PathBuf::from(&record.local_root);
    let pull = Back {
        root: &root,
        machine_folder: &record.folder,
        state_dir: &record.state_dir,
        manifest: &manifest,
        dry_run,
    };
    let socket = socket.unwrap_or_else(|| PathBuf::from(&record.socket));
    let before = ledger.clone();
    let result = back::pull(&pull, &socket, &mut ledger);
    // What was applied is kept, also when the pull stopped partway.
    if !dry_run && ledger != before {
        ledger.version = 1;
        let saved = serde_json::to_vec(&ledger)
            .map_err(std::io::Error::other)
            .and_then(|bytes| write_private(&dir.join(PULLED), &bytes));
        if let Err(error) = saved {
            return failed("ledger_unwritable", format!("{PULLED}: {error}"));
        }
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
