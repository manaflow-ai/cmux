//! Linux: the git HEAD watch's inotify watch, non-recursive, asking only for the events that can
//! change a HEAD: an entry made, removed or moved (git renames `HEAD.lock` over `HEAD`; a `.git`
//! made or removed), a file written and closed (a HEAD or `.git` file rewritten in place), and the
//! folder itself removed or moved.
//!
//! Not `notify`'s inotify watcher: it always asks for `IN_OPEN` (notify 8.2). A watched git dir is
//! opened by every git command, editor and build that looks at the repository (an idle daemon
//! launched in a checkout watches the checkout's `.git`), and each open woke the watch's threads
//! though `Fired::add` then dropped the event as a read (`tests/idle_wakeups.rs` found
//! `git-head-watch` and notify's thread running in every window). The same class as
//! `acpmux/src/quiet_dirs.rs` and `cmux-config/src/watch/inotify.rs`.
//!
//! Each event reaches the receiver as the `notify::Event` the notify watcher sent (so `Fired`
//! reads both the same way): a removal names its path, a lost queue is an error. The reading
//! thread blocks in `poll` on the inotify descriptor and a pipe; dropping the watch closes the
//! pipe, and the thread ends and drops its sender.

use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};
use std::collections::HashMap;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, PoisonError};

/// Every event that can change the HEAD read from a folder; never an open, a read or a close
/// with no write.
const MASK: WatchMask = WatchMask::CREATE
    .union(WatchMask::DELETE)
    .union(WatchMask::MOVED_FROM)
    .union(WatchMask::MOVED_TO)
    .union(WatchMask::CLOSE_WRITE)
    .union(WatchMask::DELETE_SELF)
    .union(WatchMask::MOVE_SELF)
    .union(WatchMask::ONLYDIR);

/// Live while held: dropping it ends the reading thread.
pub(super) struct HeadInotify {
    watches: Watches,
    /// The folder of each watch, shared with the reading thread.
    by_wd: Arc<Mutex<HashMap<WatchDescriptor, PathBuf>>>,
    by_dir: HashMap<PathBuf, WatchDescriptor>,
    /// Closed on drop: the reading thread ends.
    _stop: OwnedFd,
}

impl HeadInotify {
    /// Starts the reading thread (named `name`), which sends each event on `tx` until this is
    /// dropped or `tx`'s receiver is gone.
    pub(super) fn start(
        tx: Sender<notify::Result<notify::Event>>,
        name: &str,
    ) -> std::io::Result<Self> {
        let mut inotify = Inotify::init()?;
        let mut pipe = [0 as RawFd; 2];
        // SAFETY: `pipe` has room for the two descriptors pipe2 writes.
        if unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: pipe2 succeeded, so both descriptors are open and owned only here.
        let (read_end, write_end) =
            unsafe { (OwnedFd::from_raw_fd(pipe[0]), OwnedFd::from_raw_fd(pipe[1])) };
        let watches = inotify.watches();
        let by_wd: Arc<Mutex<HashMap<WatchDescriptor, PathBuf>>> = Arc::default();
        let thread_by_wd = Arc::clone(&by_wd);
        // task-owner: the HeadInotify; ends when it is dropped (its stop pipe) or `tx`'s receiver
        // is gone.
        std::thread::Builder::new().name(name.into()).spawn(move || {
            let mut buffer = vec![0u8; 4096];
            loop {
                let mut fds = [
                    libc::pollfd { fd: inotify.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                    libc::pollfd { fd: read_end.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                ];
                // SAFETY: `fds` is a valid array of two pollfd for the call.
                let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) };
                if ready < 0 {
                    let error = std::io::Error::last_os_error();
                    if error.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    let _ = tx.send(Err(notify::Error::io(error)));
                    return;
                }
                if fds[1].revents != 0 {
                    return;
                }
                let events = match inotify.read_events(&mut buffer) {
                    Ok(events) => events,
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                        ) =>
                    {
                        continue;
                    }
                    Err(error) => {
                        let _ = tx.send(Err(notify::Error::io(error)));
                        return;
                    }
                };
                let mut out = Vec::new();
                {
                    let mut by_wd = thread_by_wd.lock().unwrap_or_else(PoisonError::into_inner);
                    for event in events {
                        if event.mask.contains(EventMask::Q_OVERFLOW) {
                            out.push(Err(notify::Error::generic("inotify queue overflow")));
                            continue;
                        }
                        if event.mask.contains(EventMask::IGNORED) {
                            by_wd.remove(&event.wd);
                            continue;
                        }
                        let Some(dir) = by_wd.get(&event.wd) else { continue };
                        out.push(Ok(to_event(dir, event.mask, event.name)));
                    }
                }
                for sent in out {
                    if tx.send(sent).is_err() {
                        return;
                    }
                }
            }
        })?;
        Ok(Self { watches, by_wd, by_dir: HashMap::new(), _stop: write_end })
    }

    /// Watches `dir`; whether the watch holds it.
    pub(super) fn add(&mut self, dir: &Path) -> bool {
        let Ok(wd) = self.watches.add(dir, MASK) else { return false };
        self.by_wd.lock().unwrap_or_else(PoisonError::into_inner).insert(wd.clone(), dir.into());
        self.by_dir.insert(dir.to_path_buf(), wd);
        true
    }

    /// Takes the watch off `dir`.
    pub(super) fn remove(&mut self, dir: &Path) {
        let Some(wd) = self.by_dir.remove(dir) else { return };
        self.by_wd.lock().unwrap_or_else(PoisonError::into_inner).remove(&wd);
        let _ = self.watches.remove(wd);
    }

    /// The folders watched now.
    #[cfg(test)]
    pub(super) fn dirs(&self) -> Vec<PathBuf> {
        self.by_dir.keys().cloned().collect()
    }
}

