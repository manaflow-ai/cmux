//! Socket-root changes for the journal forwarder. A session appears when a
//! cmux-tui daemon binds `<name>.sock` in one of the resolver roots, so the
//! forwarder rescans on a file-watcher event, not on a scan period (Chromium
//! base/files/file_path_watcher.h). A root that does not exist yet is
//! watched through its parent until it appears. `changes` counts the events;
//! session workers whose daemon is gone wait on it too.

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use notify::Watcher as _;
use tokio::sync::watch;

/// A root can appear between the check and the parent watch; a reconcile
/// repeats until the targets it watched are the ones it finds, at most this
/// often.
const RECONCILE_PASSES: usize = 4;

pub(super) struct SocketDirs {
    dirs: Vec<PathBuf>,
    watched: Option<Watched>,
    changes: Arc<watch::Sender<u64>>,
    /// The watcher reported an error: its watches may be gone.
    lost: Arc<AtomicBool>,
}

struct Watched {
    watcher: notify::RecommendedWatcher,
    paths: HashSet<PathBuf>,
}

impl SocketDirs {
    pub(super) fn new(dirs: Vec<PathBuf>) -> Self {
        Self {
            dirs,
            watched: None,
            changes: Arc::new(watch::channel(0).0),
            lost: Arc::new(AtomicBool::new(false)),
        }
    }

    /// A receiver that wakes on the next change of a socket root.
    pub(super) fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    /// Wakes every receiver, as a root change would.
    pub(super) fn bump(&self) {
        bump(&self.changes);
    }

    /// Watches every root (or its parent while it does not exist). `false`
    /// when a root cannot be watched: the caller rescans on a backoff then.
    /// The watcher's calls block (inotify answers on its own thread, FSEvents
    /// restarts its stream), so they run on the blocking pool.
    pub(super) async fn reconcile(&mut self) -> bool {
        let dirs = self.dirs.clone();
        let watched = self.watched.take();
        let changes = Arc::clone(&self.changes);
        let lost = Arc::clone(&self.lost);
        let task = cmux_blocking::spawn_blocking(move || {
            let watched = match watched {
                Some(watched) if !lost.swap(false, Ordering::AcqRel) => Some(watched),
                stale => {
                    drop(stale);
                    Watched::new(&dirs, changes, lost)
                }
            };
            match watched {
                Some(mut watched) => {
                    let complete = watched.reconcile(&dirs);
                    (Some(watched), complete)
                }
                None => (None, false),
            }
        });
        match task.await {
            Ok((watched, complete)) => {
                self.watched = watched;
                complete
            }
            Err(_) => false,
        }
    }

    /// Drops the watcher on the blocking pool (its backends join threads).
    pub(super) async fn close(mut self) {
        if let Some(watched) = self.watched.take() {
            let _ = cmux_blocking::spawn_blocking(move || drop(watched)).await;
        }
    }
}

fn bump(changes: &watch::Sender<u64>) {
    changes.send_modify(|generation| *generation = generation.wrapping_add(1));
}

impl Watched {
    fn new(
        dirs: &[PathBuf],
        changes: Arc<watch::Sender<u64>>,
        lost: Arc<AtomicBool>,
    ) -> Option<Self> {
        let names: Vec<OsString> =
            dirs.iter().filter_map(|dir| dir.file_name().map(OsStr::to_owned)).collect();
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let relevant = match event {
                Ok(event) => concerns_sockets(&names, &event),
                Err(_) => {
                    lost.store(true, Ordering::Release);
                    true
                }
            };
            if relevant {
                bump(&changes);
            }
        })
        .ok()?;
        Some(Self { watcher, paths: HashSet::new() })
    }

    fn reconcile(&mut self, dirs: &[PathBuf]) -> bool {
        for _ in 0..RECONCILE_PASSES {
            let (wanted, found_all) = watch_targets(dirs);
            if wanted == self.paths {
                return found_all;
            }
            let gone: Vec<PathBuf> = self.paths.difference(&wanted).cloned().collect();
            for path in gone {
                let _ = self.watcher.unwatch(&path);
                self.paths.remove(&path);
            }
            for path in wanted {
                if self.paths.contains(&path) {
                    continue;
                }
                if self.watcher.watch(&path, notify::RecursiveMode::NonRecursive).is_err() {
                    return false;
                }
                self.paths.insert(path);
            }
        }
        false
    }
}

