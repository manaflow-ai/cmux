//! The file a swap replaced: how long it stays, the full starts counted on
//! the new registry, and the way back to it (a rollback when the new registry
//! does not open or the owner does not start on it, and the restore of a
//! swap that a crash interrupted).
//!
//! The file has two names, one after the other:
//!
//! - `.pre-output-cleanup` from the swap until one owner got through a full
//!   start on the new registry. Only under this name is it put back by a
//!   start (the rollback, the restore of an interrupted swap).
//! - `.kept-before-cleanup` from the next open. No start reads it or puts it
//!   back: a person does, with the daemon stopped. It goes at an open once
//!   [`BACKUP_KEEP`] passed since the swap AND [`BACKUP_KEEP_FULL_STARTS`]
//!   full starts were counted. The swap rewrites a person's only registry
//!   and cannot be undone, so the way back is long; the cost is the disk:
//!   the old file's size stays for that time.
//!
//! The second name is not for style. An older build removes
//! `.pre-output-cleanup` at its first open after one full start, so that
//! name does not live through a return to an older build; and a start that
//! finds no registry takes `.pre-output-cleanup` for an interrupted swap and
//! serves it, which a week-old file must never be.
//!
//! While either file is beside the registry no rebuild starts
//! ([`backup_held`]): its swap would replace the kept file with a newer and
//! smaller one. Journal retention deletes in place in that time. A kept file
//! that is not of this registry (the registry was made again in its place)
//! never goes by itself, so it holds the rebuild off for good; each open
//! says so in the log, and `server-stats` shows the file ([`held_backup`]).

use std::fs;
use std::path::Path;
use std::time::Duration;

use anyhow::Context as _;
use rusqlite::{OpenFlags, OptionalExtension as _};

use super::super::open_guard::sidecar_path;
use super::super::session_journal::unix_epoch_ms;
use super::super::{open_registry_database_read_only, open_registry_database_with_flags};
use super::{
    DONE_META_KEY, V1_DONE_META_KEY, kept_path, previous_path, remove_if_present,
    rollback_pending_path, write_failure_marker,
};
use crate::platform;

/// Meta key: full owner starts since the swap. One ends the rollback window;
/// [`BACKUP_KEEP_FULL_STARTS`] of them are one of the two conditions for the
/// kept file to go.
pub(super) const FULL_STARTS_META_KEY: &str = "output_cleanup_full_starts";

/// The file a swap replaced stays at least this long after the swap.
const BACKUP_KEEP: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// The file a swap replaced stays through at least this many full owner
/// starts on the new registry.
const BACKUP_KEEP_FULL_STARTS: u64 = 3;

#[cfg(test)]
thread_local! {
    /// The clock of the backup rule for a test on this thread, in
    /// milliseconds since the Unix epoch.
    pub(super) static NOW_MS_FOR_TEST: std::cell::Cell<Option<u64>> =
        const { std::cell::Cell::new(None) };
}

/// The clock of the backup rule. A clock that cannot be read is time 0: the
/// file stays.
fn now_ms() -> u64 {
    #[cfg(test)]
    if let Some(now) = NOW_MS_FOR_TEST.with(std::cell::Cell::get) {
        return now;
    }
    let now = unix_epoch_ms().unwrap_or(0);
    // A real owner in a test: its clock is this much ahead.
    #[cfg(debug_assertions)]
    if let Some(ahead) = std::env::var("CMUX_TUI_TEST_OUTPUT_CLEANUP_CLOCK_AHEAD_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return now.saturating_add(ahead);
    }
    now
}

/// The rule for the kept file: both the time and the count. A clock behind
/// the swap (set back) keeps the file.
fn backup_due(now_ms: u64, swapped_at_ms: u64, full_starts: u64) -> bool {
    let keep_ms = u64::try_from(BACKUP_KEEP.as_millis()).unwrap_or(u64::MAX);
    full_starts >= BACKUP_KEEP_FULL_STARTS && now_ms.saturating_sub(swapped_at_ms) >= keep_ms
}

/// True while a file that a swap replaced is beside the registry, under
/// either name. The cleanup worker starts no rebuild then.
pub(crate) fn backup_held(db_path: &Path) -> bool {
    previous_path(db_path).exists() || kept_path(db_path).exists()
}

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
fn is_swapped_registry(db_path: &Path, backup: &Path) -> bool {
    swapped_registry(db_path, backup).unwrap_or_else(|error| {
        eprintln!(
            "cmux-tui: output cleanup: could not tell whether the registry was swapped: {error:#}"
        );
        false
    })
}

/// [`is_swapped_registry`] that reports a file it could not read instead of
/// answering "not swapped": a locked or unreadable backup is not evidence that
/// the registry is another one. A missing key reads as absent.
fn swapped_registry(db_path: &Path, backup: &Path) -> anyhow::Result<bool> {
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
    if read(backup, "registry_id")?.as_deref() != Some(current.as_str()) {
        return Ok(false);
    }
    // A swap writes what it kept. The version 1 cleanup wrote only the
    // version 1 key, and version 2 may later mark that registry `not-needed`
    // (#39381 review): its swap is still the version 1 one.
    let swapped = |value: Option<String>| value.is_some_and(|value| value.contains("\"kept\""));
    Ok(swapped(read(db_path, DONE_META_KEY)?) || swapped(read(db_path, V1_DONE_META_KEY)?))
}

