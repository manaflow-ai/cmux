//! Part of `Hub`; see `hub/mod.rs`. A chat's metadata (`session.json`): one writer, versioned
//! commits.
//!
//! Every change to a chat's metadata (its draft, name, mode, unread mark, bookmarks, tags, turn
//! cap, policy, rules and the rest) is made in memory and then committed with
//! [`Hub::commit_meta`]: the change takes the chat's next version, and the chat's writer
//! commits to `session.json` in version order. The writer is whichever caller finds none at
//! work; it reads the version committed so far as its target, copies the metadata (which holds
//! every change up to that version, as each change is made before it takes its version), writes
//! the copy (`write_atomic`: on disk, renamed, its folder synced), marks the target durable, and
//! goes on while a newer version waits. Every other caller writes nothing. So a copy older than a
//! committed change can never be written after it, and a burst of changes shares one write.
//!
//! Before, each caller copied the metadata and wrote its own copy, with no order between two
//! callers of one chat: a copy taken before a change could be written after that change's own
//! write, so `session.json` kept the older value although the change had been answered, and a
//! `kill -9` before the next save lost it (fuzz row g finding g2: an acknowledged
//! `_acpmux/draft_set`, "the one durable shared draft").
//!
//! A request whose answer reports a change ([`Hub::save_meta_answered`]) waits until its version
//! is durable; a commit that fails fails the request (`store.save_failed`), and the change stays
//! in memory for the next commit. A change no request answers for ([`Hub::save_meta`]) takes its
//! version and returns: the writer at work (or this caller, when none is) commits it.
//!
//! Test seam (debug builds): `ACPMUX_TEST_SAVE_META_HOLD_DIR` names a folder. When it holds
//! `hold-<session id>`, the writer's next commit for that chat takes the file (renames it to
//! `held-<session id>`) after it copied the metadata and before it writes the copy, and waits until
//! `release-<session id>` exists (at most 30 s). A test so holds an older copy of a chat's
//! metadata while other requests change it (`tests/meta_save_order.rs`). When the folder holds
//! `kill-<session id>`, that commit removes the file and the daemon kills itself with SIGKILL at
//! the same point: after the change is made in memory and copied, before its write
//! (`tests/meta_save_kill_point.rs`).

use super::*;
use std::sync::Condvar;

/// One chat's metadata writer (module text). Its lock is never held across a write.
#[derive(Default)]
pub(crate) struct MetaWriter {
    state: StdMutex<WriterState>,
    /// Signalled when a commit ends, written or failed.
    done: Condvar,
}

#[derive(Default)]
struct WriterState {
    /// The newest version a change took.
    requested: u64,
    /// The newest version on disk.
    durable: u64,
    /// A caller is writing.
    writing: bool,
    /// The newest version a failed commit covered, and its error: the requests for versions up
    /// to it that are not durable fail.
    failed: Option<(u64, String)>,
}

/// Whether a commit waits for its version to be durable.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Wait {
    Durable,
    No,
}

impl MetaWriter {
    /// Takes the next version for the change the caller just made, and commits it: as the
    /// writer, when none is at work; else it waits for the writer (`Wait::Durable`) or returns
    /// (`Wait::No`). `write` copies the metadata and writes the copy.
    pub(super) fn commit(&self, wait: Wait, write: &dyn Fn() -> Result<()>) -> Result<()> {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // After the caller's change: a copy taken once this version is the target holds it.
        state.requested += 1;
        let version = state.requested;
        loop {
            if state.durable >= version {
                return Ok(());
            }
            if let Some((upto, error)) = &state.failed
                && *upto >= version
            {
                anyhow::bail!("{error}");
            }
            if !state.writing {
                state.writing = true;
                drop(state);
                self.run(write);
                state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                continue;
            }
            if wait == Wait::No {
                return Ok(());
            }
            // The writer runs no task of this runtime: it copies, writes and wakes.
            state = self.done.wait(state).unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    }

    /// The writer: commits until nothing newer waits or a commit fails, then hands the role back.
    fn run(&self, write: &dyn Fn() -> Result<()>) {
        // A writer that unwinds hands the role back, so no waiter waits for it forever.
        struct Unwind<'a>(&'a MetaWriter);
        impl Drop for Unwind<'_> {
            fn drop(&mut self) {
                if std::thread::panicking() {
                    let mut state =
                        self.0.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    state.writing = false;
                    state.failed = Some((state.requested, "the metadata writer panicked".into()));
                    self.0.done.notify_all();
                }
            }
        }
        let _unwind = Unwind(self);
        loop {
            let target = {
                let mut state =
                    self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                if state.requested <= state.durable {
                    state.writing = false;
                    self.done.notify_all();
                    return;
                }
                state.requested
            };
            // Copied after the target is read: the copy holds every change up to it.
            let written = write();
            let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            match written {
                Ok(()) => {
                    state.durable = state.durable.max(target);
                    if state.failed.as_ref().is_some_and(|(upto, _)| *upto <= target) {
                        state.failed = None;
                    }
                    self.done.notify_all();
                }
                Err(e) => {
                    // No retry here: the requests it covered fail, and the next change commits
                    // again.
                    state.failed = Some((target, e.to_string()));
                    state.writing = false;
                    self.done.notify_all();
                    return;
                }
            }
        }
    }
}

