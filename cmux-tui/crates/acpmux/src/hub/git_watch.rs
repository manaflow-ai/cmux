//! Part of `Hub`; see `hub/mod.rs`. A shown chat's branch, kept live: every
//! summary's `gitBranch` names the branch its folder has checked out now, so
//! a client's header and Inspector follow a checkout within about a second.
//! The branch it started on (`meta.git_branch`) never changes: the stats and
//! the pull request link read that one (hq#1920).
//!
//! One non-recursive watcher over the git directory that holds each attached
//! session's HEAD (`git_state::head_dir`; a linked worktree's own one under
//! `.git/worktrees/`): a checkout, a switch or a branch rename rewrites HEAD
//! there. No timers and no polling, as `settings_watch.rs`: the event thread
//! gathers a burst and only signals; one task on the runtime reads the git
//! state of every attached session and moves the watch to their folders. A
//! session whose branch differs from the last one acpmux saw gets a `git`
//! record, which watchers hear as `_acpmux/session_changed` kind `git`. An
//! attach or a detach signals too, so the watch follows the chats clients
//! hold, and a checkout made while none held a chat shows on its next attach.

use super::*;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::RecvTimeoutError;
use std::time::Instant;

use notify::Watcher as _;

use super::harness_watch::{MAX_BURST, QUIET};
use crate::git_state::{GitState, head_dir};

/// The hub's git watch: the task's wake-up, the task, and the branch each
/// session's folder had at its last read.
#[derive(Default)]
pub(crate) struct GitWatchState {
    signal: StdMutex<Option<tokio::sync::mpsc::UnboundedSender<()>>>,
    task: StdMutex<Option<tokio::task::JoinHandle<()>>>,
    /// By session id; `None` inside is a detached HEAD or no repository.
    now: StdMutex<HashMap<String, Option<String>>>,
}

impl Drop for GitWatchState {
    fn drop(&mut self) {
        if let Some(task) = self.task.get_mut().unwrap_or_else(|p| p.into_inner()).take() {
            task.abort();
        }
    }
}

/// The watcher and the folders it watches, used only off the runtime.
struct Watched {
    watcher: notify::RecommendedWatcher,
    dirs: HashSet<PathBuf>,
}

