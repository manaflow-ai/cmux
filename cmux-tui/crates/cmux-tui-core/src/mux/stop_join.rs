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
//! The list is one for the process, not one for each owner: a thread that a
//! stop joins is not always started with a handle of an owner. The cost is a
//! process with two owners: a thread that the stop of one left keeps the
//! session of the other too while it lives.

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
/// release gives for it. `ended` is true when that thread ended.
pub(crate) fn left(name: &'static str, ended: impl Fn() -> bool + Send + 'static) {
    list().push(Left { name, ended: Box::new(ended) });
}

/// The names of the threads of the list that live at `deadline`. It returns
/// before `deadline` when none lives. A thread that ended leaves the list.
pub(crate) fn alive_at(deadline: Instant) -> Vec<&'static str> {
    loop {
        let alive = {
            let mut threads = list();
            threads.retain(|left| !(left.ended)());
            threads.iter().map(|left| left.name).collect::<Vec<_>>()
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
    left(name, move || thread.is_finished());
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
}