impl Hub {
    /// Commits a change no request answers for; a failed commit is logged.
    pub(super) fn save_meta(&self, session: &Session) {
        if let Err(e) = self.commit_meta(session, Wait::No) {
            tracing::warn!(session = %session.id, "save meta failed: {e}");
        }
    }

    /// Commits a change a request answers for: returns once it is durable; a failed commit
    /// fails the request.
    pub(super) fn save_meta_answered(&self, session: &Session) -> Result<(), RpcError> {
        self.write_meta(session).map_err(|e| {
            tracing::warn!(session = %session.id, "save meta failed: {e}");
            RpcError::internal(format!("the chat's change was not saved: {e}"))
                .with_data(json!({"reason": "store.save_failed"}))
        })
    }

    /// Commits the chat's metadata and waits until it is durable (a chat's first save, a fork's).
    pub(super) fn write_meta(&self, session: &Session) -> Result<()> {
        self.commit_meta(session, Wait::Durable)
    }

    /// The commit of the change just made to `session`'s metadata (module text).
    fn commit_meta(&self, session: &Session, wait: Wait) -> Result<()> {
        session.meta_writer.commit(wait, &|| self.write_snapshot(session))
    }

    /// One copy of the metadata, written; never a purged chat's. A late save (a generated title
    /// after the turn, a tag) would write its record back after the purge deleted it, and the next
    /// daemon start loaded it as a closed session: the Chief's compactor, which purges each node's
    /// session when the node is built, left about 450 of them in two hours (2026-10-20).
    fn write_snapshot(&self, session: &Session) -> Result<()> {
        if session.purged.load(Ordering::SeqCst) {
            return Ok(());
        }
        let meta = session.meta();
        #[cfg(debug_assertions)]
        hold_seam(&session.id);
        let saved = self.store.save(&meta);
        // The purge ran between the check and the save: delete it again.
        if session.purged.load(Ordering::SeqCst)
            && let Err(e) = self.store.delete(&session.id)
        {
            tracing::warn!(session = %session.id, "delete of a purged session failed: {e}");
        }
        saved
    }
}

/// Runs the seam's wait; on a worker of a multi-thread runtime, the worker's other tasks go to
/// another thread first (a task in a blocked worker's LIFO slot is not stolen), so the requests a
/// test sends while a commit is held run.
#[cfg(debug_assertions)]
fn off_worker<T>(wait: impl FnOnce() -> T) -> T {
    match tokio::runtime::Handle::try_current().map(|h| h.runtime_flavor()) {
        Ok(tokio::runtime::RuntimeFlavor::MultiThread) => tokio::task::block_in_place(wait),
        _ => wait(),
    }
}

/// The seam in the module text, between the writer's copy and its write.
#[cfg(debug_assertions)]
fn hold_seam(session_id: &str) {
    let Some(dir) = std::env::var_os("ACPMUX_TEST_SAVE_META_HOLD_DIR") else { return };
    let dir = std::path::PathBuf::from(dir);
    // Removed first, so the next daemon does not kill itself again.
    if std::fs::remove_file(dir.join(format!("kill-{session_id}"))).is_ok() {
        // SAFETY: a signal to this process; the test that asked for it restarts the daemon.
        unsafe { libc::kill(libc::getpid(), libc::SIGKILL) };
    }
    let hold = dir.join(format!("hold-{session_id}"));
    if std::fs::rename(&hold, dir.join(format!("held-{session_id}"))).is_err() {
        return;
    }
    let release = dir.join(format!("release-{session_id}"));
    let wait = || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !release.exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    };
    // On a worker of the daemon's runtime, the wait hands the worker's other tasks to another
    // thread first, so the requests the test sends meanwhile run (a task in a blocked worker's
    // LIFO slot is not stolen).
    off_worker(wait);
    let _ = std::fs::remove_file(release);
}

#[cfg(test)]
#[path = "meta_save_tests.rs"]
mod tests;
