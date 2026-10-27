//! notify's recommended watcher (macOS FSEvents, Windows directory changes,
//! kqueue elsewhere). These backends report no opens or reads; the callback
//! still drops every event that is not about a watched name, on notify's own
//! thread, so changes to unrelated entries of a watched directory (for
//! example under /Library while /Library/Managed Preferences is missing)
//! never wake the watch thread. FSEvents itself still wakes notify's thread
//! for every change under a watched directory, so on macOS a missing
//! directory's nearest ancestor (the only busy one) gets a kqueue vnode watch
//! instead (`ancestors.rs`), which fires only when its own entries change.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher as _};

use super::{MAX_DELAY, Plan, QUIET};

type Shared = Arc<Mutex<Option<RecommendedWatcher>>>;

#[cfg(target_os = "macos")]
type Ancestors = Arc<super::ancestors::Ancestors>;
/// Elsewhere notify's non-recursive watch reports only a directory's own
/// entries, so ancestors stay with it.
#[cfg(not(target_os = "macos"))]
type Ancestors = ();

/// A wake of the watch thread. One queued wake is enough: the thread reads
/// every hint's state after its burst, and checks `stopping` after each wake.
struct Wake;

/// Queues a wake without waiting: on a full queue a wake is already pending.
/// It runs on notify's event thread, which must never block.
fn wake(sender: &SyncSender<Wake>) {
    let _ = sender.try_send(Wake);
}

