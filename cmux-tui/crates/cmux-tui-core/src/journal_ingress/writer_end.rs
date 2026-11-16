//! The end of the journal writer's thread, for the owner's release of its
//! session (decision of 2026-11-16).
//!
//! A join of the writer waits for a bound and then goes on without the
//! thread (`JournalWriter::join_until`): the thread's handle is dropped, and
//! a commit that the writer admitted is still its own. The owner must not
//! give the session to the next owner while that thread lives, so the
//! thread says here when it ended, and the release waits for that with a
//! deadline (a condition variable, no poll). The text of a join that ran out
//! stays here too, for the record that the next owner reads.

use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use crate::panic_free::RecoverPoison;

#[derive(Default)]
pub(super) struct WriterEnd {
    state: Mutex<WriterEndState>,
    changed: Condvar,
}

#[derive(Default)]
struct WriterEndState {
    /// Writer threads that started and did not end.
    running: usize,
    /// What the join that ran out said.
    late_join: Option<String>,
}

impl WriterEnd {
    /// A writer thread starts. The thread owns the value that this returns
    /// and drops it at its end.
    pub(super) fn begin(self: &Arc<Self>) -> WriterRuns {
        self.state.lock().recover_poison().running += 1;
        WriterRuns(Arc::clone(self))
    }

    /// True when no writer thread lives. Waits for that at most until
    /// `deadline`; a thread that ended is seen also after the deadline.
    pub(super) fn ended_by(&self, deadline: Instant) -> bool {
        let mut state = self.state.lock().recover_poison();
        while state.running > 0 {
            let wait = deadline.saturating_duration_since(Instant::now());
            if wait.is_zero() {
                return false;
            }
            state = self.changed.wait_timeout(state, wait).recover_poison().0;
        }
        true
    }

    /// A join of the writer ran out; `text` is what it said.
    pub(super) fn note_late_join(&self, text: &str) {
        self.state.lock().recover_poison().late_join = Some(text.to_owned());
    }

    pub(super) fn late_join(&self) -> Option<String> {
        self.state.lock().recover_poison().late_join.clone()
    }
}

/// Held by a writer thread from its start to its end, also when the thread
/// ends by a panic.
pub(super) struct WriterRuns(Arc<WriterEnd>);

impl Drop for WriterRuns {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().recover_poison();
        state.running = state.running.saturating_sub(1);
        drop(state);
        self.0.changed.notify_all();
    }
}
