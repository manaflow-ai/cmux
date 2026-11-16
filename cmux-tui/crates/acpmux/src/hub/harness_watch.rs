//! Part of `Hub`; see `hub/mod.rs`. Harness profile hot reload
//! (BRING-YOUR-OWN-HARNESS H2, slice 2b).
//!
//! One non-recursive watch over the profile sources: the managed folders,
//! the user folder and cmux.json. Linux: inotify for changes only
//! (`quiet_dirs`), since notify asks for every open. Others: notify's watcher
//! (inotify). macOS: kqueue vnode events (`record_watch::DirWatch`) on the
//! folders and on each file in them, made again when the files change, and
//! a change counts only when what the sources hold changed (`sources_print`).
//! Not FSEvents: it goes through fseventsd, which falls behind a burst of
//! writes anywhere on the volume (a build, a full test run) by many seconds
//! or drops the events (cx-ckdxf), so a new profile was missed or its event
//! came seconds after another reload. The folder that holds the user folder is watched too, so a user folder that
//! `cmux harness add` creates later is picked up; nothing is created here. A
//! source folder whose path does not exist yet (no `~/.config/cmux`, no
//! `/etc/cmux/harnesses`) is watched through its nearest existing ancestor,
//! and each folder on the way as it is made (`nearest_folders`). On Linux the
//! watch follows paths (`quiet_dirs`): a source folder replaced with `mv` is
//! watched again, a source folder that is a link is followed to its target
//! (through the target's nearest existing ancestor while it is missing), and
//! a watch no longer needed is removed.
//! No timers and no polling: the event thread blocks until an event comes,
//! gathers the burst (debounce) and only signals. One task on the runtime
//! takes the signals and reloads the catalog one reload at a time
//! (`reload_catalog`, which keeps sessions), then tells `_acpmux/watch`
//! connections with `_acpmux/harnesses_changed {harnesses, diagnostics}`.
//! The thread never blocks on the runtime, so a runtime or hub that ends
//! during a burst ends both cleanly: the task stops with the runtime or when
//! the hub's watch state drops, and the thread ends when the watcher drops.

use super::*;

use std::path::{Path, PathBuf};
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
use notify::Watcher as _;

use crate::config::ProfileSources;

/// A burst ends after this much quiet...
pub(super) const QUIET: Duration = Duration::from_millis(200);
/// ...or after this long.
pub(super) const MAX_BURST: Duration = Duration::from_secs(2);

/// The hub's profile hot-reload state: the live watcher and the change feed
/// that `_acpmux/watch` connections forward.
pub(crate) struct HarnessWatchState {
    watcher: StdMutex<Option<Arc<HarnessWatcher>>>,
    changes: broadcast::Sender<Value>,
    /// The task that runs the reloads the watcher thread signals.
    reloader: StdMutex<Option<tokio::task::JoinHandle<()>>>,
    /// Peer state notes and their own feed (`Hub::peer_states`).
    peer_states: std::sync::OnceLock<Arc<crate::peer_states::PeerStates>>,
}

impl Default for HarnessWatchState {
    fn default() -> Self {
        Self {
            watcher: StdMutex::new(None),
            changes: broadcast::channel(64).0,
            reloader: StdMutex::new(None),
            peer_states: std::sync::OnceLock::new(),
        }
    }
}

impl Drop for HarnessWatchState {
    fn drop(&mut self) {
        // The task holds the hub only while it reloads, so here it waits for
        // a signal: stop it.
        if let Some(task) = self.reloader.get_mut().unwrap_or_else(|p| p.into_inner()).take() {
            task.abort();
        }
    }
}

/// Keeps the watcher alive; dropping it stops the events and its thread.
pub(crate) struct HarnessWatcher {
    #[cfg(target_os = "linux")]
    watcher: StdMutex<crate::quiet_dirs::QuietDirs>,
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    watcher: StdMutex<notify::RecommendedWatcher>,
    #[cfg(not(target_os = "linux"))]
    watched: StdMutex<Vec<PathBuf>>,
    /// The kqueue watch (macOS) on the watched folders, the files in the
    /// source folders and cmux.json, made again on each refresh; its events
    /// reach the event thread as rescans (`events`).
    #[cfg(target_os = "macos")]
    kernel: StdMutex<Option<crate::agent_host::record_watch::DirWatch>>,
    #[cfg(target_os = "macos")]
    events: std::sync::mpsc::Sender<notify::Result<notify::Event>>,
}

