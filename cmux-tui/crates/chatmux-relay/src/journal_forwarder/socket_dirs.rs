//! Socket-root changes for the journal forwarder. A session appears when a
//! cmux-tui daemon binds `<name>.sock` in one of the resolver roots, so the
//! forwarder rescans on a directory-entry event, not on a scan period
//! (Chromium base/files/file_path_watcher.h). A root that does not exist yet
//! is watched through its parent, for entries appearing only, until it
//! appears (entry_watch.rs: file work in the parent queues no event).
//! `changes` counts the relevant events; session workers whose daemon is
//! gone wait on it too.

mod entry_watch;

use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use entry_watch::{EntryWatch, Fired, Mask};
use tokio::sync::watch;

/// A root can appear between the check and the parent watch; a reconcile
/// repeats until the targets it watched are the ones it finds, at most this
/// often.
const RECONCILE_PASSES: usize = 4;

/// Each watched directory: a root (`Entries`) or a missing root's parent
/// (`Appear`).
type Targets = HashMap<PathBuf, Mask>;

pub(super) struct SocketDirs {
    dirs: Arc<[PathBuf]>,
    /// None before the first reconcile and after the watch failed.
    watched: Option<Watched>,
    changes: watch::Sender<u64>,
}

struct Watched {
    watch: EntryWatch,
    targets: Targets,
}

impl SocketDirs {
    pub(super) fn new(dirs: Vec<PathBuf>) -> Self {
        Self { dirs: dirs.into(), watched: None, changes: watch::channel(0).0 }
    }

    /// A receiver that wakes on the next change of a socket root.
    pub(super) fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    /// Wakes every receiver, as a root change would.
    pub(super) fn bump(&self) {
        self.changes.send_modify(|generation| *generation = generation.wrapping_add(1));
    }

    /// Watches every root (or its parent while it does not exist). `false`
    /// when a root cannot be watched: the caller rescans on a backoff then.
    /// The path lookups block, so they run on the blocking pool.
    pub(super) async fn reconcile(&mut self) -> bool {
        let watched = match self.watched.take() {
            Some(watched) => watched,
            None => match EntryWatch::new() {
                Ok(watch) => Watched { watch, targets: Targets::new() },
                Err(_) => return false,
            },
        };
        let dirs = Arc::clone(&self.dirs);
        let task = cmux_blocking::spawn_blocking(move || {
            let mut watched = watched;
            let complete = watched.reconcile(&dirs);
            (watched, complete)
        });
        match task.await {
            Ok((watched, complete)) => {
                self.watched = Some(watched);
                complete
            }
            Err(_) => false,
        }
    }

    /// Waits for the next change of a socket root, bumps every receiver and
    /// returns. Events that concern no root (another entry appearing in a
    /// parent) are dropped here. Never returns while nothing is watched.
    /// Cancel-safe.
    pub(super) async fn changed(&mut self) {
        let Some(watched) = self.watched.as_mut() else {
            return std::future::pending().await;
        };
        loop {
            match watched.watch.wait().await {
                Ok(fired) => {
                    if concerns_sockets(&mut watched.targets, &self.dirs, fired) {
                        break;
                    }
                }
                Err(_) => {
                    // The next reconcile makes a new watch.
                    self.watched = None;
                    break;
                }
            }
        }
        self.bump();
    }
}

impl Watched {
    fn reconcile(&mut self, dirs: &[PathBuf]) -> bool {
        for _ in 0..RECONCILE_PASSES {
            let (wanted, found_all) = watch_targets(dirs);
            if wanted == self.targets {
                return found_all;
            }
            let stale: Vec<PathBuf> = self
                .targets
                .iter()
                .filter(|(path, mask)| wanted.get(*path) != Some(*mask))
                .map(|(path, _)| path.clone())
                .collect();
            for path in stale {
                self.watch.remove(&path);
                self.targets.remove(&path);
            }
            for (path, mask) in wanted {
                if self.targets.contains_key(&path) {
                    continue;
                }
                if self.watch.add(&path, mask).is_err() {
                    return false;
                }
                self.targets.insert(path, mask);
            }
        }
        false
    }
}

/// Whether the events change a socket root: a `.sock` entry in a root, a
/// root appearing in a parent, a watched directory going away (its target is
/// dropped so the next reconcile watches again), or lost events.
fn concerns_sockets(targets: &mut Targets, roots: &[PathBuf], fired: Vec<Fired>) -> bool {
    let mut relevant = false;
    for fired in fired {
        relevant |= match fired {
            Fired::Overflow => true,
            Fired::Gone { dir } => {
                targets.remove(&dir);
                true
            }
            Fired::Entry { dir, name } => match targets.get(&dir).copied() {
                Some(Mask::Entries) => {
                    name.is_none_or(|name| Path::new(&name).extension() == Some(OsStr::new("sock")))
                }
                Some(Mask::Appear) => {
                    // The missing roots under this parent (a sibling root
                    // that exists has its own watch).
                    let mut missing = roots.iter().filter(|root| {
                        root.parent() == Some(dir.as_path()) && !targets.contains_key(*root)
                    });
                    match name {
                        Some(name) => {
                            missing.any(|root| root.file_name() == Some(name.as_os_str()))
                        }
                        // kqueue names no entry: a missing root that exists
                        // now is the change.
                        None => missing.any(|root| is_dir(root)),
                    }
                }
                None => false,
            },
        };
    }
    relevant
}

