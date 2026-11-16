//! An owner that keeps its session until its process ends (decision of
//! 2026-11-16).
//!
//! The session's locks are the last thing an owner gives up. When a thread
//! that can still write the session's stores does not end in the owner's
//! release, the owner keeps the locks: nothing of the process drops them
//! from then on, and the kernel frees them when the process ended, which is
//! when each of its threads is gone.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use super::SessionLease;

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