impl Hub {
    /// Watches the harness profile sources of the loaded config, and the
    /// settings file (`start_settings_watch`). Call once,
    /// inside the runtime, before any other config write. A config built in
    /// code (no sources) watches no profiles.
    pub fn start_harness_watch(self: &Arc<Self>) {
        // The settings file too: a start-mode setting change reaches the
        // watchers (`settings_watch.rs`).
        self.start_settings_watch();
        // And each attached session's HEAD, so its branch stays live (`git_watch.rs`).
        self.start_git_watch();
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            tracing::warn!("harness watch: no async runtime");
            return;
        };
        let sources = match self.config.try_read() {
            Ok(cfg) => cfg.profile_sources.clone(),
            Err(_) => {
                tracing::warn!("harness watch: the config is busy; profiles reload on request");
                return;
            }
        };
        if sources == ProfileSources::none() {
            return;
        }
        let (tx, rx) = std::sync::mpsc::channel();
        #[cfg(target_os = "linux")]
        let watcher = match crate::quiet_dirs::QuietDirs::follow(
            tx,
            "acpmux-harness-inotify",
            followed_targets(&sources),
        ) {
            Ok(watcher) => watcher,
            Err(e) => {
                tracing::warn!("harness watch cannot start: {e}");
                return;
            }
        };
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        let watcher = match notify::recommended_watcher(move |event| {
            let _ = tx.send(event);
        }) {
            Ok(watcher) => watcher,
            Err(e) => {
                tracing::warn!("harness watch cannot start: {e}");
                return;
            }
        };
        let watch = Arc::new(HarnessWatcher {
            #[cfg(not(target_os = "macos"))]
            watcher: StdMutex::new(watcher),
            #[cfg(not(target_os = "linux"))]
            watched: StdMutex::new(Vec::new()),
            #[cfg(target_os = "macos")]
            kernel: StdMutex::new(None),
            #[cfg(target_os = "macos")]
            events: tx,
        });
        watch.refresh(&sources);
        *self.harness_watch.watcher.lock().unwrap_or_else(|p| p.into_inner()) = Some(watch.clone());
        // The thread signals, this task reloads: one reload at a time, and
        // signals that come during a reload make one more. It ends when the
        // thread ends (the channel closes), the hub is gone, or the runtime
        // stops; the hub's watch state aborts it when the hub drops.
        let (signal, mut wake) = tokio::sync::mpsc::unbounded_channel::<()>();
        let hub = Arc::downgrade(self);
        let reloader = handle.spawn(async move {
            while wake.recv().await.is_some() {
                while wake.try_recv().is_ok() {}
                let Some(hub) = hub.upgrade() else { break };
                hub.reload_and_announce().await;
            }
        });
        *self.harness_watch.reloader.lock().unwrap_or_else(|p| p.into_inner()) = Some(reloader);
        // Weak: dropping the hub drops the watcher, which closes the channel
        // and ends the thread.
        let watch = Arc::downgrade(&watch);
        let thread = std::thread::Builder::new()
            .name("acpmux-harness-watch".into())
            .spawn(move || run(&rx, &watch, &sources, &signal));
        if let Err(e) = thread {
            tracing::warn!("harness watch thread cannot start: {e}");
        }
    }

    /// The watchers' copy of a profile change: the reloaded harness names
    /// and the profile sources' diagnostics.
    pub fn subscribe_harness_changes(&self) -> broadcast::Receiver<Value> {
        self.harness_watch.changes.subscribe()
    }

    /// The last peer state note of each name, and their feed to watchers (`peer_states.rs`).
    pub fn peer_states(&self) -> &Arc<crate::peer_states::PeerStates> {
        self.harness_watch.peer_states.get_or_init(Default::default)
    }

    /// Sends one `_acpmux/harnesses_changed` payload to the watchers.
    pub(super) fn send_harness_change(&self, payload: Value) {
        let _ = self.harness_watch.changes.send(payload);
    }

    /// The config file and profile sources a reload reads.
    pub(super) async fn config_sources(&self) -> Result<(PathBuf, ProfileSources), RpcError> {
        let cfg = self.config.read().await;
        let path = cfg
            .path
            .clone()
            .ok_or_else(|| RpcError::invalid_params("this daemon has no config file to reload"))?;
        Ok((path, cfg.profile_sources.clone()))
    }

    /// Reloads the catalog and sends it to the watchers; false when the
    /// reload failed.
    pub(crate) async fn reload_and_announce(self: &Arc<Self>) -> bool {
        match self.reload_catalog().await {
            Ok(reply) => {
                let diagnostics = self.config.read().await.profile_diagnostics.clone();
                let _ = self
                    .harness_watch
                    .changes
                    .send(json!({"harnesses": reply["harnesses"], "diagnostics": diagnostics}));
                true
            }
            Err(e) => {
                tracing::warn!("catalog reload failed: {}", e.message);
                false
            }
        }
    }
}

