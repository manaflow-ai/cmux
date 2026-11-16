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
//!
//! An open that an owner refuses reads the same file, without the locks: only
//! when it says that the owner keeps the session until its exit, the open
//! waits for that owner's end, with a bound ([`KeptOwnerWait`]). With no such
//! record an open is refused at once, as before.

use std::fs;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use cmux_file_lock::LockError;
use serde_json::{Value, json};

use super::SessionLease;
use super::terminal_state_end::{LockWait, wait_for_session_locks};

/// The file, in the session's folder, in which an owner says how its release
/// went.
pub(crate) const RELEASE_RECORD_FILE: &str = "previous-owner-release.json";
/// The record's `release` of an owner that keeps the session until its
/// process ends.
pub(crate) const KEPT_RELEASE: &str = "kept until the exit";
/// The record's `release` of an owner that gave the session up.
const FREE_RELEASE: &str = "released";
/// How long an open waits for an owner that said that it keeps the session
/// until its exit (decision of 2026-11-16). Such an owner ended its shutdown:
/// its process ends next, so a start right after a stop gets the session and
/// is not refused.
const KEPT_OWNER_WAIT: Duration = Duration::from_secs(3);
/// The most bytes that an open reads of the record file. A record of this
/// code is a few hundred bytes; the folder can hold a file with that name
/// that this code did not write.
const RECORD_READ_BOUND: u64 = 64 * 1024;

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
/// one. A file that cannot be read, that is not a plain file, that is longer
/// than [`RECORD_READ_BOUND`], or that does not hold a record (its writer
/// ended in the middle), gives a value that says so: it never stops a start.
fn read_record(session_dir: &Path) -> Option<Value> {
    let unreadable = |why: String| Some(json!({"unreadable": true, "error": why}));
    let path = session_dir.join(RELEASE_RECORD_FILE);
    // No open of a thing that is not a plain file: the open of a pipe waits
    // for its writer.
    let size = match fs::symlink_metadata(&path) {
        Ok(found) if found.is_file() => found.len(),
        Ok(_) => return unreadable("not a plain file".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return None,
        Err(error) => return unreadable(error.to_string()),
    };
    if size > RECORD_READ_BOUND {
        return unreadable(format!("{size} bytes, more than the bound of {RECORD_READ_BOUND}"));
    }
    // The read has the bound too: the file can grow after the size was read.
    let mut bytes = Vec::new();
    let read = fs::File::open(&path)
        .and_then(|file| file.take(RECORD_READ_BOUND.saturating_add(1)).read_to_end(&mut bytes));
    match read {
        Ok(_) if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > RECORD_READ_BOUND => {
            unreadable(format!("more than the bound of {RECORD_READ_BOUND} bytes"))
        }
        Ok(_) => Some(
            serde_json::from_slice::<Value>(&bytes)
                .ok()
                .filter(Value::is_object)
                .unwrap_or_else(|| json!({"unreadable": true, "bytes": bytes.len()})),
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => unreadable(error.to_string()),
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

/// The wait of one open for an owner that keeps the session until its exit.
///
/// An open takes the session guard and then the writer lease, each with one
/// try. When a holder refuses a try and the record in the session's folder
/// says that the owner keeps the session, the open waits for that lock: a
/// blocking lock call on a helper thread, which the kernel wakes when the
/// holder drops the lock or its process ends, and a deadline. No poll. One
/// deadline for the open, from its first refused try: the two steps share
/// it. Then the open tries one more time.
pub(super) struct KeptOwnerWait<'a> {
    session_dir: &'a Path,
    /// When this open's wait began, and when it ends.
    wait: Option<(Instant, Instant)>,
}

impl<'a> KeptOwnerWait<'a> {
    pub(super) fn new(session_dir: &'a Path) -> Self {
        Self { session_dir, wait: None }
    }

    /// Takes one of the session's locks with `acquire`; `lock` is the file
    /// of that lock. A refusal with no record of a kept session is returned
    /// at once, and so is each error that is not the refusal of a holder.
    pub(super) fn take(
        &mut self,
        lock: &Path,
        acquire: impl Fn() -> anyhow::Result<SessionLease>,
    ) -> anyhow::Result<SessionLease> {
        let refused = match acquire() {
            Ok(lease) => return Ok(lease),
            Err(refused) => refused,
        };
        if !refused_by_a_holder(&refused) {
            return Err(refused);
        }
        let Some(record) = read_record(self.session_dir).filter(says_kept) else {
            return Err(refused);
        };
        let (began, deadline) = *self.wait.get_or_insert_with(|| {
            let began = Instant::now();
            #[cfg(test)]
            super::terminal_state_end::kept_owner_wait_started_for_test();
            (began, began + kept_owner_wait())
        });
        match wait_for_session_locks(vec![lock.to_path_buf()], deadline) {
            // The lock was free for a moment. A refusal now is the plain
            // one, of whichever holder took it.
            Ok(LockWait::Free) => acquire(),
            Ok(LockWait::StillHeld) => {
                // The pid is the record's word. This open did not check it:
                // the holder can be another process than the record's.
                let pid = record
                    .get("pid")
                    .and_then(Value::as_u64)
                    .map(|pid| format!(" (pid {pid} by that record)"))
                    .unwrap_or_default();
                Err(refused.context(format!(
                    "workspace session is already owned by another daemon; a record in the \
                     session's folder says that an owner{pid} keeps the session until its \
                     exit; the session was not free in {} ms",
                    began.elapsed().as_millis()
                )))
            }
            Err(error) => Err(refused.context(format!(
                "workspace session is already owned by another daemon; a record in the \
                 session's folder says that an owner keeps the session until its exit; the \
                 wait for its end failed: {error:#}"
            ))),
        }
    }
}

/// The bound of an open's wait for an owner that keeps the session.
#[cfg(not(test))]
fn kept_owner_wait() -> Duration {
    KEPT_OWNER_WAIT
}

/// The bound of an open's wait for an owner that keeps the session: the one
/// that a test set for its thread, or the product's.
#[cfg(test)]
fn kept_owner_wait() -> Duration {
    super::terminal_state_end::kept_owner_wait_for_test().unwrap_or(KEPT_OWNER_WAIT)
}

/// True when `error` is the refusal of a lock's holder, by its type, and not
/// a file or a path fault.
fn refused_by_a_holder(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| matches!(cause.downcast_ref::<LockError>(), Some(LockError::Busy(_))))
}

/// True when `record` says that its owner keeps the session until its exit.
fn says_kept(record: &Value) -> bool {
    record.get("release").and_then(Value::as_str) == Some(KEPT_RELEASE)
}
