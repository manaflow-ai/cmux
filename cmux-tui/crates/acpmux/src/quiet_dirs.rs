//! Linux: an inotify watch over a few folders, non-recursive, that asks only for the events
//! that can change what a folder holds, with folders added and removed while it runs. Each event
//! reaches its sender as a `notify::Event` naming the path (the folder joined with the entry's
//! name); a queue overflow (events lost) is sent as an error.
//!
//! Not `notify`'s inotify watcher: it always asks for `IN_OPEN` (notify 8.2), so a watched folder
//! that every program opens files in sent an event per open. The harness profile watch watches
//! the nearest existing ancestor of a missing source folder, which for `/etc/cmux/harnesses` is
//! `/etc`: an idle daemon then woke for every program that started (`tests/daemon_idle.rs`). A
//! folder watched only for its entries (an ancestor on the way to a missing folder) is asked
//! for entries made, removed and moved, and nothing else.
//!
//! The reading thread blocks in `poll` on the inotify descriptor and a pipe; dropping the watch
//! writes to the pipe, and the thread ends and drops its sender.

use std::collections::HashMap;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, PoisonError};

use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};

/// What a folder's watch reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    /// Every change of a file in it, or of the folder itself.
    Changes,
    /// Only entries made, removed or moved, and the folder itself removed or moved.
    Entries,
}

fn mask(kind: Kind) -> WatchMask {
    let entries = WatchMask::CREATE
        | WatchMask::DELETE
        | WatchMask::MOVED_FROM
        | WatchMask::MOVED_TO
        | WatchMask::DELETE_SELF
        | WatchMask::MOVE_SELF
        | WatchMask::ONLYDIR;
    match kind {
        Kind::Entries => entries,
        Kind::Changes => entries | WatchMask::ATTRIB | WatchMask::CLOSE_WRITE | WatchMask::MODIFY,
    }
}

type Folders = Arc<Mutex<HashMap<WatchDescriptor, PathBuf>>>;

/// Live while held: dropping it ends the reading thread.
pub(crate) struct QuietDirs {
    watches: Watches,
    folders: Folders,
    by_path: HashMap<PathBuf, WatchDescriptor>,
    stop: OwnedFd,
}

impl QuietDirs {
    /// Starts the reading thread (named `name`), which sends each event on `tx` until this is
    /// dropped or `tx`'s receiver is gone.
    pub(crate) fn start(
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
        let (read_end, write_end) = unsafe {
            use std::os::fd::FromRawFd;
            (OwnedFd::from_raw_fd(pipe[0]), OwnedFd::from_raw_fd(pipe[1]))
        };
        let watches = inotify.watches();
        let folders: Folders = Arc::default();
        let thread_folders = folders.clone();
        // task-owner: the QuietDirs; ends when it is dropped (its stop pipe) or `tx`'s receiver
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
                    let e = std::io::Error::last_os_error();
                    if e.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    let _ = tx.send(Err(notify::Error::io(e)));
                    return;
                }
                if fds[1].revents != 0 {
                    return;
                }
                let events = match inotify.read_events(&mut buffer) {
                    Ok(events) => events,
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                        ) =>
                    {
                        continue;
                    }
                    Err(e) => {
                        let _ = tx.send(Err(notify::Error::io(e)));
                        return;
                    }
                };
                for event in events {
                    let sent = if event.mask.contains(EventMask::Q_OVERFLOW) {
                        Err(notify::Error::generic("inotify queue overflow"))
                    } else {
                        let mut folders =
                            thread_folders.lock().unwrap_or_else(PoisonError::into_inner);
                        let Some(dir) = folders.get(&event.wd).cloned() else { continue };
                        if event.mask.contains(EventMask::IGNORED) {
                            folders.remove(&event.wd);
                            continue;
                        }
                        let path = event.name.map_or_else(|| dir.clone(), |n| dir.join(n));
                        Ok(notify::Event::new(notify::EventKind::Any).add_path(path))
                    };
                    if tx.send(sent).is_err() {
                        return;
                    }
                }
            }
        })?;
        Ok(Self { watches, folders, by_path: HashMap::new(), stop: write_end })
    }

    /// Watches `dir` for `kind`; false when it cannot be watched (gone, not a folder).
    pub(crate) fn watch(&mut self, dir: &Path, kind: Kind) -> bool {
        let Ok(wd) = self.watches.add(dir, mask(kind)) else { return false };
        self.folders.lock().unwrap_or_else(PoisonError::into_inner).insert(wd.clone(), dir.into());
        self.by_path.insert(dir.to_path_buf(), wd);
        true
    }

    /// Stops watching `dir` (nothing when it is not watched or already gone).
    pub(crate) fn unwatch(&mut self, dir: &Path) {
        if let Some(wd) = self.by_path.remove(dir) {
            self.folders.lock().unwrap_or_else(PoisonError::into_inner).remove(&wd);
            let _ = self.watches.remove(wd);
        }
    }
}

impl Drop for QuietDirs {
    fn drop(&mut self) {
        // SAFETY: `stop` is the open write end of the pipe; one byte from a valid buffer.
        let _ = unsafe { libc::write(self.stop.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// A folder watched for its entries sends nothing for a read or a write of a file in it, and
    /// sends a folder made in it; a folder watched for changes sends a write. Dropping the watch
    /// ends the thread, which drops its sender.
    #[test]
    fn an_entries_watch_ignores_opens_and_writes_and_sees_a_folder_made() {
        let base = tempfile::tempdir().unwrap();
        let ancestor = base.path().join("ancestor");
        let changes = base.path().join("changes");
        std::fs::create_dir_all(&ancestor).unwrap();
        std::fs::create_dir_all(&changes).unwrap();
        let file = ancestor.join("busy");
        std::fs::write(&file, "x").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let mut dirs = QuietDirs::start(tx, "quiet-dirs-test").unwrap();
        assert!(dirs.watch(&ancestor, Kind::Entries));
        assert!(dirs.watch(&changes, Kind::Changes));
        for _ in 0..20 {
            let _ = std::fs::read_to_string(&file).unwrap();
            std::fs::write(&file, "y").unwrap();
        }
        let quiet = rx.recv_timeout(Duration::from_millis(300));
        assert!(quiet.is_err(), "an open or a write sent an event: {quiet:?}");
        std::fs::create_dir(ancestor.join("made")).unwrap();
        let made = rx.recv_timeout(Duration::from_secs(5)).expect("a folder made sends");
        assert_eq!(made.unwrap().paths, vec![ancestor.join("made")]);
        std::fs::write(changes.join("profile.toml"), "x").unwrap();
        let wrote = rx.recv_timeout(Duration::from_secs(5)).expect("a write sends");
        assert_eq!(wrote.unwrap().paths[0], changes.join("profile.toml"));
        drop(dirs);
        // The thread ends: once what it already sent is read, the channel closes.
        let end = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            match rx.recv_timeout(end.saturating_duration_since(std::time::Instant::now())) {
                Ok(_) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                Err(e) => panic!("the reading thread did not end: {e:?}"),
            }
        }
    }
}