/// What the registry alone says about its swap, read without the kept file
/// (a read of that file leaves SQLite sidecars beside it): the full starts
/// counted, and when the swap was (`None`: the registry has no swap record,
/// or the record has no time).
fn swap_record(db_path: &Path) -> anyhow::Result<Option<(u64, Option<u64>)>> {
    let connection = open_registry_database_read_only(db_path)?;
    connection.busy_timeout(Duration::from_secs(5))?;
    let read = |key: &str| -> anyhow::Result<Option<String>> {
        Ok(connection
            .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| {
                row.get::<_, String>(0)
            })
            .optional()?)
    };
    let record = [read(DONE_META_KEY)?, read(V1_DONE_META_KEY)?]
        .into_iter()
        .flatten()
        .find(|value| value.contains("\"kept\""));
    let Some(record) = record else { return Ok(None) };
    // `{"at_ms":"<ms>","kept":"<records>"}`; a number is read too.
    let at_ms = serde_json::from_str::<serde_json::Value>(&record).ok().and_then(|value| {
        let at = value.get("at_ms")?;
        at.as_u64().or_else(|| at.as_str()?.parse().ok())
    });
    let starts =
        read(FULL_STARTS_META_KEY)?.and_then(|value| value.parse::<u64>().ok()).unwrap_or(0);
    Ok(Some((starts, at_ms)))
}

/// A previous registry exists and no owner got through a full start on the
/// registry that replaced it: a failed owner build may still roll back.
pub(crate) fn rollback_possible(db_path: &Path) -> bool {
    let previous = previous_path(db_path);
    if !previous.is_file() || !db_path.is_file() || !is_swapped_registry(db_path, &previous) {
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
        // Past the rollback window the count is only for the kept file's
        // rule: a start is never refused for it.
        if kept_path(db_path).exists()
            && matches!(swap_record(db_path), Ok(Some(_)))
            && let Err(error) = count_full_start(db_path)
        {
            eprintln!(
                "cmux-tui: output cleanup: a full start was not counted for the kept previous \
                 registry: {error:#}"
            );
        }
        return Ok(());
    }
    // A backup that cannot be read (held by another process, unreadable) is
    // not proof the registry is another one: answering "not swapped" would
    // let this start serve without its confirmation, and a later failed start
    // could roll back over what it served. Once more after a failure, then
    // the start is refused.
    let previous = previous_path(db_path);
    let swapped = swapped_registry(db_path, &previous)
        .or_else(|_| swapped_registry(db_path, &previous))
        .with_context(|| {
            format!(
                "check whether the registry was made from the output cleanup backup {} (the \
                 start is refused; the next start tries again)",
                previous.display()
            )
        })?;
    if !swapped {
        eprintln!(
            "cmux-tui: output cleanup: the registry is not the one made from {}; it stays",
            previous_path(db_path).display()
        );
        return Ok(());
    }
    // Once more after a failure (a busy registry). A start that cannot
    // record itself is not a full start: the caller refuses it before it
    // serves, so a later failed start can never roll back a served session.
    count_full_start(db_path).or_else(|_| count_full_start(db_path)).context(
        "record the first full start on the output-cleaned registry (the start is refused; \
         the next start tries again)",
    )
}

/// One more full owner start in the registry's count.
fn count_full_start(db_path: &Path) -> anyhow::Result<()> {
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
}

/// At an open with no rollback to do. Once an owner got through a full
/// start on the new registry, the file the swap replaced leaves the name the
/// rollback uses and is kept under [`kept_path`]; the kept file goes, off the
/// start path, when its rule is met (module docs). Neither step reads or
/// writes the content of the file.
pub(crate) fn keep_or_remove_previous_registry(db_path: &Path) {
    keep_previous_registry(db_path);
    let Some(kept) = kept_file_due(db_path, now_ms()) else { return };
    let _ =
        std::thread::Builder::new().name("cmux-output-cleanup-remove".into()).spawn(move || {
            match remove_previous_with_sidecars(&kept) {
                Ok(()) => eprintln!(
                    "cmux-tui: output cleanup: removed the previous registry {}",
                    kept.display()
                ),
                Err(error) => eprintln!(
                    "cmux-tui: output cleanup: could not remove {}: {error:#}",
                    kept.display()
                ),
            }
        });
}

