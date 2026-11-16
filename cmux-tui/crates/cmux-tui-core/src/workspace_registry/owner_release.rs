//! An owner that keeps its session until its process ends (decision of
//! 2026-11-16).
//!
//! The session's locks are the last thing an owner gives up. When a thread
//! that can still write the session's stores does not end in the owner's
//! release, the owner keeps the locks: nothing of the process drops them
//! from then on, and the kernel frees them when the process ended, which is
//! when each of its threads is gone.
//!
//! An owner whose release waited for such a thread, or whose journal writer
//! ended after its join ran out, says so in a small file in the session's
//! folder ([`RELEASE_RECORD_FILE`]). It writes the file while it holds the
//! session, and the next owner, under its own locks, reads the file into its
//! start line and removes it. The stderr of a daemon is often lost; this
//! file is not. The record is a plain file and not a row of the store: the
//! thread that lives can be at a commit of the store.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use serde_json::{Value, json};

use super::SessionLease;

/// The file, in the session's folder, in which an owner says how its release
/// went.
pub(crate) const RELEASE_RECORD_FILE: &str = "previous-owner-release.json";
/// The record's `release` of an owner that keeps the session until its
/// process ends.
pub(crate) const KEPT_RELEASE: &str = "kept until the exit";
/// The record's `release` of an owner that gave the session up.
const FREE_RELEASE: &str = "released";

/// The session locks of each owner of this process that keeps its session,
/// with the session's folder. No product code takes an entry out.
static KEPT_UNTIL_EXIT: Mutex<Vec<(PathBuf, SessionLease)>> = Mutex::new(Vec::new());

/// The owner of the session in `session_dir` keeps `locks` until this
/// process ends: they outlive the owner's registry and the owner's value.
pub(crate) fn keep_until_exit(session_dir: &Path, locks: impl IntoIterator<Item = SessionLease>) {
    let mut kept = KEPT_UNTIL_EXIT.lock().unwrap_or_else(PoisonError::into_inner);
    kept.extend(locks.into_iter().map(|lock| (session_dir.to_path_buf(), lock)));
}

/// Test seam: what the end of the process does for the session in
/// `session_dir`, and for no other session: its kept locks are dropped.
#[cfg(test)]
pub(crate) fn end_kept_owner_for_test(session_dir: &Path) {
    KEPT_UNTIL_EXIT
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|(kept_dir, _)| kept_dir != session_dir);
}

/// What an owner says of its release in [`RELEASE_RECORD_FILE`].
pub(crate) struct ReleaseRecord<'a> {
    /// The owner keeps the session until its process ends.
    pub(crate) kept: bool,
    /// What still lived when the release's wait ended.
    pub(crate) alive: &'a [&'static str],
    /// How long the release waited.
    pub(crate) waited: Duration,
    /// What the join of the journal writer said when it ran out.
    pub(crate) writer_join: Option<String>,
}

/// Writes the record of this owner into `session_dir`, with the time and
/// this process's id. The caller holds the session's locks. A temporary file
/// and a rename, so the next owner reads the whole record or none.
pub(crate) fn write_record(session_dir: &Path, record: &ReleaseRecord<'_>) -> std::io::Result<()> {
    let mut line = json!({
        "at_ms": crate::startup_timings::unix_now_ms(),
        "pid": std::process::id(),
        "release": if record.kept { KEPT_RELEASE } else { FREE_RELEASE },
        "alive": record.alive,
        "waited_ms": u64::try_from(record.waited.as_millis()).unwrap_or(u64::MAX),
    });
    if let Some(text) = record.writer_join.as_deref()
        && let Some(fields) = line.as_object_mut()
    {
        fields.insert("writer_join".into(), Value::from(text));
    }
    let staged = session_dir.join(format!(".{RELEASE_RECORD_FILE}.{}", std::process::id()));
    fs::write(&staged, line.to_string())
        .and_then(|()| fs::rename(&staged, session_dir.join(RELEASE_RECORD_FILE)))
        .inspect_err(|_| {
            let _ = fs::remove_file(&staged);
        })
}

/// The record that the owner before left in `session_dir`, when there is
/// one. A file that cannot be read, or that does not hold a record (its
/// writer ended in the middle), gives a value that says so: it never stops
/// a start.
fn read_record(session_dir: &Path) -> Option<Value> {
    match fs::read(session_dir.join(RELEASE_RECORD_FILE)) {
        Ok(bytes) => Some(
            serde_json::from_slice::<Value>(&bytes)
                .ok()
                .filter(Value::is_object)
                .unwrap_or_else(|| json!({"unreadable": true, "bytes": bytes.len()})),
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => Some(json!({"unreadable": true, "error": error.to_string()})),
    }
}

/// The next owner, under its own session locks: reads the record of the
/// owner before it and removes the file, so the record is said one time and
/// no later open reads it as the word of the owner that runs now.
pub(crate) fn take_record(session_dir: &Path) -> Option<Value> {
    let record = read_record(session_dir)?;
    if let Err(error) = fs::remove_file(session_dir.join(RELEASE_RECORD_FILE)) {
        eprintln!("cmux-tui: could not remove the release record of the owner before: {error}");
    }
    Some(record)
}
