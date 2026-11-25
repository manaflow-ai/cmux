//! Part of `Hub`; see `hub/mod.rs`. A fork's pending start, kept in its meta
//! ([`crate::store::ForkStart`]) until its agent took the chat's conversation.
//!
//! A fork gets the chat's conversation when its agent first starts: Claude by
//! `--resume <chat> --fork-session` (`Session::fork_from`), a fork onto another
//! harness or one made from acpmux's transcript by its first prompt
//! (`Session::rehydrate`). Both were in memory only, so a daemon restart before
//! that start (a fork made 0.4 s before `acpmux daemon restart`, or at the same
//! moment) left a fork that listed the chat's turns while its agent started a
//! fresh conversation (cmux#50096, "I don't see a codeword anywhere"). Now the
//! next daemon starts it as the first one would have. A fork the restart cut
//! off while it was being made (its meta written, its `forked` record not) is
//! closed at that start and said so in the log, never shown as a copy.

use super::*;
use crate::store::ForkStart;

impl Session {
    /// Keeps what the fork's first start needs (`fork_from`, `rehydrate` and its note) in its
    /// meta, the next save writes it. `made`: the fork is whole (a chat that adopts or watches
    /// another app's conversation as a fork); `fork.rs` marks its own once its history is in.
    pub(super) fn keep_fork_start(&self, made: bool) {
        let resume_from = self.fork_from.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let rehydrate = self.rehydrate.load(Ordering::SeqCst);
        let note = self.rehydrate_note.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let start = ForkStart { made, resume_from, rehydrate, note };
        let mut meta = self.meta.lock().unwrap_or_else(|e| e.into_inner());
        meta.fork_start = (!start.settled()).then_some(start);
    }

    /// The fork is whole: from here a restart keeps it.
    pub(super) fn fork_made(&self) {
        self.edit_fork_start(|start| start.made = true);
    }

    /// Its agent started from the chat's conversation (`--resume --fork-session`).
    pub(super) fn fork_resumed(&self) {
        self.fork_from.lock().unwrap_or_else(|e| e.into_inner()).take();
        self.edit_fork_start(|start| start.resume_from = None);
    }

    /// Whether the next prompt carries the chat's transcript; taken once, also from the meta.
    pub(super) fn take_rehydrate(&self) -> bool {
        let taken = self.rehydrate.swap(false, Ordering::SeqCst);
        if taken {
            self.edit_fork_start(|start| {
                start.rehydrate = false;
                start.note = None;
            });
        }
        taken
    }

    fn edit_fork_start(&self, edit: impl FnOnce(&mut ForkStart)) {
        let mut meta = self.meta.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(start) = meta.fork_start.as_mut() {
            edit(start);
            if start.settled() {
                meta.fork_start = None;
            }
        }
    }
}

/// What a session read from the store starts with of its fork's pending start: the
/// `fork_from`, `rehydrate` and note its first start uses (`Hub::make_session`).
pub(super) fn restored(meta: &SessionMeta) -> (Option<String>, bool, Option<String>) {
    match &meta.fork_start {
        Some(s) => (s.resume_from.clone(), s.rehydrate, s.note.clone()),
        None => (None, false, None),
    }
}

/// A fork the last daemon was still making when it stopped: closed now, and said so. True when
/// it was closed here (`Hub::install_stored_session`).
pub(super) fn close_cut_off(meta: &mut SessionMeta) -> bool {
    let cut_off = meta.fork_start.as_ref().is_some_and(|s| !s.made);
    if !cut_off || meta.status == SessionStatus::Closed {
        return false;
    }
    meta.status = SessionStatus::Closed;
    tracing::warn!(
        session = %meta.id,
        parent = meta.parent_id.as_deref().unwrap_or("-"),
        name = %meta.name,
        "fork closed: the daemon stopped while it was being made, so it holds only part of its chat; fork the chat again"
    );
    true
}
