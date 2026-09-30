//! Non-recursive directory watches for `workspace-watch-v1`.
//!
//! A client registers workspace-relative directories and long-polls for the
//! ones whose direct entries changed. One lazily created kernel watcher serves
//! every watch in the daemon, so clients cannot exhaust per-user inotify
//! instances. Kernel registrations are reference counted per canonical
//! directory because the backend keeps a single registration per path.
//!
//! Lock order: `backend` before `registry` before a watch's `changes`. The
//! notify callback takes only `registry` and `changes`, and no code calls into
//! the backend while holding `registry`. Backend calls can wait for the
//! callback thread, so that rule is what keeps them deadlock-free.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use cmux_remote_protocol::{RpcError, WorkspaceId, WorkspaceResponse};
use notify::{EventKind, RecursiveMode, Watcher as _};
use tokio::sync::watch;

use super::ClientScope;

pub(super) const MAX_WATCH_PATHS: usize = 512;
pub(super) const MAX_WATCHES_PER_CLIENT: usize = 16;
const MAX_POLL_WAIT: Duration = Duration::from_secs(30);
/// After the first change wakes a poll, wait this long to batch a burst.
const COALESCE_WINDOW: Duration = Duration::from_millis(50);

#[derive(Default)]
pub(super) struct WatchManager {
    backend: Mutex<Option<notify::RecommendedWatcher>>,
    registry: Arc<Mutex<WatchRegistry>>,
}

#[derive(Default)]
struct WatchRegistry {
    watches: HashMap<String, Arc<DirectoryWatch>>,
    owners: HashMap<ClientScope, HashSet<String>>,
    /// Canonical directory to (watch id to the protocol paths it names).
    directories: HashMap<PathBuf, HashMap<String, Vec<String>>>,
}

struct DirectoryWatch {
    owner: ClientScope,
    workspace: WorkspaceId,
    directories: Vec<PathBuf>,
    changes: Mutex<WatchChanges>,
    wakeup: watch::Sender<u64>,
}

#[derive(Default)]
struct WatchChanges {
    sequence: u64,
    /// Protocol path to the latest sequence that changed it.
    changed: HashMap<String, u64>,
    overflow: u64,
    removed: bool,
}

pub(super) enum WatchSelection {
    All,
    Owner(ClientScope),
    OwnerWorkspace(ClientScope, WorkspaceId),
}

