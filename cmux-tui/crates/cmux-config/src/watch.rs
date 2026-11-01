//! Kernel file events for cmux.json and the managed files (no polling).
//!
//! Editors save in place, by atomic rename, or by delete and recreate, so
//! the watcher observes each file's directory, not the file. While a
//! directory does not exist it watches the nearest existing ancestor for
//! the next missing directory and moves down as directories appear.
//!
//! Only content changes of the watched files count: a create, a delete, a
//! rename, a close after a write and a metadata change of a watched name
//! (or a missing directory on the way to one appearing or vanishing).
//! Opens, reads and read-only closes never count: the reload a hint
//! triggers reads the watched file, and a watched ancestor such as /etc
//! sees an open on every process start. Events that arrive within
//! [`QUIET`] of each other are one burst and give one hint; the consumer
//! then reads the latest state (the owner's `reload` reports a change only
//! when the effective settings changed).
//!
//! Linux uses inotify directly with masks that leave out opens and reads
//! (`inotify.rs`), so the kernel queues nothing for unrelated opens. macOS
//! uses kqueue vnode watches directly (`kqueue.rs`): a watch of each
//! directory's entries and of each watched regular file. FSEvents is not
//! used there: it reports no Unix socket being bound (the daemon watches
//! acpmux's socket with this), runs late under load, and reports every
//! change below a directory. Other platforms use notify's recommended
//! watcher, which reports no opens; its callback drops every event that is
//! not about a watched name before it reaches the watch thread
//! (`portable.rs`).

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::owner::ConfigStore;
use crate::store::Change;

#[cfg(target_os = "linux")]
mod inotify;
#[cfg(target_os = "linux")]
use inotify as backend;
#[cfg(target_os = "macos")]
mod kqueue;
#[cfg(target_os = "macos")]
use kqueue as backend;
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod portable;
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
use portable as backend;

/// A burst ends after this long without another event.
const QUIET: Duration = Duration::from_millis(100);
/// A burst that keeps going still gives a hint after this long.
const MAX_DELAY: Duration = Duration::from_millis(1000);

/// A running watch. Dropping it stops the watch and joins its thread.
pub struct Watcher {
    _backend: backend::Handle,
}

impl Watcher {
    /// Watches `files` and calls `on_hint` on the watcher's own thread: once
    /// right after the watch is armed (so a save between the consumer's
    /// first read and arming is not missed), then once per burst of content
    /// changes of a watched file or of one of its missing ancestors.
    pub fn start(
        files: Vec<PathBuf>,
        on_hint: impl FnMut() + Send + 'static,
    ) -> notify::Result<Watcher> {
        Ok(Watcher { _backend: backend::start(files, on_hint)? })
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

/// The directories to watch (canonical) and, in each, the entry names whose
/// changes matter.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Plan(BTreeMap<PathBuf, Interest>);

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Interest {
    /// Watched files in this directory, and missing directories on the way
    /// to a watched file.
    names: BTreeSet<OsString>,
    /// The directory holds a watched file (it is not only the nearest
    /// existing ancestor of a missing directory).
    holds_file: bool,
}

impl Plan {
    /// Each file's own directory, or for a missing directory its nearest
    /// existing ancestor with the next missing name.
    fn of(files: &[PathBuf]) -> Plan {
        let mut plan = Plan::default();
        for file in files {
            let (Some(parent), Some(name)) = (file.parent(), file.file_name()) else { continue };
            let mut directory = normalize(parent);
            let mut child = name.to_os_string();
            let mut holds_file = true;
            loop {
                if directory.is_dir() {
                    let interest = plan.0.entry(directory).or_default();
                    interest.names.insert(child);
                    interest.holds_file |= holds_file;
                    break;
                }
                let Some(name) = directory.file_name().map(OsString::from) else { break };
                if !directory.pop() {
                    break;
                }
                child = name;
                holds_file = false;
            }
        }
        plan
    }

    /// `path` is a watched name in a watched directory, or a watched
    /// directory itself (it was removed or renamed).
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    fn matches(&self, path: &Path) -> bool {
        if self.0.contains_key(path) {
            return true;
        }
        match (path.parent(), path.file_name()) {
            // macOS and Windows volumes are usually case-insensitive: an
            // event names the entry as it is on disk.
            (Some(parent), Some(name)) => self.0.get(parent).is_some_and(|interest| {
                interest.names.iter().any(|watched| {
                    watched.as_os_str() == name
                        || watched.to_string_lossy().eq_ignore_ascii_case(&name.to_string_lossy())
                })
            }),
            _ => false,
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