impl HarnessWatcher {
    /// Watches, for each source folder (and the folder that holds the user folder and
    /// cmux.json), the nearest folder that exists, each once (`nearest_folders`): a folder
    /// missing at the start (no `~/.config/cmux`, no `/etc/cmux/harnesses`) is watched through
    /// its nearest existing ancestor, and each folder on the way is watched as it is made. A
    /// folder no longer the nearest one (its child came) is let go, so a home watched while
    /// `~/.config` was missing stops sending its events once the path exists.
    fn refresh(&self, sources: &ProfileSources) {
        // Linux: the watch follows the source paths itself (`quiet_dirs`): a folder that came,
        // went, or was replaced under its name. Looking again here covers what changed while
        // the burst gathered.
        #[cfg(target_os = "linux")]
        {
            let _ = sources;
            self.watcher.lock().unwrap_or_else(|p| p.into_inner()).sync();
        }
        #[cfg(not(target_os = "linux"))]
        let mut watched = self.watched.lock().unwrap_or_else(|p| p.into_inner());
        // A folder made between its look and its parent's watch has no event (the watch came
        // after it): after each new watch every folder is looked at again, until a look adds
        // none (`settings_watch.rs` `refresh`).
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        {
            let mut watcher = self.watcher.lock().unwrap_or_else(|p| p.into_inner());
            let folders = source_folders(sources);
            loop {
                let wanted = nearest_folders(sources);
                // A removed folder's watch is gone with it: forget it so it returns.
                watched.retain(|dir| {
                    let keep = wanted.contains(dir) && dir.is_dir();
                    if !keep {
                        disarm_dir(&mut watcher, dir);
                    }
                    keep
                });
                let mut added = false;
                for dir in wanted {
                    // An ancestor standing in for a missing folder: its entries only.
                    let entries_only = !folders.contains(&dir);
                    if !watched.contains(&dir) && arm_dir(&mut watcher, &dir, entries_only) {
                        watched.push(dir);
                        added = true;
                    }
                }
                if !added {
                    break;
                }
            }
        }
        #[cfg(target_os = "macos")]
        {
            *watched = nearest_folders(sources);
            let mut paths = watched.clone();
            paths.extend(source_files(sources));
            // Made again on every refresh (a burst that changed the sources):
            // a file replaced by a rename is another file to watch under the
            // same path. The old watch ends when dropped; the new one is
            // armed before this returns, so the reload that follows a
            // refresh reads every change it missed.
            let mut kernel = self.kernel.lock().unwrap_or_else(|p| p.into_inner());
            *kernel = None;
            let events = self.events.clone();
            let sources = sources.clone();
            let mut last = (sources_print(&sources), nearest_folders(&sources));
            *kernel = crate::agent_host::record_watch::DirWatch::start(&paths, move || {
                // The folders also hold other files (cmux.json's folder, a home
                // watched for its `.config`): only a change to a profile
                // source, or to which folders are the nearest ones, is a rescan.
                let now = (sources_print(&sources), nearest_folders(&sources));
                if now == last {
                    return false;
                }
                last = now;
                let rescan = notify::Event::new(notify::EventKind::Any)
                    .set_flag(notify::event::Flag::Rescan);
                // The event thread ended: this watch is done too.
                events.send(Ok(rescan)).is_err()
            });
        }
    }
}

