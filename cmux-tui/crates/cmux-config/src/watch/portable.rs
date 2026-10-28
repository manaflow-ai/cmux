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
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
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

enum Message {
    Event,
    Stop,
}

pub(super) struct Handle {
    inner: Shared,
    _ancestors: Ancestors,
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
    #[cfg(target_os = "macos")]
    let ancestors: Ancestors = {
        let sender = stop.clone();
        Arc::new(
            super::ancestors::Ancestors::start(move || {
                let _ = sender.send(Message::Event);
            })
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
    // supervise-allow: owned by Handle, which keeps it and joins it at drop; a panic ends config change hints only, and the loaded config stays in effect.
    let thread = cmux_threads::spawn("cmux-config-watch", super::WATCH_THREAD_QOS, move || {
        on_hint();
        run(&receiver, &shared, &thread_ancestors, &plan, &files, &mut watched, &mut on_hint);
    })
    .map_err(|error| notify::Error::generic(&error.to_string()))?;
    Ok(Handle { inner, _ancestors: ancestors, stop, thread: Some(thread) })
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
    ancestors: &Ancestors,
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