/// The first step: after one full start, `.pre-output-cleanup` gets the
/// kept name.
fn keep_previous_registry(db_path: &Path) {
    let previous = previous_path(db_path);
    let kept = kept_path(db_path);
    if previous.exists() {
        if !is_swapped_registry(db_path, &previous) {
            eprintln!(
                "cmux-tui: output cleanup: kept {}: the registry is not the one made from it",
                previous.display()
            );
            return;
        }
        if !matches!(swap_record(db_path), Ok(Some((starts, _))) if starts > 0) {
            // Still the rollback window.
            return;
        }
        if kept.exists() {
            // Never one kept file over another: the older one is the
            // larger history. This one waits under its name.
            eprintln!(
                "cmux-tui: output cleanup: {} stays: an older previous registry is still kept \
                 as {}",
                previous.display(),
                kept.display()
            );
            return;
        }
        if let Err(error) = fs::rename(&previous, &kept) {
            eprintln!(
                "cmux-tui: output cleanup: could not keep {} as {}: {error}",
                previous.display(),
                kept.display()
            );
            return;
        }
        if let Some(parent) = db_path.parent() {
            let _ = platform::sync_directory(parent);
        }
        eprintln!(
            "cmux-tui: output cleanup: the previous registry is kept as {} for at least {} days \
             and {BACKUP_KEEP_FULL_STARTS} full starts; no start reads it",
            kept.display(),
            BACKUP_KEEP.as_secs() / 86_400
        );
    }
    // Sidecars a read of the previous file left (they hold no data: the
    // swap folded its log first), or an older build left without it.
    for suffix in ["-wal", "-shm", "-journal"] {
        let _ = remove_if_present(&sidecar_path(&previous, suffix));
    }
}

/// When the swap behind `backup` was: the registry's record of it, or, for
/// a record with no time (written by hand, or by a build before the time
/// was recorded), the last write of the file, which is the swap.
fn swap_time_ms(recorded: Option<u64>, backup: &Path) -> Option<u64> {
    recorded.or_else(|| {
        let modified = fs::metadata(backup).ok()?.modified().ok()?;
        u64::try_from(modified.duration_since(std::time::UNIX_EPOCH).ok()?.as_millis()).ok()
    })
}

/// The second step, as a decision: the kept file when its rule is met at
/// `now_ms` and the registry is the one a swap made from it. Every doubt
/// keeps the file.
fn kept_file_due(db_path: &Path, now_ms: u64) -> Option<std::path::PathBuf> {
    let kept = kept_path(db_path);
    if !kept.exists() {
        return None;
    }
    let (starts, recorded) = match swap_record(db_path) {
        Ok(Some(record)) => record,
        Ok(None) => {
            eprintln!(
                "cmux-tui: output cleanup: kept {}: the registry is not the one made from it",
                kept.display()
            );
            return None;
        }
        Err(error) => {
            eprintln!(
                "cmux-tui: output cleanup: kept {}: the registry's swap record could not be \
                 read: {error:#}",
                kept.display()
            );
            return None;
        }
    };
    if !backup_due(now_ms, swap_time_ms(recorded, &kept)?, starts) {
        return None;
    }
    // The last check, and the one that reads the kept file: another
    // registry in this place never removes it.
    if !is_swapped_registry(db_path, &kept) {
        eprintln!(
            "cmux-tui: output cleanup: kept {}: the registry is not the one made from it",
            kept.display()
        );
        return None;
    }
    Some(kept)
}

/// The file a swap replaced, under either name, for `server-stats`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct HeldBackup {
    /// The file name beside the registry.
    pub(crate) name: String,
    pub(crate) bytes: u64,
    /// When the swap was, in milliseconds since the Unix epoch; `None` when
    /// it is not known (the file then stays).
    pub(crate) swapped_at_ms: Option<u64>,
    /// The first time the file can go: the swap plus [`BACKUP_KEEP`].
    pub(crate) kept_until_ms: Option<u64>,
    /// Full owner starts counted since the swap, and how many more the
    /// file stays through.
    pub(crate) full_starts: u64,
    pub(crate) full_starts_left: u64,
}

/// What is held beside the registry at `db_path`: the kept file, or the
/// file of the rollback window. Reads the registry's `meta` on its own
/// read-only connection and one file size; never the held file's content.
pub(crate) fn held_backup(db_path: &Path) -> Option<HeldBackup> {
    let path =
        [kept_path(db_path), previous_path(db_path)].into_iter().find(|path| path.exists())?;
    let (full_starts, recorded) = swap_record(db_path).ok().flatten().unwrap_or((0, None));
    let swapped_at_ms = swap_time_ms(recorded, &path);
    let keep_ms = u64::try_from(BACKUP_KEEP.as_millis()).unwrap_or(u64::MAX);
    Some(HeldBackup {
        name: path.file_name()?.to_string_lossy().into_owned(),
        bytes: fs::metadata(&path).map_or(0, |metadata| metadata.len()),
        swapped_at_ms,
        kept_until_ms: swapped_at_ms.map(|at| at.saturating_add(keep_ms)),
        full_starts,
        full_starts_left: BACKUP_KEEP_FULL_STARTS.saturating_sub(full_starts),
    })
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

#[cfg(test)]
#[path = "backup_tests.rs"]
mod tests;