/// The `notify::Event` of one inotify event in `dir`: a removal (the entry, or the folder itself)
/// is a `Remove` naming its path, anything else a `Modify` naming the entry.
fn to_event(dir: &Path, mask: EventMask, name: Option<&std::ffi::OsStr>) -> notify::Event {
    use notify::event::{EventKind, ModifyKind, RemoveKind};
    let path = name.map_or_else(|| dir.to_path_buf(), |name| dir.join(name));
    let kind = if mask.intersects(EventMask::DELETE | EventMask::DELETE_SELF | EventMask::MOVE_SELF)
    {
        EventKind::Remove(RemoveKind::Any)
    } else {
        EventKind::Modify(ModifyKind::Any)
    };
    notify::Event::new(kind).add_path(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::{Receiver, RecvTimeoutError};
    use std::time::Duration;

    /// A folder of the test's own, removed with it.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let dir = std::env::temp_dir()
                .join(format!("cmux-git-head-inotify-{name}-{}-{stamp}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn next(rx: &Receiver<notify::Result<notify::Event>>) -> Option<notify::Event> {
        match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(event) => Some(event.expect("no watch error")),
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => None,
        }
    }

    fn quiet(rx: &Receiver<notify::Result<notify::Event>>) -> bool {
        matches!(rx.recv_timeout(Duration::from_millis(300)), Err(RecvTimeoutError::Timeout))
    }

    /// Opens and reads of the files of a watched git dir send nothing (notify's watcher sent an
    /// event per open); a HEAD renamed in, written in place or removed, and the folder removed,
    /// each send an event naming its path.
    #[test]
    fn a_watched_git_dir_reports_head_changes_and_never_its_reads() {
        let root = Scratch::new("reads");
        let git = root.path().join(".git");
        std::fs::create_dir(&git).unwrap();
        std::fs::write(git.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(git.join("config"), "").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watch = HeadInotify::start(tx, "git-head-watch-test").unwrap();
        assert!(watch.add(&git));

        for _ in 0..20 {
            std::fs::read(git.join("HEAD")).unwrap();
            std::fs::read(git.join("config")).unwrap();
            let _ = std::fs::read_dir(&git).unwrap().count();
        }
        assert!(quiet(&rx), "a read of a watched git dir sent an event");

        // git's switch: HEAD.lock written, then renamed over HEAD.
        std::fs::write(git.join("HEAD.lock"), "ref: refs/heads/other\n").unwrap();
        std::fs::rename(git.join("HEAD.lock"), git.join("HEAD")).unwrap();
        let mut paths = Vec::new();
        while let Some(event) = next(&rx) {
            paths.extend(event.paths);
            if paths.contains(&git.join("HEAD")) {
                break;
            }
        }
        assert!(paths.contains(&git.join("HEAD")), "{paths:?}");
        while !quiet(&rx) {}

        std::fs::write(git.join("HEAD"), "0123\n").unwrap();
        let event = next(&rx).expect("a HEAD written in place");
        assert_eq!(event.paths, [git.join("HEAD")]);
        while !quiet(&rx) {}

        std::fs::remove_file(git.join("config")).unwrap();
        std::fs::remove_file(git.join("HEAD")).unwrap();
        std::fs::remove_dir(&git).unwrap();
        let mut removed = Vec::new();
        while let Some(event) = next(&rx) {
            assert!(matches!(event.kind, notify::EventKind::Remove(_)), "{event:?}");
            removed.extend(event.paths);
            if removed.contains(&git) {
                break;
            }
        }
        assert!(removed.contains(&git.join("HEAD")), "{removed:?}");
        assert!(removed.contains(&git), "{removed:?}");
    }

    /// A folder taken off the watch sends nothing more, and dropping the watch ends its thread
    /// (the receiver sees the sender gone).
    #[test]
    fn a_removed_or_dropped_watch_goes_quiet() {
        let root = Scratch::new("removed");
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watch = HeadInotify::start(tx, "git-head-watch-test").unwrap();
        assert!(watch.add(root.path()));
        assert_eq!(watch.dirs(), [root.path().to_path_buf()]);
        watch.remove(root.path());
        assert!(watch.dirs().is_empty());
        std::fs::write(root.path().join(".git"), "gitdir: elsewhere\n").unwrap();
        assert!(quiet(&rx), "a removed watch sent an event");
        drop(watch);
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(5)),
            Err(RecvTimeoutError::Disconnected)
        ));
    }
}