impl WatchSelection {
    fn matches(&self, watch: &DirectoryWatch) -> bool {
        match self {
            Self::All => true,
            Self::Owner(owner) => &watch.owner == owner,
            Self::OwnerWorkspace(owner, workspace) => {
                &watch.owner == owner && &watch.workspace == workspace
            }
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn unknown_watch(watch: &str) -> RpcError {
    RpcError::new("unknown-watch", format!("unknown watch {watch}"))
}

impl DirectoryWatch {
    fn record<'a>(&self, paths: impl IntoIterator<Item = &'a String>, overflow: bool) {
        let sequence = {
            let mut changes = lock(&self.changes);
            if changes.removed {
                return;
            }
            changes.sequence += 1;
            let sequence = changes.sequence;
            for path in paths {
                changes.changed.insert(path.clone(), sequence);
            }
            if overflow {
                changes.overflow = sequence;
            }
            sequence
        };
        self.wakeup.send_replace(sequence);
    }

    fn mark_removed(&self) {
        let sequence = {
            let mut changes = lock(&self.changes);
            changes.removed = true;
            changes.sequence
        };
        self.wakeup.send_replace(sequence);
    }

    /// `Ok(true)` when changes after `after` exist, `Err` once removed.
    fn ready(&self, watch: &str, after: u64) -> Result<bool, RpcError> {
        let changes = lock(&self.changes);
        if changes.removed {
            return Err(unknown_watch(watch));
        }
        Ok(changes.sequence > after)
    }

    fn snapshot(&self, watch: &str, after: u64) -> Result<WorkspaceResponse, RpcError> {
        let changes = lock(&self.changes);
        if changes.removed {
            return Err(unknown_watch(watch));
        }
        let mut paths = changes
            .changed
            .iter()
            .filter(|(_, sequence)| **sequence > after)
            .map(|(path, _)| path.clone())
            .collect::<Vec<_>>();
        paths.sort_unstable();
        Ok(WorkspaceResponse::WatchChanges {
            sequence: changes.sequence,
            paths,
            overflow: changes.overflow > after,
        })
    }
}

fn dispatch(registry: &Mutex<WatchRegistry>, event: notify::Result<notify::Event>) {
    let registry = lock(registry);
    let event = match event {
        Ok(event) if !event.need_rescan() => event,
        // A backend error or queue overflow can hide any change. Clients
        // reload every watched directory when they see `overflow`.
        _ => {
            for watch in registry.watches.values() {
                watch.record(std::iter::empty(), true);
            }
            return;
        }
    };
    // Opening a directory to list it is an access event. Reporting it would
    // make every client reload loop on its own listing.
    if matches!(event.kind, EventKind::Access(_)) {
        return;
    }
    let mut touched = HashMap::<&str, HashSet<&String>>::new();
    for path in &event.paths {
        let candidates = [path.parent(), Some(path.as_path())];
        for directory in candidates.into_iter().flatten() {
            let Some(subscribers) = registry.directories.get(directory) else { continue };
            for (watch, paths) in subscribers {
                touched.entry(watch.as_str()).or_default().extend(paths);
            }
        }
    }
    for (watch, paths) in touched {
        if let Some(watch) = registry.watches.get(watch) {
            watch.record(paths, false);
        }
    }
}

fn notify_error(directory: &Path, error: notify::Error) -> RpcError {
    match error.kind {
        notify::ErrorKind::MaxFilesWatch => RpcError::new(
            "limit-exceeded",
            format!("watch-directories {}: kernel watch limit reached", directory.display()),
        ),
        notify::ErrorKind::PathNotFound => RpcError::new(
            "not-found",
            format!("watch-directories {}: directory not found", directory.display()),
        ),
        notify::ErrorKind::Io(error) if is_kernel_limit(&error) => RpcError::new(
            "limit-exceeded",
            format!("watch-directories {}: {error}", directory.display()),
        ),
        notify::ErrorKind::Io(error) => {
            super::path::io_error("watch-directories", directory, error)
        }
        kind => RpcError::new(
            "io-error",
            format!("watch-directories {}: {kind:?}", directory.display()),
        ),
    }
}

#[cfg(unix)]
fn is_kernel_limit(error: &std::io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ENOSPC | libc::EMFILE | libc::ENFILE))
}

#[cfg(not(unix))]
fn is_kernel_limit(_error: &std::io::Error) -> bool {
    false
}

