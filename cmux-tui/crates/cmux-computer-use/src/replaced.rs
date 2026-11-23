//! Hot upgrade of a running worker. The worker's executable can be replaced on disk while it
//! runs: on macOS a newer build swaps the signed helper into its one fixed path
//! (`cmux_signed_bundle::swap_into`, one `renamex_np`, so the grants stay), on Linux and Windows
//! an update replaces `cmux-tui`. The running process keeps the old code until something
//! restarts it; this is that something, with no relaunch of the cmux app or the daemon.
//!
//! Each call stats the executable (one `stat`, no watcher thread, nothing when no call comes).
//! Once the file at the path is not the one this process started from:
//!
//! 1. New calls are refused by closing their connection unanswered. The bridge retries a
//!    closed connection on the daemon's next worker with the same `call_id`, so the agent sees
//!    no error and the call runs once, on the new code.
//! 2. The calls already admitted (running, or queued behind one in their session's lane)
//!    finish on this worker: nothing is cut off mid-call.
//! 3. When the last of them ends, the drained hook runs, once: the worker tells the daemon
//!    (`{"type":"replaced"}`) and exits, and the daemon starts the new executable at once.
//!
//! A missing file is no replacement (an uninstall, a copy not yet in place): this worker keeps
//! serving.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::SystemTime;

/// What changes when the file at a path is replaced: its inode (a swap or a rename over it),
/// or its size and modification time (an in-place rewrite).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileId {
    dev: u64,
    ino: u64,
    len: u64,
    modified: Option<SystemTime>,
}

/// The identity of the file at `path` (following links), or None when there is none.
pub fn file_id(path: &Path) -> Option<FileId> {
    let meta = std::fs::metadata(path).ok()?;
    #[cfg(unix)]
    let (dev, ino) = {
        use std::os::unix::fs::MetadataExt;
        (meta.dev(), meta.ino())
    };
    #[cfg(not(unix))]
    let (dev, ino) = (0, 0);
    Some(FileId { dev, ino, len: meta.len(), modified: meta.modified().ok() })
}

#[derive(Default)]
struct State {
    /// Admitted calls not yet finished.
    running: usize,
    /// The executable was replaced: no new call is admitted.
    closing: bool,
    /// The drained hook ran.
    fired: bool,
}

/// One worker's watch on its own executable, and the gate every call passes.
pub struct Swap {
    path: PathBuf,
    started: Option<FileId>,
    state: Mutex<State>,
    drained: Box<dyn Fn() + Send + Sync>,
}

impl Swap {
    /// Watches `path`, as it is now, for this process. `drained` runs once, after the path
    /// was replaced and the last admitted call ended.
    pub fn new(path: PathBuf, drained: impl Fn() + Send + Sync + 'static) -> Arc<Self> {
        let started = file_id(&path);
        Arc::new(Self {
            path,
            started,
            state: Mutex::new(State::default()),
            drained: Box::new(drained),
        })
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Whether another file now sits at the path.
    pub fn replaced(&self) -> bool {
        self.started.is_some_and(|started| file_id(&self.path).is_some_and(|now| now != started))
    }

    /// Whether new calls are refused.
    pub fn closing(&self) -> bool {
        self.lock().closing
    }

    /// A call is about to be admitted: its ticket (held until the call ends), or None when
    /// this worker is being replaced (close the connection unanswered; the bridge retries on
    /// the new worker).
    pub fn enter(self: &Arc<Self>) -> Option<Ticket> {
        let replaced = !self.closing() && self.replaced();
        let fire = {
            let mut state = self.lock();
            if replaced {
                state.closing = true;
            }
            if !state.closing {
                state.running += 1;
                return Some(Ticket(Arc::clone(self)));
            }
            let fire = state.running == 0 && !state.fired;
            state.fired |= fire;
            fire
        };
        if fire {
            (self.drained)();
        }
        None
    }

    fn leave(&self) {
        let fire = {
            let mut state = self.lock();
            state.running = state.running.saturating_sub(1);
            let fire = state.closing && state.running == 0 && !state.fired;
            state.fired |= fire;
            fire
        };
        if fire {
            (self.drained)();
        }
    }
}

/// An admitted call; dropping it ends the call for [`Swap`].
pub struct Ticket(Arc<Swap>);

impl Drop for Ticket {
    fn drop(&mut self) {
        self.0.leave();
    }
}

#[cfg(test)]
#[path = "replaced_tests.rs"]
mod tests;