/// Each root that exists (`Entries`), else its parent (`Appear`); `false`
/// when neither exists for some root.
fn watch_targets(dirs: &[PathBuf]) -> (Targets, bool) {
    let mut targets = Targets::new();
    let mut found_all = true;
    for dir in dirs {
        if is_dir(dir) {
            targets.insert(dir.clone(), Mask::Entries);
            continue;
        }
        match dir.parent().filter(|parent| is_dir(parent)) {
            Some(parent) => {
                targets.entry(parent.to_path_buf()).or_insert(Mask::Appear);
            }
            None => found_all = false,
        }
    }
    (targets, found_all)
}

fn is_dir(path: &Path) -> bool {
    cmux_blocking::fs::metadata(path).is_ok_and(|metadata| metadata.is_dir())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::time::Duration;

    fn scratch(label: &str) -> PathBuf {
        let base = std::env::temp_dir()
            .join(format!("chatmux-socket-dirs-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        base
    }

    fn entry(dir: &str, name: Option<&str>) -> Vec<Fired> {
        vec![Fired::Entry { dir: PathBuf::from(dir), name: name.map(OsString::from) }]
    }

    #[test]
    fn only_root_and_socket_entries_are_changes() {
        let roots = [PathBuf::from("/tmp/cmux-tui-501"), PathBuf::from("/run/cmux-tui-hashed-501")];
        let mut targets = Targets::from([
            (PathBuf::from("/tmp/cmux-tui-501"), Mask::Entries),
            (PathBuf::from("/run"), Mask::Appear),
        ]);
        let mut check = |fired| concerns_sockets(&mut targets, &roots, fired);
        assert!(check(entry("/tmp/cmux-tui-501", Some("work.sock"))));
        assert!(check(entry("/tmp/cmux-tui-501", None)), "kqueue names no entry");
        assert!(!check(entry("/tmp/cmux-tui-501", Some("work.pid"))));
        assert!(check(entry("/run", Some("cmux-tui-hashed-501"))));
        assert!(!check(entry("/run", Some("unrelated.txt"))));
        assert!(!check(entry("/run", None)), "no root under /run exists here");
        assert!(!check(entry("/elsewhere", Some("work.sock"))));
        assert!(check(vec![Fired::Overflow]));
        assert!(check(vec![Fired::Gone { dir: PathBuf::from("/tmp/cmux-tui-501") }]));
        assert!(
            !targets.contains_key(Path::new("/tmp/cmux-tui-501")),
            "a gone root is watched again"
        );
    }

    /// $TMPDIR holds the existing root and is the parent of the missing
    /// hashed root: other entries changing in $TMPDIR (kqueue does not name
    /// them) are not changes because the existing root has its own watch.
    #[test]
    fn an_existing_sibling_root_does_not_make_parent_churn_a_change() {
        let base = scratch("sibling");
        let root = base.join("cmux-tui-501");
        let hashed = base.join("cmux-tui-hashed-501");
        std::fs::create_dir(&root).unwrap();
        let roots = [root.clone(), hashed.clone()];
        let (mut targets, found_all) = watch_targets(&roots);
        assert!(found_all);
        assert_eq!(targets, Targets::from([(root, Mask::Entries), (base.clone(), Mask::Appear)]));
        let unnamed = || vec![Fired::Entry { dir: base.clone(), name: None }];
        assert!(!concerns_sockets(&mut targets, &roots, unnamed()));
        std::fs::create_dir(&hashed).unwrap();
        assert!(concerns_sockets(&mut targets, &roots, unnamed()));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_missing_root_is_watched_through_its_parent() {
        let base = scratch("targets");
        let root = base.join("cmux-tui-501");
        let (targets, found_all) = watch_targets(std::slice::from_ref(&root));
        assert!(found_all);
        assert_eq!(targets, Targets::from([(base.clone(), Mask::Appear)]));
        std::fs::create_dir(&root).unwrap();
        let (targets, _) = watch_targets(std::slice::from_ref(&root));
        assert_eq!(targets, Targets::from([(root, Mask::Entries)]));
        let orphan = base.join("missing").join("cmux-tui-501");
        assert!(!watch_targets(&[orphan]).1, "no root and no parent: not complete");
        let _ = std::fs::remove_dir_all(&base);
    }

    /// The forwarder wakes when a socket is bound in a root that did not
    /// exist at start, with no scan period; unrelated file work in the
    /// watched parent (a busy /tmp) neither changes anything nor returns
    /// from `changed`.
    #[tokio::test]
    async fn a_socket_bound_in_a_new_root_wakes_the_forwarder_and_parent_work_does_not() {
        let base = scratch("bind");
        let root = base.join("cmux-tui-77");
        let unrelated = base.join("unrelated.txt");
        std::fs::write(&unrelated, b"seed").unwrap();
        let mut dirs = SocketDirs::new(vec![root.clone()]);
        let mut changes = dirs.subscribe();
        assert!(dirs.reconcile().await, "the parent is watched");
        changes.borrow_and_update();

        for _ in 0..200 {
            std::fs::write(&unrelated, b"unrelated work").unwrap();
            let _ = std::fs::read(&unrelated).unwrap();
        }
        assert!(
            tokio::time::timeout(Duration::from_millis(300), dirs.changed()).await.is_err(),
            "file work in the parent is not a change"
        );
        assert!(!changes.has_changed().unwrap());

        std::fs::create_dir(&root).unwrap();
        tokio::time::timeout(Duration::from_secs(10), dirs.changed())
            .await
            .expect("the new root is a change");
        assert!(changes.has_changed().unwrap());
        assert!(dirs.reconcile().await, "the root itself is watched now");
        changes.borrow_and_update();

        let _listener = std::os::unix::net::UnixListener::bind(root.join("session.sock")).unwrap();
        tokio::time::timeout(Duration::from_secs(10), dirs.changed())
            .await
            .expect("the bound socket is a change");
        assert!(changes.has_changed().unwrap());
        let _ = std::fs::remove_dir_all(&base);
    }
}