impl WatchManager {
    /// Publish a watch over resolved `(protocol path, canonical directory)`
    /// pairs. Runs on a blocking thread because kernel registration blocks.
    pub(super) fn watch(
        &self,
        owner: &ClientScope,
        workspace: WorkspaceId,
        directories: Vec<(String, PathBuf)>,
    ) -> Result<String, RpcError> {
        if directories.len() > MAX_WATCH_PATHS {
            return Err(limit_exceeded_paths());
        }
        let mut backend = lock(&self.backend);
        let id = uuid::Uuid::new_v4().to_string();
        let mut grouped = HashMap::<PathBuf, Vec<String>>::new();
        for (path, directory) in directories {
            let paths = grouped.entry(directory).or_default();
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
        // Subscribe before registering kernel watches so no event that the
        // kernel reports after registration can miss this watch.
        let new_directories = {
            let mut registry = lock(&self.registry);
            let owned = registry.owners.get(owner).map_or(0, HashSet::len);
            if owned >= MAX_WATCHES_PER_CLIENT {
                return Err(RpcError::new(
                    "limit-exceeded",
                    format!("a client may hold at most {MAX_WATCHES_PER_CLIENT} live watches"),
                ));
            }
            let mut new_directories = Vec::new();
            for (directory, paths) in &grouped {
                let subscribers = registry.directories.entry(directory.clone()).or_default();
                if subscribers.is_empty() {
                    new_directories.push(directory.clone());
                }
                subscribers.insert(id.clone(), paths.clone());
            }
            let (wakeup, _) = watch::channel(0);
            registry.watches.insert(
                id.clone(),
                Arc::new(DirectoryWatch {
                    owner: owner.clone(),
                    workspace,
                    directories: grouped.into_keys().collect(),
                    changes: Mutex::new(WatchChanges::default()),
                    wakeup,
                }),
            );
            registry.owners.entry(owner.clone()).or_default().insert(id.clone());
            new_directories
        };
        if let Err(error) = self.register(&mut backend, &new_directories) {
            self.remove_locked(&mut backend, |watch_id, _| watch_id == id);
            return Err(error);
        }
        Ok(id)
    }

    fn register(
        &self,
        backend: &mut Option<notify::RecommendedWatcher>,
        directories: &[PathBuf],
    ) -> Result<(), RpcError> {
        if backend.is_none() {
            let registry = Arc::clone(&self.registry);
            let watcher = notify::recommended_watcher(move |event| dispatch(&registry, event))
                .map_err(|error| notify_error(Path::new(""), error))?;
            *backend = Some(watcher);
        }
        let Some(watcher) = backend.as_mut() else {
            return Err(RpcError::new("internal", "directory watch backend is unavailable"));
        };
        for directory in directories {
            watcher
                .watch(directory, RecursiveMode::NonRecursive)
                .map_err(|error| notify_error(directory, error))?;
        }
        Ok(())
    }

    /// Remove matching watches and release kernel registrations nobody else
    /// uses. Runs on a blocking thread.
    pub(super) fn remove(&self, selection: &WatchSelection) {
        let mut backend = lock(&self.backend);
        self.remove_locked(&mut backend, |_, watch| selection.matches(watch));
    }

    pub(super) fn remove_id(&self, id: &str) {
        let mut backend = lock(&self.backend);
        self.remove_locked(&mut backend, |watch_id, _| watch_id == id);
    }

    fn remove_locked(
        &self,
        backend: &mut Option<notify::RecommendedWatcher>,
        selected: impl Fn(&str, &DirectoryWatch) -> bool,
    ) {
        let orphaned = self.unpublish(selected);
        if let Some(watcher) = backend.as_mut() {
            for directory in orphaned {
                // A directory that failed to register or was deleted has no
                // kernel watch left to remove.
                let _ = watcher.unwatch(&directory);
            }
        }
    }

    pub(super) fn contains(&self, selection: &WatchSelection) -> bool {
        lock(&self.registry).watches.values().any(|watch| selection.matches(watch))
    }

    /// Unpublish matching watches. Returns directories left without any
    /// subscriber; the caller holds `backend` and unregisters them.
    fn unpublish(&self, selected: impl Fn(&str, &DirectoryWatch) -> bool) -> Vec<PathBuf> {
        let mut registry = lock(&self.registry);
        let ids = registry
            .watches
            .iter()
            .filter(|(id, watch)| selected(id.as_str(), watch.as_ref()))
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        let mut orphaned = Vec::new();
        for id in ids {
            let Some(watch) = registry.watches.remove(&id) else { continue };
            if let Some(owned) = registry.owners.get_mut(&watch.owner) {
                owned.remove(&id);
                if owned.is_empty() {
                    registry.owners.remove(&watch.owner);
                }
            }
            for directory in &watch.directories {
                if let Some(subscribers) = registry.directories.get_mut(directory) {
                    subscribers.remove(&id);
                    if subscribers.is_empty() {
                        registry.directories.remove(directory);
                        orphaned.push(directory.clone());
                    }
                }
            }
            watch.mark_removed();
        }
        orphaned
    }

    pub(super) async fn poll(
        &self,
        id: &str,
        after: u64,
        timeout_ms: u32,
    ) -> Result<WorkspaceResponse, RpcError> {
        let watch =
            lock(&self.registry).watches.get(id).cloned().ok_or_else(|| unknown_watch(id))?;
        let mut wakeup = watch.wakeup.subscribe();
        let deadline = tokio::time::Instant::now()
            + Duration::from_millis(u64::from(timeout_ms)).min(MAX_POLL_WAIT);
        if !watch.ready(id, after)? {
            let arrived = tokio::time::timeout_at(deadline, async {
                loop {
                    // The watch owns the sender, and this poll owns the watch,
                    // so the channel cannot close while waiting.
                    if wakeup.changed().await.is_err() {
                        return;
                    }
                    if !matches!(watch.ready(id, after), Ok(false)) {
                        return;
                    }
                }
            })
            .await
            .is_ok();
            if arrived && watch.ready(id, after)? {
                let batch = tokio::time::Instant::now() + COALESCE_WINDOW;
                tokio::time::sleep_until(batch.min(deadline)).await;
            }
        }
        watch.snapshot(id, after)
    }
}

pub(super) fn limit_exceeded_paths() -> RpcError {
    RpcError::new(
        "limit-exceeded",
        format!("a watch may name at most {MAX_WATCH_PATHS} directories"),
    )
}
