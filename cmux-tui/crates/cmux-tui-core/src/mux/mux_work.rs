//! The mux's blocking work, off request threads (p02-threads section 3F).
//!
//! A request handler answers from memory; what would block (a file read, a
//! wait for another thread) goes to a [`cmux_threads::work`] lane and
//! reports back through the mux when it finishes, as Chrome posts a
//! `MayBlock` task and replies on the calling sequence
//! (base/task/thread_pool.h `PostTaskAndReplyWithResult`). The daemon has one
//! mux, so this is the daemon's one [`Work`]; it is built with the mux, at
//! the composition root, and dropped with it.

use std::sync::{Arc, OnceLock, Weak};

use cmux_threads::work::{Lane, Priority, Refused, Shutdown, Work, WorkConfig};

use super::Mux;

pub(crate) struct MuxWork {
    work: Work,
    /// The owning mux, bound once it is built. An item holds it weakly, so
    /// queued work never keeps a dropped mux alive.
    mux: OnceLock<Weak<Mux>>,
}

impl MuxWork {
    pub(super) fn new() -> std::io::Result<Self> {
        let work = Work::new(WorkConfig { label: "mux-work".to_owned(), ..WorkConfig::default() })?;
        Ok(Self { work, mux: OnceLock::new() })
    }

    pub(super) fn bind(&self, mux: Weak<Mux>) {
        let _ = self.mux.set(mux);
    }

    /// Queues `body` with the mux. It does not run once the mux is gone.
    pub(super) fn post(
        &self,
        priority: Priority,
        lane: Lane,
        shutdown: Shutdown,
        body: impl FnOnce(&Arc<Mux>) + Send + 'static,
    ) -> Result<(), Refused> {
        let mux = self.mux.get().cloned().ok_or(Refused)?;
        self.work.post(priority, lane, shutdown, move || {
            if let Some(mux) = mux.upgrade() {
                body(&mux);
            }
        })
    }
}

/// Runs `f` on a new thread that disallows blocking, in the detector's panic
/// mode: the test stand-in for a request thread (`CMUX_DAEMON_BLOCKING=panic`).
/// `Err` is the panic of a blocking call `f` reached.
#[cfg(test)]
pub(crate) fn on_request_thread_in_panic_mode<R: Send + 'static>(
    f: impl FnOnce() -> R + Send + 'static,
) -> std::thread::Result<R> {
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
    let request = std::thread::Builder::new()
        .name("test-request".to_owned())
        .spawn(move || {
            cmux_threads::disallow_blocking();
            f()
        })
        .expect("spawn the request thread");
    cmux_threads::checked::sync::join(request)
}
