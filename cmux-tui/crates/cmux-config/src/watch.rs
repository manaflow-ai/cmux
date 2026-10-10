//! Kernel file events for cmux.json and the managed files (no polling).
//!
//! Editors save in place, by atomic rename, or by delete and recreate, so
//! the watcher observes each file's directory, not the file. While a
//! directory does not exist it watches the nearest existing ancestor and
//! moves down as directories appear. Events that arrive together are
//! coalesced into one hint; the consumer then reads the latest state (the
//! owner's `reload` reports a change only when the effective settings
//! changed).

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher as _};

use crate::owner::ConfigStore;
use crate::store::Change;

type Shared = Arc<Mutex<Option<RecommendedWatcher>>>;

enum Message {
    Event(notify::Result<Event>),
    Stop,
}

/// A running watch. Dropping it stops the watch and joins its thread.
pub struct Watcher {
    inner: Shared,
    stop: Sender<Message>,
    thread: Option<JoinHandle<()>>,
}

impl Watcher {
    /// Watches `files` and calls `on_hint` on the watcher's own thread: once
    /// right after the watch is armed (so a save between the consumer's
    /// first read and arming is not missed), then once per burst of events
    /// that touch a watched file or one of its missing ancestors.
    pub fn start(
        files: Vec<PathBuf>,
        mut on_hint: impl FnMut() + Send + 'static,
    ) -> notify::Result<Watcher> {
        let (sender, receiver) = channel::<Message>();
        let stop = sender.clone();
        let watcher = notify::recommended_watcher(move |event| {
            let _ = sender.send(Message::Event(event));
        })?;
        let inner: Shared = Arc::new(Mutex::new(Some(watcher)));
        let mut watched = BTreeSet::new();
        rearm(&inner, &files, &mut watched)?;
        let shared = Arc::clone(&inner);
        let thread = std::thread::Builder::new()
            .name("cmux-config-watch".to_string())
            .spawn(move || {
                on_hint();
                run(&receiver, &shared, &files, &mut watched, &mut on_hint);
            })
            .map_err(|error| notify::Error::generic(&error.to_string()))?;
        Ok(Watcher { inner, stop, thread: Some(thread) })
    }
}

impl Drop for Watcher {
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

/// Watches `store`'s files and reloads it on every hint; `on_change` gets
/// each change the reload reports (only when the effective settings changed).
/// Do not drop the returned watcher while holding `store`'s lock: the drop
/// joins the watch thread, which may be waiting for that lock.
pub fn watch_store(
    store: Arc<Mutex<ConfigStore>>,
    mut on_change: impl FnMut(Change) + Send + 'static,
) -> notify::Result<Watcher> {
    let paths = store.lock().map(|store| store.watch_paths()).unwrap_or_default();
    Watcher::start(paths, move || {
        let change = store.lock().ok().and_then(|mut store| store.reload());
        if let Some(change) = change {
            on_change(change);
        }
    })
}

fn run(
    receiver: &Receiver<Message>,
    shared: &Shared,
    files: &[PathBuf],
    watched: &mut BTreeSet<PathBuf>,
    on_hint: &mut impl FnMut(),
) {
    while let Ok(Message::Event(first)) = receiver.recv() {
        let mut burst = vec![first];
        for message in receiver.try_iter() {
            match message {
                Message::Event(event) => burst.push(event),
                Message::Stop => return,
            }
        }
        let targets: Vec<PathBuf> = files.iter().map(|file| normalize(file)).collect();
        let relevant = burst.iter().any(|event| match event {
            Err(_) => true,
            Ok(event) => {
                event.need_rescan()
                    || event.paths.iter().any(|path| touches(&normalize(path), &targets))
            }
        });
        // A directory that appeared or vanished moves the watch.
        let _ = rearm(shared, files, watched);
        if relevant {
            on_hint();
        }
    }
}

/// The event path is a target, or an ancestor directory of one.
fn touches(path: &Path, targets: &[PathBuf]) -> bool {
    targets.iter().any(|target| target == path || target.starts_with(path))
}

/// Points the watches at the nearest existing directory of every file.
fn rearm(
    shared: &Shared,
    files: &[PathBuf],
    watched: &mut BTreeSet<PathBuf>,
) -> notify::Result<()> {
    let wanted: BTreeSet<PathBuf> =
        files.iter().filter_map(|file| nearest_existing_dir(file)).collect();
    if wanted == *watched {
        return Ok(());
    }
    let Ok(mut guard) = shared.lock() else { return Ok(()) };
    let Some(watcher) = guard.as_mut() else { return Ok(()) };
    for gone in watched.difference(&wanted) {
        let _ = watcher.unwatch(gone);
    }
    let mut result = Ok(());
    for added in wanted.difference(watched) {
        if let Err(error) = watcher.watch(added, RecursiveMode::NonRecursive) {
            result = Err(error);
        }
    }
    *watched = wanted;
    result
}

/// The file's directory, or its nearest existing ancestor (canonical).
fn nearest_existing_dir(file: &Path) -> Option<PathBuf> {
    let mut directory = file.parent()?.to_path_buf();
    loop {
        if directory.is_dir() {
            return directory.canonicalize().ok();
        }
        if !directory.pop() {
            return None;
        }
    }
}

/// `path` with its nearest existing ancestor canonicalized (macOS reports
/// `/private/var/...` for `/var/...`), so event and target paths compare.
fn normalize(path: &Path) -> PathBuf {
    let mut existing = path.to_path_buf();
    let mut rest: Vec<PathBuf> = Vec::new();
    loop {
        if let Ok(canonical) = existing.canonicalize() {
            return rest.iter().rev().fold(canonical, |base, part| base.join(part));
        }
        match (existing.file_name().map(PathBuf::from), existing.parent()) {
            (Some(name), Some(parent)) => {
                rest.push(name);
                existing = parent.to_path_buf();
            }
            _ => return path.components().filter(|c| !matches!(c, Component::CurDir)).collect(),
        }
    }
}
