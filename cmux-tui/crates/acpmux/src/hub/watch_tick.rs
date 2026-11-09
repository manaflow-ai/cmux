//! One check for every watched transcript (`watch.rs`), so a quiet watch costs no wakeup of its
//! own (Leo 2026-11-04: "never ... acceptable ... linear time growth degradation"). Each watch
//! used to wake 2.5 times a second and open and read its transcript on a blocking thread.
//!
//! One task, the hub's [`WatchTicker`], wakes every [`FAST`] while a transcript grew in the last
//! [`QUIET_AFTER`] (or a watch just started), and every [`SLOW`] after that. Each wake reads the
//! length of every watched transcript in one blocking call and wakes only the watches whose
//! transcript's length moved, or whose chat closed or stopped watching (they end). A watch reads
//! its transcript only then. A watch whose last read or start failed is woken at the next check
//! while its transcript exists ([`Registration::retry`]). The task ends when no watch is left (a
//! new watch starts it again) or the hub drops.

use super::super::{Session, SessionStatus};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::time::Instant;

/// How often the transcripts are checked while one grew lately.
pub(super) const FAST: Duration = Duration::from_millis(400);

/// How often they are checked once all were quiet for [`QUIET_AFTER`].
pub(super) const SLOW: Duration = Duration::from_secs(2);

/// How long the checks stay at [`FAST`] after a transcript grew or a watch started.
pub(super) const QUIET_AFTER: Duration = Duration::from_secs(30);

/// The hub's one check of its watched transcripts.
#[derive(Default)]
pub(crate) struct WatchTicker {
    state: Arc<State>,
}

#[derive(Default)]
struct State {
    watches: Mutex<Watches>,
    /// Set when the hub drops; `stopped` wakes the task to see it.
    stop: AtomicBool,
    stopped: Notify,
}

#[derive(Default)]
struct Watches {
    next: u64,
    by_key: HashMap<u64, Entry>,
    /// The task runs.
    running: bool,
    /// When a transcript last grew or a watch started.
    lively: Option<Instant>,
}

struct Entry {
    session: Weak<Session>,
    wake: Arc<Notify>,
    /// The transcript's length at the last check (`None`: missing or unreadable).
    seen: Option<u64>,
    /// Wake at the next check even if the length did not move.
    retry: bool,
}

impl Drop for WatchTicker {
    fn drop(&mut self) {
        self.state.stop.store(true, Ordering::SeqCst);
        self.state.stopped.notify_one();
    }
}

/// One watch's place in the check; dropping it leaves the check.
pub(super) struct Registration {
    state: Arc<State>,
    key: u64,
    wake: Arc<Notify>,
}

impl Registration {
    /// Until the transcript's length moved, the chat stopped watching, or a retry is due.
    pub(super) async fn wait(&self) {
        self.wake.notified().await;
    }

    /// The next check wakes this watch even if its transcript's length did not move, as long as
    /// the transcript exists: its read or its start failed.
    pub(super) fn retry(&self) {
        let mut watches = self.state.watches.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = watches.by_key.get_mut(&self.key) {
            entry.retry = true;
        }
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        let mut watches = self.state.watches.lock().unwrap_or_else(|e| e.into_inner());
        watches.by_key.remove(&self.key);
    }
}

impl WatchTicker {
    /// Adds `session`'s watch to the check, starting the check's task when it is not running.
    pub(super) fn register(&self, session: &Arc<Session>) -> Registration {
        let wake = Arc::new(Notify::new());
        let mut watches = self.state.watches.lock().unwrap_or_else(|e| e.into_inner());
        let key = watches.next;
        watches.next = watches.next.wrapping_add(1);
        watches.by_key.insert(
            key,
            Entry {
                session: Arc::downgrade(session),
                wake: wake.clone(),
                seen: None,
                retry: false,
            },
        );
        watches.lively = Some(Instant::now());
        if !watches.running {
            watches.running = true;
            tokio::spawn(run(self.state.clone()));
        }
        Registration { state: self.state.clone(), key, wake }
    }
}

/// The transcript `session` watches, or `None` when its watch is over.
fn watched_file(session: &Session) -> Option<PathBuf> {
    if session.purged.load(Ordering::SeqCst) {
        return None;
    }
    let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
    if meta.status == SessionStatus::Closed {
        return None;
    }
    meta.watching.as_ref().map(|w| w.file.clone())
}

async fn run(state: Arc<State>) {
    loop {
        let lively = {
            let mut watches = state.watches.lock().unwrap_or_else(|e| e.into_inner());
            if watches.by_key.is_empty() || state.stop.load(Ordering::SeqCst) {
                watches.running = false;
                return;
            }
            watches.lively
        };
        let every = if lively.is_some_and(|at| at.elapsed() < QUIET_AFTER) { FAST } else { SLOW };
        tokio::select! {
            _ = tokio::time::sleep(every) => {}
            _ = state.stopped.notified() => continue,
        }
        #[cfg(test)]
        super::idle_cost::wakeup();
        let (mut files, mut over) = (Vec::new(), Vec::new());
        {
            let watches = state.watches.lock().unwrap_or_else(|e| e.into_inner());
            for (key, entry) in &watches.by_key {
                match entry.session.upgrade().as_deref().and_then(watched_file) {
                    Some(file) => files.push((*key, file)),
                    None => over.push(entry.wake.clone()),
                }
            }
        }
        // The watch sees it is over and ends, dropping its registration.
        for wake in over {
            wake.notify_one();
        }
        if files.is_empty() {
            continue;
        }
        #[cfg(test)]
        super::idle_cost::blocking();
        let lengths = tokio::task::spawn_blocking(move || {
            files
                .into_iter()
                .map(|(key, file)| (key, std::fs::metadata(&file).ok().map(|m| m.len())))
                .collect::<Vec<_>>()
        })
        .await;
        let Ok(lengths) = lengths else { continue };
        let mut watches = state.watches.lock().unwrap_or_else(|e| e.into_inner());
        let mut grew = false;
        for (key, length) in lengths {
            let Some(entry) = watches.by_key.get_mut(&key) else { continue };
            let moved = entry.seen != length;
            let retry = std::mem::take(&mut entry.retry) && length.is_some();
            entry.seen = length;
            if moved || retry {
                entry.wake.notify_one();
            }
            grew |= moved;
        }
        if grew {
            watches.lively = Some(Instant::now());
        }
    }
}
