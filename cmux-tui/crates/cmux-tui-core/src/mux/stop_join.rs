//! One bounded join for each thread that a stop of this process waits for,
//! and the list of the threads that such a join left alive.
//!
//! A stop that joins a thread with no bound hangs with that thread. Each
//! join on the way to an owner's release goes through
//! [`Mux::join_within_stop`]: it waits [`STOP_JOIN_WAIT`] for the thread's
//! end. A thread that did not end in that time stays where it is, the stop
//! goes on without it, and the thread goes into this process's list with its
//! name. An owner's release reads the list ([`alive_at`]): while one of those
//! threads lives, the owner keeps its session until its exit and names the
//! thread, because a thread that a stop left can still write files of the
//! session.
//!
//! An entry of the list has the session folder of its owner where the join
//! has it ([`Mux::join_within_own_stop`], and the stop of the output store's
//! writer): that thread keeps the session of that owner only. A join that
//! has no owner at hand ([`Mux::join_within_stop`]) makes an entry with no
//! owner, and such a thread keeps each owner of the process while it lives:
//! the list cannot say whose files it writes (decision of 2026-11-17).

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::Mux;

/// How long one join of a stop waits for its thread's end.
pub(crate) const STOP_JOIN_WAIT: Duration = Duration::from_secs(2);

/// How often a bounded join looks at its thread: a thread's handle has no
/// join with a bound, and a look is one atomic read.
const LOOK_EVERY: Duration = Duration::from_millis(2);

/// A thread that a bounded join left alive.
struct Left {
    name: &'static str,
    /// The session folder of the owner whose stop left the thread. `None`:
    /// the join had no owner, and the thread keeps each owner.
    owner: Option<PathBuf>,
    /// True when the thread ended.
    ended: Box<dyn Fn() -> bool + Send>,
}

static LEFT: Mutex<Vec<Left>> = Mutex::new(Vec::new());

fn list() -> MutexGuard<'static, Vec<Left>> {
    LEFT.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Wait until `deadline` for `thread`'s end. True when the thread ended.
pub(crate) fn ended_by<T>(thread: &JoinHandle<T>, deadline: Instant) -> bool {
    loop {
        if thread.is_finished() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(LOOK_EVERY);
    }
}

/// Put a thread that a stop left alive into the list, with the name that a
/// release gives for it. `owner` is the session folder of the thread's
/// owner: the thread keeps that owner only. With no owner it keeps each
/// owner of the process. `ended` is true when that thread ended.
pub(crate) fn left(
    owner: Option<&Path>,
    name: &'static str,
    ended: impl Fn() -> bool + Send + 'static,
) {
    list().push(Left { name, owner: owner.map(Path::to_path_buf), ended: Box::new(ended) });
}

/// The names of the threads of the list that keep the owner whose session
/// folder is `owner`, and that live at `deadline`: the threads of that
/// owner, and the threads with no owner. It returns before `deadline` when
/// none of them lives. A thread that ended leaves the list.
pub(crate) fn alive_at(owner: Option<&Path>, deadline: Instant) -> Vec<&'static str> {
    loop {
        let alive = {
            let mut threads = list();
            threads.retain(|left| !(left.ended)());
            let keeps = |left: &&Left| left.owner.as_deref().is_none_or(|of| Some(of) == owner);
            threads.iter().filter(keeps).map(|left| left.name).collect::<Vec<_>>()
        };
        if alive.is_empty() || Instant::now() >= deadline {
            return alive;
        }
        std::thread::sleep(LOOK_EVERY);
    }
}

/// [`Mux::join_within_stop`] with the bound `wait`.
pub(super) fn join_for<T: Send + 'static>(
    name: &'static str,
    thread: JoinHandle<T>,
    wait: Duration,
) -> Option<std::thread::Result<T>> {
    join_of(None, name, thread, wait)
}

/// [`join_for`] for a thread of the owner whose session folder is `owner`.
fn join_of<T: Send + 'static>(
    owner: Option<&Path>,
    name: &'static str,
    thread: JoinHandle<T>,
    wait: Duration,
) -> Option<std::thread::Result<T>> {
    if thread.thread().id() == std::thread::current().id() {
        return None;
    }
    if ended_by(&thread, Instant::now() + wait) {
        return Some(thread.join());
    }
    eprintln!(
        "cmux-tui: the {name} did not stop within {} ms; shutdown goes on without it",
        wait.as_millis()
    );
    left(owner, name, move || thread.is_finished());
    None
}

impl Mux {
    /// Join a thread that a stop of this process waits for, with the bound
    /// [`STOP_JOIN_WAIT`].
    ///
    /// `Some` is the thread's end. `None`: the thread did not end in that
    /// time. One stderr line with `name` says so, the caller's stop goes on
    /// without the thread, and the release of each owner of this process
    /// keeps its session with `name` while the thread lives. `None` also
    /// when the caller is that thread: a thread does not join itself.
    pub fn join_within_stop<T: Send + 'static>(
        name: &'static str,
        thread: JoinHandle<T>,
    ) -> Option<std::thread::Result<T>> {
        join_for(name, thread, STOP_JOIN_WAIT)
    }

    /// [`Self::join_within_stop`] for a thread of this owner: a thread that
    /// did not end keeps the session of this owner only.
    pub(super) fn join_within_own_stop<T: Send + 'static>(
        &self,
        name: &'static str,
        thread: JoinHandle<T>,
    ) -> Option<std::thread::Result<T>> {
        join_of(self.stop_owner(), name, thread, STOP_JOIN_WAIT)
    }

    /// The session folder of this owner, as the list of the left threads
    /// has it: the output store's folder is in it. `None`: an owner with no
    /// folder; its release reads the threads with no owner only.
    pub(crate) fn stop_owner(&self) -> Option<&Path> {
        self.output_store.directory().and_then(Path::parent)
    }
}
