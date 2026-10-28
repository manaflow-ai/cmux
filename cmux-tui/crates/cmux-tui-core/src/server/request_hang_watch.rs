//! Hang-watch scopes of daemon frames and requests (p09-observability 073,
//! section 3E): Chrome's `WatchHangsInScope` (base/threading/hang_watcher.h)
//! with a deadline per [`MethodClass`].
//!
//! A thread runs one frame or request at a time, and that unit owns the
//! thread's request scope ([`RequestHang`]). A frame opens it at
//! [`FRAME_HANG_DEADLINE`] before anything parses; when the frame reaches
//! the request it runs, [`RequestHang::enter`] restarts the same scope at
//! the request's class deadline, so a frame never nests a second deadline
//! that its first could outlive. A request on a thread with no frame (the
//! dispatcher, a clear-history worker, a creation job) opens its own.
//!
//! A request of a class that may wait ([`MethodClass::may_wait`]) waits on
//! another process through [`ipc_reply`]: the scope stops blaming the
//! thread (Chrome's `HangWatcher::InvalidateActiveExpectations`) and the
//! trace marks the wait (`daemon.request.wait`). Any other class is still
//! watched through such a wait: a query that waits on a peer is the hang.

use std::cell::RefCell;
use std::marker::PhantomData;
use std::time::Duration;

use cmux_hang_watch::Scope;

use super::command_names::MethodClass;
use super::{Command, RequestHead};

/// How long a frame may take before it reaches its request (a `Command`,
/// a v2 resource operation or a feature route, each then watched at its
/// class deadline): the head parse, the admission and the hand-off to the
/// connection's queue (the Swift daemon reader's 1 s line scope, task 069).
pub(super) const FRAME_HANG_DEADLINE: Duration = Duration::from_secs(1);

/// The scope of the frame or request this thread runs, and the request's
/// class once it is known.
struct Current {
    class: Option<MethodClass>,
    scope: Option<Scope<'static>>,
}

thread_local! {
    static CURRENT: RefCell<Option<Current>> = const { RefCell::new(None) };
}

/// The owner of the thread's request scope: it closes the scope when it
/// drops. It belongs to the thread that opened it.
#[must_use = "the frame or request stops being watched when this drops"]
pub(super) struct RequestHang {
    _thread_bound: PhantomData<*const ()>,
}

impl RequestHang {
    /// Opens the scope of one frame. A frame inside a request (a request
    /// that handles a nested line) keeps the request's scope.
    pub(super) fn frame() -> Option<Self> {
        Self::open(None, FRAME_HANG_DEADLINE)
    }

    /// Watches `command` from now at its class deadline: the scope of the
    /// frame that runs it, or a new one owned by the returned value. A
    /// command that waits by design (`wait-for`) is not blamed.
    pub(super) fn enter_command(command: &Command) -> Option<Self> {
        let owner = Self::enter(command.method_class());
        if command.waits_by_design() {
            cmux_hang_watch::invalidate_active();
        }
        owner
    }

    /// Watches a request of `class` from now at its class deadline (see
    /// [`Self::enter_command`]).
    pub(super) fn enter(class: MethodClass) -> Option<Self> {
        let deadline = class.hang_deadline();
        let restarted = CURRENT.with(|current| {
            let mut current = current.borrow_mut();
            let Some(running) = current.as_mut() else { return false };
            running.class = Some(class);
            // Close before the open: scopes close innermost first, and
            // nothing opened above this one on its thread.
            running.scope = None;
            running.scope = Some(cmux_hang_watch::watch(deadline));
            true
        });
        if restarted { None } else { Self::open(Some(class), deadline) }
    }

    fn open(class: Option<MethodClass>, deadline: Duration) -> Option<Self> {
        CURRENT.with(|current| {
            let mut current = current.borrow_mut();
            if current.is_some() {
                return None;
            }
            *current = Some(Current { class, scope: Some(cmux_hang_watch::watch(deadline)) });
            Some(Self { _thread_bound: PhantomData })
        })
    }
}

impl Drop for RequestHang {
    fn drop(&mut self) {
        let closed = CURRENT.try_with(|current| current.borrow_mut().take());
        drop(closed);
    }
}

/// Runs a feature or operation route (server/routes.rs) for the line
/// `head` reads: the route is the line's request, so it is watched at the
/// class its span names ([`RequestHead::method`]), not at the frame's.
pub(super) fn route<R>(head: &RequestHead<'_>, entry: impl FnOnce() -> R) -> R {
    let _owner = RequestHang::enter(head.method().class);
    entry()
}

/// The class of the request this thread runs, if any.
fn current_class() -> Option<MethodClass> {
    CURRENT
        .try_with(|current| current.borrow().as_ref().and_then(|running| running.class))
        .ok()
        .flatten()
}

/// [`cmux_threads::checked::ipc_reply`] for a request handler: a request
/// whose class may wait is not blamed for the round trip, and the trace
/// marks it (arg0: the class).
#[track_caller]
pub(super) fn ipc_reply<R>(round_trip: impl FnOnce() -> R) -> R {
    let Some(class) = current_class().filter(|class| class.may_wait()) else {
        return cmux_threads::checked::ipc_reply(round_trip);
    };
    cmux_hang_watch::invalidate_active();
    let _wait = cmux_trace::trace_scope!(daemon, "daemon.request.wait", class as u8);
    cmux_threads::checked::ipc_reply(round_trip)
}

#[cfg(test)]
#[path = "request_hang_watch_tests.rs"]
mod tests;