/// Each root that exists, else its parent; `false` when neither exists for
/// some root.
fn watch_targets(dirs: &[PathBuf]) -> (HashSet<PathBuf>, bool) {
    let mut targets = HashSet::new();
    let mut found_all = true;
    for dir in dirs {
        let target = Some(dir.as_path())
            .filter(|dir| is_dir(dir))
            .or_else(|| dir.parent().filter(|parent| is_dir(parent)));
        match target {
            Some(target) => {
                targets.insert(target.to_path_buf());
            }
            None => found_all = false,
        }
    }
    (targets, found_all)
}

fn is_dir(path: &Path) -> bool {
    cmux_blocking::fs::metadata(path).is_ok_and(|metadata| metadata.is_dir())
}

/// A root itself appearing or going, or a `.sock` entry in one. Matched by
/// name: FSEvents reports `/private/tmp` for `/tmp`.
fn concerns_sockets(roots: &[OsString], event: &notify::Event) -> bool {
    if event.need_rescan() {
        return true;
    }
    if matches!(event.kind, notify::EventKind::Access(_)) {
        return false;
    }
    let is_root =
        |path: &Path| path.file_name().is_some_and(|name| roots.iter().any(|root| root == name));
    event.paths.iter().any(|path| {
        is_root(path)
            || (path.extension() == Some(OsStr::new("sock")) && path.parent().is_some_and(is_root))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn event(kind: notify::EventKind, path: &str) -> notify::Event {
        notify::Event::new(kind).add_path(PathBuf::from(path))
    }

    #[test]
    fn only_root_and_socket_entries_are_changes() {
        use notify::EventKind;
        use notify::event::{AccessKind, CreateKind, ModifyKind, RemoveKind};
        let roots = vec![OsString::from("cmux-tui-501")];
        let create = EventKind::Create(CreateKind::Any);
        assert!(concerns_sockets(&roots, &event(create, "/private/tmp/cmux-tui-501")));
        assert!(concerns_sockets(&roots, &event(create, "/tmp/cmux-tui-501/work.sock")));
        assert!(concerns_sockets(
            &roots,
            &event(EventKind::Remove(RemoveKind::Any), "/tmp/cmux-tui-501/work.sock")
        ));
        assert!(!concerns_sockets(&roots, &event(create, "/tmp/cmux-tui-501/work.log")));
        assert!(!concerns_sockets(&roots, &event(create, "/tmp/other/work.sock")));
        assert!(!concerns_sockets(
            &roots,
            &event(EventKind::Modify(ModifyKind::Any), "/tmp/unrelated.txt")
        ));
        assert!(!concerns_sockets(
            &roots,
            &event(EventKind::Access(AccessKind::Any), "/tmp/cmux-tui-501/work.sock")
        ));
    }

    #[test]
    fn a_missing_root_is_watched_through_its_parent() {
        let base = std::env::temp_dir().join(format!("chatmux-socket-dirs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let root = base.join("cmux-tui-501");
        let (targets, found_all) = watch_targets(std::slice::from_ref(&root));
        assert!(found_all);
        assert_eq!(targets, HashSet::from([base.clone()]));
        std::fs::create_dir(&root).unwrap();
        let (targets, _) = watch_targets(std::slice::from_ref(&root));
        assert_eq!(targets, HashSet::from([root]));
        let orphan = base.join("missing").join("cmux-tui-501");
        assert!(!watch_targets(&[orphan]).1, "no root and no parent: not complete");
        let _ = std::fs::remove_dir_all(&base);
    }

    /// The forwarder wakes when a socket is bound in a root that did not
    /// exist at start, with no scan period.
    #[test]
    fn a_socket_bound_in_a_new_root_wakes_the_forwarder() {
        let base =
            std::env::temp_dir().join(format!("chatmux-socket-dirs-bind-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let root = base.join("cmux-tui-77");
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let mut dirs = SocketDirs::new(vec![root.clone()]);
            let mut changes = dirs.subscribe();
            assert!(dirs.reconcile().await, "the parent is watched");
            changes.borrow_and_update();

            std::fs::create_dir(&root).unwrap();
            tokio::time::timeout(Duration::from_secs(10), changes.changed())
                .await
                .expect("the new root is a change")
                .unwrap();
            assert!(dirs.reconcile().await, "the root itself is watched now");
            changes.borrow_and_update();

            let _listener =
                std::os::unix::net::UnixListener::bind(root.join("session.sock")).unwrap();
            tokio::time::timeout(Duration::from_secs(10), changes.changed())
                .await
                .expect("the bound socket is a change")
                .unwrap();
            dirs.close().await;
        });
        let _ = std::fs::remove_dir_all(&base);
    }
}