/// What the Linux watch follows: each source folder, and cmux.json (through its folder). The
/// folder that holds the user folder needs no watch of its own: while the user folder is
/// missing, its nearest existing ancestor stands in.
#[cfg(target_os = "linux")]
fn followed_targets(sources: &ProfileSources) -> Vec<crate::quiet_dirs::Target> {
    use crate::quiet_dirs::Target;
    let mut targets: Vec<Target> = sources.managed.iter().cloned().map(Target::Dir).collect();
    targets.extend(sources.user_dir.iter().cloned().map(Target::Dir));
    targets.extend(sources.cmux_json.iter().cloned().map(Target::File));
    targets
}

/// Watches `dir` (notify has no entries-only watch: every change).
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn arm_dir(watcher: &mut notify::RecommendedWatcher, dir: &Path, _entries_only: bool) -> bool {
    watcher.watch(dir, notify::RecursiveMode::NonRecursive).is_ok()
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn disarm_dir(watcher: &mut notify::RecommendedWatcher, dir: &Path) {
    let _ = watcher.unwatch(dir);
}

/// The folders the sources live in: each source folder, the folder that holds the user folder
/// (`cmux harness add` creates the user folder there) and cmux.json's folder.
#[cfg(not(target_os = "linux"))]
fn source_folders(sources: &ProfileSources) -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = sources.managed.clone();
    if let Some(user) = &sources.user_dir {
        folders.push(user.clone());
        folders.extend(user.parent().map(Path::to_path_buf));
    }
    folders.extend(sources.cmux_json.as_deref().and_then(Path::parent).map(Path::to_path_buf));
    folders
}

/// The folder to watch for each source folder: the folder itself when it exists, else its
/// nearest existing ancestor, whose entries name the next folder on the way when it is made.
/// Each once.
#[cfg(not(target_os = "linux"))]
fn nearest_folders(sources: &ProfileSources) -> Vec<PathBuf> {
    let mut nearest: Vec<PathBuf> = Vec::new();
    for folder in source_folders(sources) {
        if let Some(existing) = folder.ancestors().find(|a| a.is_dir())
            && !nearest.iter().any(|n| n == existing)
        {
            nearest.push(existing.to_path_buf());
        }
    }
    nearest
}

/// The files the kqueue watch follows besides the folders: each file in a
/// source folder (an edit inside one is no folder change) and cmux.json.
#[cfg(target_os = "macos")]
fn source_files(sources: &ProfileSources) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = Vec::new();
    for dir in sources.managed.iter().chain(sources.user_dir.iter()) {
        let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|read| read.filter_map(|entry| entry.ok().map(|entry| entry.path())).collect())
            .unwrap_or_default();
        found.retain(|path| path.is_file());
        found.sort();
        files.extend(found);
    }
    files.extend(sources.cmux_json.iter().filter(|path| path.is_file()).cloned());
    files
}

/// A path's size and modification time.
#[cfg(target_os = "macos")]
type Stamp = (u64, Option<std::time::SystemTime>);

/// What the profile sources hold: each source folder's entries with their
/// size and modification time (None for a missing folder), and cmux.json's.
#[cfg(target_os = "macos")]
fn sources_print(sources: &ProfileSources) -> Vec<(PathBuf, Option<Stamp>)> {
    let stamp = |path: &Path| std::fs::metadata(path).ok().map(|m| (m.len(), m.modified().ok()));
    let mut print = Vec::new();
    for dir in sources.managed.iter().chain(sources.user_dir.iter()) {
        print.push((dir.clone(), stamp(dir)));
        let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|read| read.filter_map(|entry| entry.ok().map(|entry| entry.path())).collect())
            .unwrap_or_default();
        entries.sort();
        print.extend(entries.into_iter().map(|path| {
            let at = stamp(&path);
            (path, at)
        }));
    }
    if let Some(cmux_json) = &sources.cmux_json {
        print.push((cmux_json.clone(), stamp(cmux_json)));
    }
    print
}

