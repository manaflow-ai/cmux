//! The file a swap replaced (`.pre-output-cleanup`): how long it stays, the
//! full starts counted on the new registry, and the way back to it (a
//! rollback when the new registry does not open or the owner does not start
//! on it, and the restore of a swap that a crash interrupted).

use std::fs;
use std::path::Path;
use std::time::Duration;

use anyhow::Context as _;
use rusqlite::{OpenFlags, OptionalExtension as _};

use super::super::open_guard::sidecar_path;
use super::super::{open_registry_database_read_only, open_registry_database_with_flags};
use super::{
    DONE_META_KEY, previous_path, remove_if_present, rollback_pending_path, write_failure_marker,
};
use crate::platform;

/// Meta key: full owner starts since the swap. The previous file is removed
/// at an open once one start after the swap got through restore.
pub(super) const FULL_STARTS_META_KEY: &str = "output_cleanup_full_starts";

/// The swapped-in registry did not open: put the previous file back and
/// never stage this registry again (the failure marker). When the previous
/// file cannot be put back (the swapped file still held open: a syncer
/// thread of the failed open, a sharing violation on Windows), the start is
/// refused, and the next start finishes the rollback before anything opens
/// the registry ([`finish_pending_rollback`]).
pub(crate) fn roll_back_swap(db_path: &Path, error: &anyhow::Error) -> anyhow::Result<()> {
    eprintln!(
        "cmux-tui: output cleanup: the new registry did not open ({error:#}); \
         restoring the previous registry"
    );
    write_failure_marker(db_path, &format!("the new registry did not serve: {error:#}"));
    // On disk before the rename, so a crash or a failed rename leaves the
    // next start a record to finish. A marker that cannot be written (a
    // full disk) does not stop the rename: the failure marker and an
    // unconfirmed swap are the fallback record.
    let pending = rollback_pending_path(db_path);
    if let Err(marker_error) = write_synced(&pending, &format!("{error:#}\n")) {
        eprintln!(
            "cmux-tui: output cleanup: could not record the rollback in {}: {marker_error:#}",
            pending.display()
        );
    }
    // A sidecar left behind belongs to the cleaned file's pages: the next
    // open would apply its WAL frames to the previous registry. One that
    // cannot go (held open without delete sharing on Windows) refuses the
    // start like a failed rename, and the next start tries again.
    for suffix in ["-wal", "-shm", "-journal"] {
        remove_if_present(&sidecar_path(db_path, suffix)).context(
            "clear the cleaned registry's sidecar before putting the previous registry back; \
             the next start tries again",
        )?;
    }
    let restored = fs::rename(previous_path(db_path), db_path);
    if let Some(parent) = db_path.parent() {
        let _ = platform::sync_directory(parent);
    }
    restored.with_context(|| {
        format!(
            "put the previous workspace registry {} back after a failed output cleanup; the \
             next start tries again",
            previous_path(db_path).display()
        )
    })?;
    remove_if_present(&pending)?;
    Ok(())
}

/// Writes `contents` to `path` and syncs the file and its directory.
fn write_synced(path: &Path, contents: &str) -> anyhow::Result<()> {
    use std::io::Write as _;
    let mut file = fs::File::create(path)?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()?;
    if let Some(parent) = path.parent() {
        platform::sync_directory(parent)?;
    }
    Ok(())
}

/// Finishes a rollback an earlier start could not complete: called before
/// anything opens the registry. The record is the rollback marker, or, when
/// that could not be written, the failure marker beside a swap no full start
/// confirmed (only a rollback writes the failure marker after a swap).
pub(crate) fn finish_pending_rollback(db_path: &Path) -> anyhow::Result<()> {
    let pending = rollback_pending_path(db_path);
    let unrecorded_rollback =
        || super::failed_path(db_path).is_file() && rollback_possible(db_path);
    if !(pending.is_file() || unrecorded_rollback()) {
        return Ok(());
    }
    if !previous_path(db_path).is_file() {
        // Already put back (the marker's removal did not happen).
        return remove_if_present(&pending);
    }
    roll_back_swap(db_path, &anyhow::anyhow!("an earlier rollback could not finish"))
}

