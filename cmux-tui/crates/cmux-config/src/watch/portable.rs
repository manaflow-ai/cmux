//! notify's recommended watcher on platforms other than Linux and macOS
//! (Windows directory changes, kqueue on the BSDs). These backends report no
//! opens or reads; the callback still drops every event that is not about a
//! watched name, on notify's own thread, so changes to unrelated entries of
//! a watched directory never wake the watch thread. notify's non-recursive
//! watch reports a directory's own entries only.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher as _};

use super::{MAX_DELAY, Plan, QUIET};

type Shared = Arc<Mutex<Option<RecommendedWatcher>>>;

enum Message {
    Event,
    Stop,
}

pub(super) struct Handle {
    inner: Shared,
    stop: Sender<Message>,
    thread: Option<JoinHandle<()>>,
}

pub(super) fn start(
    files: Vec<PathBuf>,
    mut on_hint: impl FnMut() + Send + 'static,
) -> notify::Result<Handle> {
    let (sender, receiver) = channel::<Message>();
    let stop = sender.clone();
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
            let _ = sender.send(Message::Event);
        }
    })?;
    let inner: Shared = Arc::new(Mutex::new(Some(watcher)));
    let mut watched = BTreeSet::new();
    rearm(&inner, &plan, &files, &mut watched)?;
    let shared = Arc::clone(&inner);
    let thread = std::thread::Builder::new()
        .name("cmux-config-watch".to_string())
        .spawn(move || {
            on_hint();
            run(&receiver, &shared, &plan, &files, &mut watched, &mut on_hint);
        })
        .map_err(|error| notify::Error::generic(&error.to_string()))?;
    Ok(Handle { inner, stop, thread: Some(thread) })
}

impl Drop for Handle {
    fn drop(&mut self) {
        let _ = self.stop.send(Message::Stop);
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

fn run(
    receiver: &Receiver<Message>,
    shared: &Shared,
    plan: &Mutex<Plan>,
    files: &[PathBuf],
    watched: &mut BTreeSet<PathBuf>,
    on_hint: &mut impl FnMut(),
) {
    while let Ok(Message::Event) = receiver.recv() {
        // One hint per burst: wait until the events stop for QUIET.
        let started = Instant::now();
        loop {
            let left = MAX_DELAY.saturating_sub(started.elapsed()).min(QUIET);
            if left.is_zero() {
                break;
            }
            match receiver.recv_timeout(left) {
                Ok(Message::Event) => {}
                Ok(Message::Stop) | Err(RecvTimeoutError::Disconnected) => return,
                Err(RecvTimeoutError::Timeout) => break,
            }
        }
        // A directory that appeared or vanished moves the watch.
        let _ = rearm(shared, plan, files, watched);
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
    plan: &Mutex<Plan>,
    files: &[PathBuf],
    watched: &mut BTreeSet<PathBuf>,
) -> notify::Result<()> {
    let next = Plan::of(files);
    let wanted: BTreeSet<PathBuf> = next.0.keys().cloned().collect();
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
        Some(error) if watched.is_empty() => Err(error),
        _ => Ok(()),
    }
}
