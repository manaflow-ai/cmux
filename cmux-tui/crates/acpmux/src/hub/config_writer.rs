//! The daemon's own settings files (`config.json`, `start-mode.json`) reach the disk on one
//! background thread (plans/cmux-next/perf-lead.md D1). A pick (a model, an effort, a
//! permission mode), the default policy, a preset, a peer or the web token used to write
//! `config.json` in place, two fsyncs (F_FULLFSYNC on macOS) while holding the config write
//! lock: every request that reads the config (a prompt's `child_for`, `session/new`, a
//! permission answer, `_acpmux/harnesses`) waited 20-50 ms behind it.
//!
//! The caller now makes the file's bytes under its lock (`Config::disk_bytes`) and queues them;
//! the thread writes the newest bytes of each file with `write_atomic`, so a burst of picks is
//! one write and the file never goes back to an older state. `flush` waits for what is queued
//! before it: before the daemon reads `config.json` back (`reload_catalog`) and at shutdown. It
//! never waits for an empty queue: bytes queued after it began never hold it.

use crate::daemon::hang_watch::{SyncThread, WRITE_ITEM};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};

use crate::supervised::{Fatal, OwnedThread, ShutdownBehavior, Supervisor};

#[derive(Default)]
struct State {
    queued: HashMap<PathBuf, Vec<u8>>,
    writing: bool,
    /// Files queued so far: each `queue` takes the next number as its ticket.
    tickets: u64,
    /// The last ticket of the batch being written: a batch takes everything queued.
    writing_ticket: u64,
    /// The last ticket written. A wait up to ticket `t` is over once `done >= t`.
    done: u64,
    stop: bool,
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    work: Condvar,
    written: Condvar,
}

/// What runs on the writer thread before each batch is written ([`ConfigWriter::start_with_hook`]).
pub(crate) type WriteHook = Arc<dyn Fn() + Send + Sync>;

/// The writer thread's name, also its name in a hang record.
const THREAD: &str = "acpmux-config-writer";

pub(crate) struct ConfigWriter {
    shared: Arc<Shared>,
    thread: Mutex<Option<OwnedThread>>,
}

impl ConfigWriter {
    /// Starts the writer thread under `supervisor`.
    pub(crate) fn start(supervisor: &Supervisor) -> Self {
        Self::start_with_hook(supervisor, None)
    }

    /// [`Self::start`]; `before_write` runs on the writer thread before each batch is written
    /// (a test queues the next bytes there, so the queue is never empty when a batch ends).
    pub(crate) fn start_with_hook(
        supervisor: &Supervisor,
        before_write: Option<WriteHook>,
    ) -> Self {
        let shared = Arc::new(Shared::default());
        let worker = shared.clone();
        // A panic in the thread leaves its queue half-written and every `flush` waiting:
        // Fatal. Continue on shutdown: the owner's drop writes what is queued and joins it.
        let thread = crate::supervised::owned_thread(
            supervisor,
            THREAD,
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || run(&worker, before_write.as_deref()),
        )
        .map_err(|e| {
            tracing::error!("the config writer did not start; files are written in place: {e}")
        })
        .ok();
        Self { shared, thread: Mutex::new(thread) }
    }

    /// Queues `bytes` as the next content of `path`, replacing older queued bytes of it.
    pub(crate) fn queue(&self, path: PathBuf, bytes: Vec<u8>) {
        if !self.running() {
            write(&path, &bytes);
            return;
        }
        let mut state = self.lock();
        state.tickets += 1;
        state.queued.insert(path, bytes);
        self.shared.work.notify_one();
    }

    /// Waits until everything queued before this call is on disk: at most the batch in progress
    /// and the next one. Bytes queued after it began never hold it.
    pub(crate) fn flush(&self) {
        let mut state = self.lock();
        let ticket = state.tickets;
        while self.running() && state.done < ticket {
            state = cmux_blocking::sync::wait(&self.shared.written, state)
                .unwrap_or_else(|e| e.into_inner());
        }
    }

    fn running(&self) -> bool {
        self.thread.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.shared.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Drop for ConfigWriter {
    /// Writes what is queued, then ends the thread.
    fn drop(&mut self) {
        self.lock().stop = true;
        self.shared.work.notify_one();
        if let Some(thread) = self.thread.get_mut().unwrap_or_else(|e| e.into_inner()).take() {
            cmux_blocking::scoped_blocking_call(
                "thread::join",
                cmux_blocking::BlockingKind::Join,
                || thread.join(),
            );
        }
    }
}

fn run(shared: &Shared, before_write: Option<&(dyn Fn() + Send + Sync)>) {
    let watched = SyncThread::register(THREAD, WRITE_ITEM);
    let mut state = shared.state.lock().unwrap_or_else(|e| e.into_inner());
    loop {
        if state.queued.is_empty() {
            if state.stop {
                return;
            }
            state =
                cmux_blocking::sync::wait(&shared.work, state).unwrap_or_else(|e| e.into_inner());
            continue;
        }
        let batch = std::mem::take(&mut state.queued);
        state.writing = true;
        state.writing_ticket = state.tickets;
        drop(state);
        if let Some(hook) = before_write {
            hook();
        }
        for (path, bytes) in batch {
            let _item = watched.item();
            write(&path, &bytes);
        }
        state = shared.state.lock().unwrap_or_else(|e| e.into_inner());
        state.writing = false;
        state.done = state.writing_ticket;
        shared.written.notify_all();
    }
}

fn write(path: &std::path::Path, bytes: &[u8]) {
    let result = path
        .parent()
        .map_or(Ok(()), crate::config::private_state_dir)
        .and_then(|()| crate::config::write_atomic(path, bytes));
    if let Err(e) = result {
        tracing::warn!(file = %path.display(), "not saved: {e:#}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_newest_bytes_of_a_file_win_and_flush_waits_for_them() {
        let dir = std::env::temp_dir().join(format!("acpmux-cfgw-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.json");
        let writer = ConfigWriter::start(&crate::supervised::embedded());
        for i in 0..50 {
            writer.queue(path.clone(), format!("{{\"n\":{i}}}").into_bytes());
        }
        writer.flush();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{\"n\":49}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