/// True when `path` is a profile source: a file in a source folder, a source
/// folder itself, or cmux.json; or a folder on the way to one (made or removed
/// while the folder past it is missing, `nearest_folders`).
fn relevant(path: &Path, sources: &ProfileSources) -> bool {
    let folders = sources.managed.iter().chain(sources.user_dir.iter());
    let in_source = |dir: &PathBuf| path == dir || path.parent() == Some(dir.as_path());
    let on_the_way = |source: &PathBuf| source.as_path() != path && source.starts_with(path);
    sources.cmux_json.as_deref() == Some(path)
        || folders.clone().any(in_source)
        || folders.chain(sources.cmux_json.iter()).any(on_the_way)
}

/// `sources` with every path resolved through its nearest existing folder.
fn real_sources(sources: &ProfileSources) -> ProfileSources {
    fn real(path: &Path) -> PathBuf {
        let mut tail = Vec::new();
        let mut at = path;
        loop {
            if let Ok(base) = std::fs::canonicalize(at) {
                return tail.iter().rev().fold(base, |acc, part| acc.join(part));
            }
            match (at.parent(), at.file_name()) {
                (Some(parent), Some(name)) => {
                    tail.push(name.to_owned());
                    at = parent;
                }
                _ => return path.to_path_buf(),
            }
        }
    }
    ProfileSources {
        managed: sources.managed.iter().map(|p| real(p)).collect(),
        user_dir: sources.user_dir.as_deref().map(real),
        cmux_json: sources.cmux_json.as_deref().map(real),
    }
}

/// Linux: whether `path` is a profile source as the sources' links resolve now (a link's
/// target may not have existed at start, or the link was pointed elsewhere since).
#[cfg(target_os = "linux")]
fn followed(path: &Path, sources: &ProfileSources) -> bool {
    use crate::quiet_dirs::resolve;
    let now = ProfileSources {
        managed: sources.managed.iter().map(|p| resolve(p).0).collect(),
        user_dir: sources.user_dir.as_deref().map(|p| resolve(p).0),
        cmux_json: sources.cmux_json.as_deref().map(|p| resolve(p).0),
    };
    relevant(path, &now)
}

#[cfg(not(target_os = "linux"))]
fn followed(_path: &Path, _sources: &ProfileSources) -> bool {
    false
}

/// Ends when the watcher is dropped (the channel closes), or when the reload
/// task is gone (the runtime stopped or the hub dropped).
fn run(
    rx: &std::sync::mpsc::Receiver<notify::Result<notify::Event>>,
    watch: &std::sync::Weak<HarnessWatcher>,
    sources: &ProfileSources,
    signal: &tokio::sync::mpsc::UnboundedSender<()>,
) {
    // FSEvents reports real paths: a symlinked ~/.config must still match.
    let real = real_sources(sources);
    let matters = |event: notify::Result<notify::Event>| match event {
        // A watcher error may have dropped events: reload.
        Err(_) => true,
        // Reads (inotify open/close-nowrite) are not changes: the reload
        // itself reads every profile file and would trigger the next one.
        Ok(event) if matches!(event.kind, notify::EventKind::Access(_)) => false,
        Ok(event) => {
            event.need_rescan()
                || event
                    .paths
                    .iter()
                    .any(|p| relevant(p, sources) || relevant(p, &real) || followed(p, sources))
        }
    };
    while let Ok(first) = rx.recv() {
        let started = Instant::now();
        let mut changed = matters(first);
        let mut closed = false;
        loop {
            let left = MAX_BURST.saturating_sub(started.elapsed());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(QUIET.min(left)) {
                Ok(event) => changed |= matters(event),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    closed = true;
                    break;
                }
            }
        }
        if changed {
            let Some(watch) = watch.upgrade() else { return };
            watch.refresh(sources);
            drop(watch);
            // Only a signal: the reload runs on the runtime, never here.
            if signal.send(()).is_err() {
                return;
            }
        }
        if closed {
            return;
        }
    }
}
