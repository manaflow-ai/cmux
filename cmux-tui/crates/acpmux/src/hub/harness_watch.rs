//! Part of `Hub`; see `hub/mod.rs`. Harness profile hot reload
//! (BRING-YOUR-OWN-HARNESS H2, slice 2b).
//!
//! One non-recursive watcher (FSEvents on macOS, inotify on Linux) over the
//! profile sources: the managed folders, the user folder and cmux.json. The
//! folder that holds the user folder is watched too, so a user folder that
//! `cmux harness add` creates later is picked up; nothing is created here.
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

use notify::Watcher as _;

use crate::config::ProfileSources;

/// A burst ends after this much quiet...
const QUIET: Duration = Duration::from_millis(200);
/// ...or after this long.
const MAX_BURST: Duration = Duration::from_secs(2);

/// The hub's profile hot-reload state: the live watcher and the change feed
/// that `_acpmux/watch` connections forward.
pub(crate) struct HarnessWatchState {
    watcher: StdMutex<Option<Arc<HarnessWatcher>>>,
    changes: broadcast::Sender<Value>,
    /// The task that runs the reloads the watcher thread signals.
    reloader: StdMutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Default for HarnessWatchState {
    fn default() -> Self {
        Self {
            watcher: StdMutex::new(None),
            changes: broadcast::channel(64).0,
            reloader: StdMutex::new(None),
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
    watcher: StdMutex<notify::RecommendedWatcher>,
    watched: StdMutex<Vec<PathBuf>>,
}

impl Hub {
    /// Watches the harness profile sources of the loaded config. Call once,
    /// inside the runtime, before any other config write. A config built in
    /// code (no sources) watches nothing.
    pub fn start_harness_watch(self: &Arc<Self>) {
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
            watcher: StdMutex::new(watcher),
            watched: StdMutex::new(Vec::new()),
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

    /// The config file and profile sources a reload reads.
    pub(super) async fn config_sources(&self) -> Result<(PathBuf, ProfileSources), RpcError> {
        let cfg = self.config.read().await;
        let path = cfg
            .path
            .clone()
            .ok_or_else(|| RpcError::invalid_params("this daemon has no config file to reload"))?;
        Ok((path, cfg.profile_sources.clone()))
    }

    async fn reload_and_announce(self: &Arc<Self>) {
        match self.reload_catalog().await {
            Ok(reply) => {
                let diagnostics = self.config.read().await.profile_diagnostics.clone();
                let _ = self
                    .harness_watch
                    .changes
                    .send(json!({"harnesses": reply["harnesses"], "diagnostics": diagnostics}));
            }
            Err(e) => tracing::warn!("harness profiles changed, reload failed: {}", e.message),
        }
    }
}

impl HarnessWatcher {
    /// Watches every source folder that exists now (and the folder that holds
    /// the user folder), each once.
    fn refresh(&self, sources: &ProfileSources) {
        let mut wanted: Vec<PathBuf> = sources.managed.clone();
        if let Some(user) = &sources.user_dir {
            wanted.push(user.clone());
            wanted.extend(user.parent().map(Path::to_path_buf));
        }
        wanted.extend(sources.cmux_json.as_deref().and_then(Path::parent).map(Path::to_path_buf));
        let mut watched = self.watched.lock().unwrap_or_else(|p| p.into_inner());
        let mut watcher = self.watcher.lock().unwrap_or_else(|p| p.into_inner());
        // A removed folder's watch is gone with it: forget it so it returns.
        watched.retain(|dir| dir.is_dir());
        for dir in wanted {
            if dir.is_dir()
                && !watched.contains(&dir)
                && watcher.watch(&dir, notify::RecursiveMode::NonRecursive).is_ok()
            {
                watched.push(dir);
            }
        }
    }
}

/// True when `path` is a profile source: a file in a source folder, a source
/// folder itself, or cmux.json.
fn relevant(path: &Path, sources: &ProfileSources) -> bool {
    let folders = sources.managed.iter().chain(sources.user_dir.iter());
    let in_source = |dir: &PathBuf| path == dir || path.parent() == Some(dir.as_path());
    sources.cmux_json.as_deref() == Some(path) || folders.into_iter().any(in_source)
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
                || event.paths.iter().any(|p| relevant(p, sources) || relevant(p, &real))
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