/// Refuses an open while the registry exists only as the backup of a swap
/// (the restore of an interrupted swap failed). The error names the backup.
pub(crate) fn refuse_open_beside_backup(db_path: &Path) -> anyhow::Result<()> {
    let previous = previous_path(db_path);
    anyhow::ensure!(
        !rollback_pending_path(db_path).is_file(),
        "an output cleanup rollback of the workspace registry is unfinished; the previous \
         registry {} could not be put back in place (see the log above). Move it to {} by hand \
         to start this session",
        previous.display(),
        db_path.display()
    );
    anyhow::ensure!(
        db_path.exists() || !previous.is_file(),
        "the workspace registry exists only as the output cleanup backup {}; it could not be \
         put back in place (see the log above). Move it to {} by hand to start this session",
        previous.display(),
        db_path.display()
    );
    Ok(())
}

/// The registry at `db_path` is the one a swap made from the backup: same
/// registry id, and the swap's completion record. A registry created in its
/// place (another id, or no record) never lets the backup be removed or
/// counts a start for it.
fn is_swapped_registry(db_path: &Path) -> bool {
    swapped_registry(db_path).unwrap_or_else(|error| {
        eprintln!(
            "cmux-tui: output cleanup: could not tell whether the registry was swapped: {error:#}"
        );
        false
    })
}

/// [`is_swapped_registry`] that reports a file it could not read instead of
/// answering "not swapped": a locked or unreadable backup is not evidence that
/// the registry is another one. A missing key reads as absent.
fn swapped_registry(db_path: &Path) -> anyhow::Result<bool> {
    let read = |path: &Path, key: &str| -> anyhow::Result<Option<String>> {
        let connection = open_registry_database_read_only(path)
            .with_context(|| format!("open {} to read {key}", path.display()))?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection
            .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| {
                row.get::<_, String>(0)
            })
            .optional()
            .with_context(|| format!("read {key} from {}", path.display()))
    };
    let Some(current) = read(db_path, "registry_id")? else { return Ok(false) };
    if read(&previous_path(db_path), "registry_id")?.as_deref() != Some(current.as_str()) {
        return Ok(false);
    }
    // A swap writes what it kept. The version 1 cleanup wrote only the
    // version 1 key, and version 2 may later mark that registry `not-needed`
    // (#39381 review): its swap is still the version 1 one.
    let swapped = |value: Option<String>| value.is_some_and(|value| value.contains("\"kept\""));
    Ok(swapped(read(db_path, DONE_META_KEY)?) || swapped(read(db_path, super::V1_DONE_META_KEY)?))
}

/// A previous registry exists and no owner got through a full start on the
/// registry that replaced it: a failed owner build may still roll back.
pub(crate) fn rollback_possible(db_path: &Path) -> bool {
    if !previous_path(db_path).is_file() || !db_path.is_file() || !is_swapped_registry(db_path) {
        return false;
    }
    open_registry_database_read_only(db_path)
        .ok()
        .map(|connection| {
            connection
                .query_row("SELECT value FROM meta WHERE key = ?1", [FULL_STARTS_META_KEY], |row| {
                    row.get::<_, String>(0)
                })
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(0)
                == 0
        })
        .unwrap_or(false)
}

/// Records a full owner start (restore done) on a registry that still has
/// the file a swap replaced.
pub(crate) fn note_full_start(db_path: &Path) -> anyhow::Result<()> {
    if !previous_path(db_path).exists() {
        return Ok(());
    }
    // A backup that cannot be read (held by another process, unreadable) is
    // not proof the registry is another one: answering "not swapped" would
    // let this start serve without its confirmation, and a later failed start
    // could roll back over what it served. Once more after a failure, then
    // the start is refused.
    let swapped =
        swapped_registry(db_path).or_else(|_| swapped_registry(db_path)).with_context(|| {
            format!(
                "check whether the registry was made from the output cleanup backup {} (the \
                 start is refused; the next start tries again)",
                previous_path(db_path).display()
            )
        })?;
    if !swapped {
        eprintln!(
            "cmux-tui: output cleanup: the registry is not the one made from {}; it stays",
            previous_path(db_path).display()
        );
        return Ok(());
    }
    let note = || -> anyhow::Result<()> {
        let connection = open_registry_database_with_flags(
            db_path,
            OpenFlags::default().difference(OpenFlags::SQLITE_OPEN_CREATE),
        )?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute(
            "INSERT INTO meta(key, value) VALUES(?1, '1')
             ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1",
            [FULL_STARTS_META_KEY],
        )?;
        Ok(())
    };
    // Once more after a failure (a busy registry). A start that cannot
    // record itself is not a full start: the caller refuses it before it
    // serves, so a later failed start can never roll back a served session.
    note().or_else(|_| note()).context(
        "record the first full start on the output-cleaned registry (the start is refused; \
         the next start tries again)",
    )
}