impl Hub {
    /// Watches the HEAD of each attached session's folder. Call once, inside
    /// the runtime (`start_harness_watch` does).
    pub(super) fn start_git_watch(self: &Arc<Self>) {
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            tracing::warn!("git watch: no async runtime");
            return;
        };
        let (tx, rx) = std::sync::mpsc::channel();
        let watcher = match notify::recommended_watcher(move |event| {
            let _ = tx.send(event);
        }) {
            Ok(watcher) => watcher,
            Err(e) => {
                tracing::warn!("git watch cannot start: {e}");
                return;
            }
        };
        let watched = Arc::new(StdMutex::new(Watched { watcher, dirs: HashSet::new() }));
        let (signal, mut wake) = tokio::sync::mpsc::unbounded_channel::<()>();
        *self.git_watch.signal.lock().unwrap_or_else(|p| p.into_inner()) = Some(signal.clone());
        let hub = Arc::downgrade(self);
        let task = handle.spawn(async move {
            while wake.recv().await.is_some() {
                while wake.try_recv().is_ok() {}
                let Some(hub) = hub.upgrade() else { break };
                let held = hub.held_sessions();
                let cwds: Vec<PathBuf> = held.iter().map(|(_, cwd)| cwd.clone()).collect();
                let watched = watched.clone();
                let Ok(read) =
                    tokio::task::spawn_blocking(move || read_and_watch(&watched, cwds)).await
                else {
                    break;
                };
                for ((session, _), branch) in held.iter().zip(read) {
                    hub.git_branch_read(session, branch);
                }
            }
        });
        *self.git_watch.task.lock().unwrap_or_else(|p| p.into_inner()) = Some(task);
        let thread = std::thread::Builder::new()
            .name("acpmux-git-watch".into())
            .spawn(move || run(&rx, &signal));
        if let Err(e) = thread {
            tracing::warn!("git watch thread cannot start: {e}");
        }
    }

    /// Wakes the git watch: a client attached or detached.
    pub(super) fn git_watch_wake(&self) {
        if let Some(signal) = &*self.git_watch.signal.lock().unwrap_or_else(|p| p.into_inner()) {
            let _ = signal.send(());
        }
    }

    /// The branch `m`'s folder has checked out now: the last read, else the
    /// one it started on.
    pub(super) fn git_branch_now(&self, m: &SessionMeta) -> Option<String> {
        let now = self.git_watch.now.lock().unwrap_or_else(|p| p.into_inner());
        now.get(&m.id).cloned().unwrap_or_else(|| m.git_branch.clone())
    }

    /// The sessions some client holds, with their folders.
    fn held_sessions(&self) -> Vec<(Arc<Session>, PathBuf)> {
        let held: Vec<Arc<Session>> = {
            let sessions = self.sessions.lock().unwrap_or_else(|p| p.into_inner());
            sessions.values().filter(|s| s.attached.load(Ordering::SeqCst) > 0).cloned().collect()
        };
        held.into_iter()
            .map(|s| {
                let cwd = s.meta.lock().unwrap_or_else(|p| p.into_inner()).cwd.clone();
                (s, cwd)
            })
            .collect()
    }

    /// Keeps `branch`, read from `session`'s folder, and tells the watchers
    /// when it is not the branch they were last told.
    fn git_branch_read(&self, session: &Session, branch: Option<String>) {
        let started = session.meta.lock().unwrap_or_else(|p| p.into_inner()).git_branch.clone();
        let before = {
            let mut now = self.git_watch.now.lock().unwrap_or_else(|p| p.into_inner());
            now.insert(session.id.clone(), branch.clone()).unwrap_or(started)
        };
        if before != branch {
            self.append(session, "mux", "git", json!({"gitBranch": branch}));
        }
    }
}

/// The watch moved to the folders' HEADs, then each folder's branch: read
/// after the watch is in place, so a checkout between the two is not missed.
fn read_and_watch(watched: &StdMutex<Watched>, cwds: Vec<PathBuf>) -> Vec<Option<String>> {
    let wanted: HashSet<PathBuf> = cwds.iter().filter_map(|cwd| head_dir(cwd)).collect();
    {
        let mut watched = watched.lock().unwrap_or_else(|p| p.into_inner());
        let Watched { watcher, dirs } = &mut *watched;
        dirs.retain(|dir| {
            wanted.contains(dir) || {
                let _ = watcher.unwatch(dir);
                false
            }
        });
        for dir in wanted {
            if !dirs.contains(&dir)
                && watcher.watch(&dir, notify::RecursiveMode::NonRecursive).is_ok()
            {
                dirs.insert(dir);
            }
        }
    }
    cwds.iter().map(|cwd| GitState::read(cwd).branch).collect()
}

/// A change to a HEAD file (git renames `HEAD.lock` over it).
fn is_head(path: &Path) -> bool {
    path.file_name().is_some_and(|name| name == "HEAD")
}

/// Ends when the watcher is dropped (the channel closes), or when the task
/// is gone (the runtime stopped or the hub dropped).
fn run(
    rx: &std::sync::mpsc::Receiver<notify::Result<notify::Event>>,
    signal: &tokio::sync::mpsc::UnboundedSender<()>,
) {
    let matters = |event: notify::Result<notify::Event>| match event {
        // A watcher error may have dropped events: read again.
        Err(_) => true,
        // Reads are not changes: the task's own read would signal again.
        Ok(event) if matches!(event.kind, notify::EventKind::Access(_)) => false,
        Ok(event) => event.need_rescan() || event.paths.iter().any(|p| is_head(p)),
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
        // Only a signal: the read runs on the runtime, never here.
        if changed && signal.send(()).is_err() {
            return;
        }
        if closed {
            return;
        }
    }
}