pub(super) struct Handle {
    inner: Shared,
    _ancestors: Ancestors,
    stop: SyncSender<Wake>,
    stopping: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

pub(super) fn start(
    files: Vec<PathBuf>,
    mut on_hint: impl FnMut() + Send + 'static,
) -> notify::Result<Handle> {
    let (sender, receiver) = sync_channel::<Wake>(1);
    let stop = sender.clone();
    let stopping = Arc::new(AtomicBool::new(false));
    let plan: Arc<Mutex<Plan>> = Arc::default();
    let filter = Arc::clone(&plan);
    let watcher = notify::recommended_watcher(move |event: notify::Result<Event>| {
        let relevant = match &event {
            Err(_) => true,
            Ok(event) => {
                event.need_rescan()
                    || (is_change(&event.kind)
                        && filter
                            .lock()
                            .is_ok_and(|plan| event.paths.iter().any(|path| plan.matches(path))))
            }
        };
        if relevant {
            wake(&sender);
        }
    })?;
    let inner: Shared = Arc::new(Mutex::new(Some(watcher)));
    #[cfg(target_os = "macos")]
    let ancestors: Ancestors = {
        let sender = stop.clone();
        Arc::new(
            super::ancestors::Ancestors::start(move || wake(&sender))
                .map_err(|error| notify::Error::generic(&error.to_string()))?,
        )
    };
    #[cfg(not(target_os = "macos"))]
    let ancestors: Ancestors = ();
    let mut watched = BTreeSet::new();
    rearm(&inner, &ancestors, &plan, &files, &mut watched)?;
    let shared = Arc::clone(&inner);
    #[cfg(target_os = "macos")]
    let thread_ancestors = Arc::clone(&ancestors);
    #[cfg(not(target_os = "macos"))]
    let thread_ancestors: Ancestors = ();
    let thread_stopping = Arc::clone(&stopping);
    let thread = std::thread::Builder::new()
        .name("cmux-config-watch".to_string())
        .spawn(move || {
            on_hint();
            let watch = Watch { receiver: &receiver, stopping: &thread_stopping };
            run(&watch, &shared, &thread_ancestors, &plan, &files, &mut watched, &mut on_hint);
        })
        .map_err(|error| notify::Error::generic(&error.to_string()))?;
    Ok(Handle { inner, _ancestors: ancestors, stop, stopping, thread: Some(thread) })
}

impl Drop for Handle {
    fn drop(&mut self) {
        // The flag before the wake: a wake that finds the queue full leaves
        // one queued, and the thread reads the flag after taking it.
        self.stopping.store(true, Ordering::Release);
        wake(&self.stop);
        if let Ok(mut guard) = self.inner.lock() {
            guard.take();
        }
        if let Some(thread) = self.thread.take() {
            // The last owner may drop the watcher from its own callback.
            if thread.thread().id() != std::thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

/// The watch thread's queue and its stop flag.
struct Watch<'a> {
    receiver: &'a Receiver<Wake>,
    stopping: &'a AtomicBool,
}

impl Watch<'_> {
    fn stopped(&self) -> bool {
        self.stopping.load(Ordering::Acquire)
    }
}

fn run(
    watch: &Watch<'_>,
    shared: &Shared,
    ancestors: &Ancestors,
    plan: &Mutex<Plan>,
    files: &[PathBuf],
    watched: &mut BTreeSet<PathBuf>,
    on_hint: &mut impl FnMut(),
) {
    while watch.receiver.recv().is_ok() && !watch.stopped() {
        // One hint per burst: wait until the events stop for QUIET.
        let started = Instant::now();
        loop {
            let left = MAX_DELAY.saturating_sub(started.elapsed()).min(QUIET);
            if left.is_zero() {
                break;
            }
            match watch.receiver.recv_timeout(left) {
                Ok(Wake) if watch.stopped() => return,
                Ok(Wake) => {}
                Err(RecvTimeoutError::Disconnected) => return,
                Err(RecvTimeoutError::Timeout) => break,
            }
        }
        // A directory that appeared or vanished moves the watch.
        let _ = rearm(shared, ancestors, plan, files, watched);
        on_hint();
    }
}

/// An event that can mean a file changed: everything but an open, a read or
/// a read-only close (a close after a write is a change).
fn is_change(kind: &notify::EventKind) -> bool {
    use notify::event::{AccessKind, AccessMode, EventKind};
    match kind {
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => true,
        EventKind::Access(_) => false,
        _ => true,
    }
}

/// Points the watches at the directories of the current plan.
fn rearm(
    shared: &Shared,
    ancestors: &Ancestors,
    plan: &Mutex<Plan>,
    files: &[PathBuf],
    watched: &mut BTreeSet<PathBuf>,
) -> notify::Result<()> {
    let next = Plan::of(files);
    // On macOS a directory that holds no watched file (a missing directory's
    // nearest ancestor) goes to the kqueue watch, never to FSEvents.
    let mut wanted = BTreeSet::new();
    let mut ancestor_dirs = BTreeSet::new();
    for (path, interest) in &next.0 {
        if interest.holds_file || cfg!(not(target_os = "macos")) {
            wanted.insert(path.clone());
        } else {
            ancestor_dirs.insert(path.clone());
        }
    }
    #[cfg(target_os = "macos")]
    let ancestors_armed = ancestors.set(&ancestor_dirs);
    #[cfg(not(target_os = "macos"))]
    let ancestors_armed = {
        let _ = (ancestors, &ancestor_dirs);
        0
    };
    if let Ok(mut current) = plan.lock() {
        *current = next;
    }
    if wanted == *watched {
        return Ok(());
    }
    let Ok(mut guard) = shared.lock() else { return Ok(()) };
    let Some(watcher) = guard.as_mut() else { return Ok(()) };
    for gone in watched.difference(&wanted) {
        let _ = watcher.unwatch(gone);
    }
    // A directory that cannot be watched (no permission) is skipped; the
    // error is returned only when no directory is watched.
    let mut first_error = None;
    let mut armed: BTreeSet<PathBuf> = wanted.intersection(watched).cloned().collect();
    for added in wanted.difference(watched) {
        match watcher.watch(added, RecursiveMode::NonRecursive) {
            Ok(()) => {
                armed.insert(added.clone());
            }
            Err(error) => {
                first_error.get_or_insert(error);
            }
        }
    }
    *watched = armed;
    match first_error {
        Some(error) if watched.is_empty() && ancestors_armed == 0 => Err(error),
        _ => Ok(()),
    }
}
