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
//! timers and no polling. On macOS it is kqueue on the files and those
//! folders' entries (`named_files_watch`): while `~/.config/cmux` does not
//! exist, that folder is `$HOME`, and an FSEvents stream over it woke the
//! daemon for every write below the home (each agent's logs in `~/.codex`). The event thread gathers a burst and only signals;
//! one task on the runtime reads the setting and tells the watchers when it
//! differs from the last value it saw. A write that leaves the setting as it
//! was (another key, the same value) tells nobody.

use super::*;

use std::path::{Path, PathBuf};
use std::sync::mpsc::RecvTimeoutError;
use std::time::Instant;

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
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
    /// Linux: inotify for changes only (`quiet_dirs`): notify asks for every open, and while
    /// `~/.config/cmux` does not exist the folder watched is `$HOME`.
    #[cfg(target_os = "linux")]
    watcher: StdMutex<crate::quiet_dirs::QuietDirs>,
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    watcher: StdMutex<notify::RecommendedWatcher>,
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    watched: StdMutex<Vec<PathBuf>>,
    #[cfg(target_os = "macos")]
    _watch: crate::named_files_watch::NamedFilesWatch,
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
        #[cfg(target_os = "macos")]
        let watch = {
            let named = crate::named_files_watch::NamedFilesWatch::start(files.clone(), {
                move |changed| {
                    changed.iter().any(|path| {
                        let event =
                            notify::Event::new(notify::EventKind::Any).add_path(path.clone());
                        tx.send(Ok(event)).is_err()
                    })
                }
            });
            let Some(named) = named else {
                tracing::warn!("settings watch cannot start: no settings folder can be watched");
                return;
            };
            Arc::new(SettingsWatcher { _watch: named })
        };
        #[cfg(target_os = "linux")]
        let watch = {
            // The watch follows each settings file's path itself: its folder as named and through
            // links, the nearest existing ancestor of a missing one, a folder replaced under its
            // name, and no watch left on a folder it no longer needs (`quiet_dirs`).
            let targets =
                files.iter().cloned().map(crate::quiet_dirs::Target::File).collect::<Vec<_>>();
            let watcher = match crate::quiet_dirs::QuietDirs::follow(
                tx,
                "acpmux-settings-inotify",
                targets,
            ) {
                Ok(watcher) => watcher,
                Err(e) => {
                    tracing::warn!("settings watch cannot start: {e}");
                    return;
                }
            };
            Arc::new(SettingsWatcher { watcher: StdMutex::new(watcher) })
        };
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        let watch = {
            let watcher = match notify::recommended_watcher(move |event| {
                let _ = tx.send(event);
            }) {
                Ok(watcher) => watcher,
                Err(e) => {
                    tracing::warn!("settings watch cannot start: {e}");
                    return;
                }
            };
            Arc::new(SettingsWatcher {
                watcher: StdMutex::new(watcher),
                watched: StdMutex::new(Vec::new()),
            })
        };
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
                // slot look again (`subsession_runs.rs`). What waits on a setting with no timer
                // reads it again (the desktop bridge while off, `desktop_bridge.rs`).
                if let Some(hub) = hub.upgrade() {
                    hub.subsession_runs.wake();
                    hub.settings_changes.send_modify(|seq| *seq = seq.wrapping_add(1));
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
    #[cfg(target_os = "macos")]
    fn refresh(&self, _files: &[PathBuf]) {
        // The kqueue watch arms itself again when a folder or file comes or goes.
    }

    /// Linux: the watch follows the files' paths itself (`quiet_dirs`); looking again here
    /// covers what changed while the burst gathered.
    #[cfg(target_os = "linux")]
    fn refresh(&self, _files: &[PathBuf]) {
        self.watcher.lock().unwrap_or_else(|p| p.into_inner()).sync();
    }

    /// Watches each settings file's folder, as for macOS above, on notify's watcher.
    ///
    /// A folder made between the look and its ancestor's watch has no event (the watch came
    /// after it), so after each new watch the folders are looked at again, until a look adds
    /// none: the daemon starts this watch after its ready line, the moment a client may make
    /// `~/.config/cmux` and its settings file, and a later write into that folder was missed.
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    fn refresh(&self, files: &[PathBuf]) {
        let mut watched = self.watched.lock().unwrap_or_else(|p| p.into_inner());
        let mut watcher = self.watcher.lock().unwrap_or_else(|p| p.into_inner());
        watched.retain(|dir| dir.is_dir());
        loop {
            let mut wanted: Vec<PathBuf> = Vec::new();
            let folders = files.iter().flat_map(|f| {
                [f.parent().map(Path::to_path_buf), real(f).parent().map(Path::to_path_buf)]
            });
            let mut own: Vec<PathBuf> = Vec::new();
            for folder in folders.flatten() {
                if let Some(existing) = folder.ancestors().find(|a| a.is_dir()) {
                    wanted.push(existing.to_path_buf());
                }
                own.push(folder);
            }
            let mut added = false;
            for dir in wanted {
                // An ancestor standing in for a missing folder: its entries only.
                let entries_only = !own.contains(&dir);
                if dir.is_dir()
                    && !watched.contains(&dir)
                    && arm_dir(&mut watcher, &dir, entries_only)
                {
                    watched.push(dir);
                    added = true;
                }
            }
            if !added {
                return;
            }
        }
    }
}

/// Watches `dir` (notify has no entries-only watch: every change).
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn arm_dir(watcher: &mut notify::RecommendedWatcher, dir: &Path, _entries_only: bool) -> bool {
    watcher.watch(dir, notify::RecursiveMode::NonRecursive).is_ok()
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

/// Whether `path` is `file` or a folder on the way to it.
fn on_the_way(file: &Path, path: &Path) -> bool {
    file == path || file.ancestors().any(|a| a == path)
}

/// Linux: whether `path` is a settings file, or a folder on the way to one, as its links resolve
/// now (a link's target may not have existed at start, or the link was pointed elsewhere since).
#[cfg(target_os = "linux")]
fn followed(files: &[PathBuf], path: &Path) -> bool {
    files.iter().any(|f| on_the_way(&crate::quiet_dirs::resolve(f).0, path))
}

#[cfg(not(target_os = "linux"))]
fn followed(_files: &[PathBuf], _path: &Path) -> bool {
    false
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
    // A settings file, or a folder on the way to one (created or removed). Linux also matches
    // each file as its links resolve now: a link's target may not have existed at start.
    let relevant = |path: &Path| names.iter().any(|f| on_the_way(f, path)) || followed(files, path);
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