/// At an open after a swap: the previous file goes, off the start path, once
/// an owner got through a full start on the new registry. Until then it stays
/// so the original can be put back.
pub(crate) fn remove_previous_registry_when_started(db_path: &Path) {
    let previous = previous_path(db_path);
    if !previous.exists() {
        // Sidecars an older build left without their backup.
        for suffix in ["-wal", "-shm", "-journal"] {
            let _ = remove_if_present(&sidecar_path(&previous, suffix));
        }
        return;
    }
    if !is_swapped_registry(db_path) {
        eprintln!(
            "cmux-tui: output cleanup: kept {}: the registry is not the one made from it",
            previous.display()
        );
        return;
    }
    let started = open_registry_database_read_only(db_path)
        .ok()
        .and_then(|connection| {
            connection
                .query_row("SELECT value FROM meta WHERE key = ?1", [FULL_STARTS_META_KEY], |row| {
                    row.get::<_, String>(0)
                })
                .ok()
        })
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(0);
    if started == 0 {
        return;
    }
    let _ =
        std::thread::Builder::new().name("cmux-output-cleanup-remove".into()).spawn(move || {
            match remove_previous_with_sidecars(&previous) {
                Ok(()) => eprintln!(
                    "cmux-tui: output cleanup: removed the previous registry {}",
                    previous.display()
                ),
                Err(error) => eprintln!(
                    "cmux-tui: output cleanup: could not remove {}: {error:#}",
                    previous.display()
                ),
            }
        });
}

/// Removes the previous registry, then the sidecars SQLite left beside it
/// (`-wal`, `-shm`, `-journal`: a read-only open of a WAL file makes them).
/// The sidecars go after the main file, so a crash between the two never
/// leaves a WAL beside a file it could be applied to. From Lawrence Chen's
/// long-jobs branch (6825f3658ff, d66f49b98f6).
fn remove_previous_with_sidecars(previous: &Path) -> anyhow::Result<()> {
    remove_if_present(previous)?;
    for suffix in ["-wal", "-shm", "-journal"] {
        remove_if_present(&sidecar_path(previous, suffix))?;
    }
    Ok(())
}

/// Without hard links the swap renames the registry aside first; a crash
/// between the two renames leaves only the previous file.
pub(crate) fn restore_interrupted_swap(db_path: &Path) {
    let previous = previous_path(db_path);
    if db_path.exists() || !previous.is_file() {
        return;
    }
    // Sidecars without their main file belong to a file that is gone; an old
    // WAL must never be applied to the backup. They are moved aside, not
    // deleted.
    let orphaned = super::super::open_guard::orphaned_sidecars(db_path);
    let shm = sidecar_path(db_path, "-shm");
    if !orphaned.is_empty() || shm.exists() {
        match super::super::open_guard::quarantine(
            db_path,
            "sidecars of a missing registry before an interrupted swap was undone",
        ) {
            Ok(kept) => eprintln!(
                "cmux-tui: output cleanup: moved stale sidecars to {}",
                kept.recovery_dir.display()
            ),
            Err(error) => {
                eprintln!(
                    "cmux-tui: output cleanup: could not move stale sidecars aside, \
                     the backup stays at {}: {error:#}",
                    previous.display()
                );
                return;
            }
        }
    }
    match fs::rename(&previous, db_path) {
        Ok(()) => {
            eprintln!("cmux-tui: output cleanup: restored the registry after an interrupted swap");
        }
        Err(error) => {
            eprintln!(
                "cmux-tui: output cleanup: could not restore {}: {error}",
                previous.display()
            );
        }
    }
}

#[cfg(test)]
#[path = "swap_rollback_tests.rs"]
mod rollback_tests;
