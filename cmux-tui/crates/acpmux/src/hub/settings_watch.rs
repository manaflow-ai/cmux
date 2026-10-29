//! Part of `Hub`; see `hub/mod.rs`. The cmux settings file watched for the
//! start-mode setting (`agents.defaultPermissionMode`, `start_mode.rs`) and the
//! cmux router's start model (`agents.modelRouter.model`, which reloads the catalog):
//! when its value changes, local `_acpmux/watch` connections get
//! `_acpmux/start_mode_changed`, so a pending chat's start-mode chip asks
//! acpmux again only then, never each time its pane is shown again. Any
//! change also wakes the sub-sessions waiting for a run slot, which read
//! `agents.subsessions.maxRunning` again (`subsession_runs.rs`).
//!
//! One non-recursive watcher over the folder of each settings file
//! `user_settings::read` looks at, and its symlink target's folder (or the
//! nearest existing ancestor of one not created yet, so it is picked up
//! when it is), as `harness_watch.rs` does for profiles: no
//! timers and no polling. The event thread gathers a burst and only signals;
//! one task on the runtime reads the setting and tells the watchers when it
//! differs from the last value it saw. A write that leaves the setting as it
//! was (another key, the same value) tells nobody.

use super::*;

use std::path::{Path, PathBuf};
use std::sync::mpsc::RecvTimeoutError;
use std::time::Instant;

use notify::Watcher as _;

use super::harness_watch::{MAX_BURST, QUIET};

/// The hub's settings watch: the live watcher and the task that reads the
/// setting when the watcher thread signals.
#[derive(Default)]
pub(crate) struct SettingsWatchState {
    watcher: StdMutex<Option<Arc<SettingsWatcher>>>,
    task: StdMutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for SettingsWatchState {
    fn drop(&mut self) {
        if let Some(task) = self.task.get_mut().unwrap_or_else(|p| p.into_inner()).take() {
            task.abort();
        }
    }
}

/// Keeps the watcher alive; dropping it stops the events and its thread.
pub(crate) struct SettingsWatcher {
    watcher: StdMutex<notify::RecommendedWatcher>,
    watched: StdMutex<Vec<PathBuf>>,
}

impl Hub {
    /// Watches the settings file for start-mode changes. Call once, inside
    /// the runtime (`start_harness_watch` does).
    pub(super) fn start_settings_watch(self: &Arc<Self>) {
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            tracing::warn!("settings watch: no async runtime");
            return;
        };
        let files = crate::user_settings::paths();
        let (tx, rx) = std::sync::mpsc::channel();
        let watcher = match notify::recommended_watcher(move |event| {
            let _ = tx.send(event);
        }) {
            Ok(watcher) => watcher,
            Err(e) => {
                tracing::warn!("settings watch cannot start: {e}");
                return;
            }
        };
        let watch = Arc::new(SettingsWatcher {
            watcher: StdMutex::new(watcher),
            watched: StdMutex::new(Vec::new()),
        });
        watch.refresh(&files);
        *self.settings_watch.watcher.lock().unwrap_or_else(|p| p.into_inner()) =
            Some(watch.clone());
        // The value the watchers' last answer was based on.
        let mut last = super::start_mode::setting_snapshot();
        // The cmux router profile's start model (`agents.modelRouter.model`): a change rebuilds
        // the catalog, so the next new chat on `cmux` starts on it.
        let mut last_router = crate::config::cmux_router_model_setting();
        let (signal, mut wake) = tokio::sync::mpsc::unbounded_channel::<()>();
        let hub = Arc::downgrade(self);
        let task = handle.spawn(async move {
            while wake.recv().await.is_some() {
                while wake.try_recv().is_ok() {}
                // `agents.subsessions.maxRunning` may have changed: sub-sessions waiting for a run
                // slot look again (`subsession_runs.rs`).
                if let Some(hub) = hub.upgrade() {
                    hub.subsession_runs.wake();
                }
                let Ok((now, router)) = tokio::task::spawn_blocking(|| {
                    (
                        super::start_mode::setting_snapshot(),
                        crate::config::cmux_router_model_setting(),
                    )
                })
                .await
                else {
                    break;
                };
                if router != last_router {
                    last_router = router;
                    if let Some(hub) = hub.upgrade()
                        && let Err(e) = hub.reload_catalog().await
                    {
                        tracing::warn!(
                            "model router setting: catalog reload failed: {}",
                            e.message
                        );
                    }
                }
                if now == last {
                    continue;
                }
                last = now;
                let Some(hub) = hub.upgrade() else { break };
                hub.start_mode_changed();
            }
        });
        *self.settings_watch.task.lock().unwrap_or_else(|p| p.into_inner()) = Some(task);
        // Weak: dropping the hub drops the watcher, which closes the channel
        // and ends the thread.
        let watch = Arc::downgrade(&watch);
        let thread = std::thread::Builder::new()
            .name("acpmux-settings-watch".into())
            .spawn(move || run(&rx, &watch, &files, &signal));
        if let Err(e) = thread {
            tracing::warn!("settings watch thread cannot start: {e}");
        }
    }
}

impl SettingsWatcher {
    /// Watches each settings file's folder, as named and through symlinks
    /// (a dotfiles link's target folder), each once; for a folder that does
    /// not exist yet, its nearest existing ancestor, so its creation is seen
    /// and the next refresh watches it.
    fn refresh(&self, files: &[PathBuf]) {
        let mut wanted: Vec<PathBuf> = Vec::new();
        let folders = files.iter().flat_map(|f| {
            [f.parent().map(Path::to_path_buf), real(f).parent().map(Path::to_path_buf)]
        });
        for folder in folders.flatten() {
            if let Some(existing) = folder.ancestors().find(|a| a.is_dir()) {
                wanted.push(existing.to_path_buf());
            }
        }
        let mut watched = self.watched.lock().unwrap_or_else(|p| p.into_inner());
        let mut watcher = self.watcher.lock().unwrap_or_else(|p| p.into_inner());
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

/// `path` resolved through its nearest existing folder (FSEvents reports
/// real paths: a symlinked ~/.config must still match).
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

/// Ends when the watcher is dropped (the channel closes), or when the task
/// is gone (the runtime stopped or the hub dropped).
fn run(
    rx: &std::sync::mpsc::Receiver<notify::Result<notify::Event>>,
    watch: &std::sync::Weak<SettingsWatcher>,
    files: &[PathBuf],
    signal: &tokio::sync::mpsc::UnboundedSender<()>,
) {
    let mut names: Vec<PathBuf> = files.to_vec();
    names.extend(files.iter().map(|f| real(f)));
    // A settings file, or a folder on the way to one (created or removed).
    let relevant =
        |path: &Path| names.iter().any(|f| f == path || f.ancestors().any(|a| a == path));
    let matters = |event: notify::Result<notify::Event>| match event {
        // A watcher error may have dropped events: look again.
        Err(_) => true,
        // Reads are not changes: the task's own read would signal again.
        Ok(event) if matches!(event.kind, notify::EventKind::Access(_)) => false,
        Ok(event) => event.need_rescan() || event.paths.iter().any(|p| relevant(p)),
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
            watch.refresh(files);
            drop(watch);
            if signal.send(()).is_err() {
                return;
            }
        }
        if closed {
            return;
        }
    }
}
