//! Linux: the git HEAD watch's inotify watch, which asks only for the events that can change a
//! HEAD: an entry made, removed, moved or written in a watched folder, and the folder itself
//! removed or moved.
//!
//! Not `notify`'s inotify watcher: it always asks for `IN_OPEN` (notify 8.2), so every program
//! that opened a file in a watched folder woke the daemon. The HEAD cache watches a repository's
//! git dir, which each `git` command opens files in (`HEAD`, `config`, `index`): an editor's or
//! a prompt's `git status` woke an idle daemon twice per command, and on CI the checkout's git
//! dir woke it in every window of `tests/idle_wakeups.rs`. acpmux's folder watch dropped
//! `IN_OPEN` for the same reason (`acpmux/src/quiet_dirs.rs`).
//!
//! Each event reaches its sender as a `notify::Event`, so the HEAD watch reads both watchers
//! alike: a named entry is the folder joined with its name, a removed or moved folder is a
//! `Remove` of the folder, and a lost queue is an error (every value is stale). The reading
//! thread blocks in `poll` on the inotify descriptor and a pipe; dropping the watch writes to
//! the pipe and the thread ends. No timers.

use std::collections::HashMap;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, PoisonError};

use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};
use notify::event::{CreateKind, ModifyKind, RemoveKind};
use notify::{Event, EventKind};

/// What a watched folder is asked for. No `IN_OPEN`, `IN_ACCESS` or `IN_CLOSE_NOWRITE`: a read
/// changes no HEAD. `IN_CLOSE_WRITE` keeps a HEAD written in place (git itself renames
/// `HEAD.lock` over it: `IN_MOVED_TO`).
fn mask() -> WatchMask {
    WatchMask::CREATE
        | WatchMask::DELETE
        | WatchMask::MOVED_FROM
        | WatchMask::MOVED_TO
        | WatchMask::CLOSE_WRITE
        | WatchMask::DELETE_SELF
        | WatchMask::MOVE_SELF
        | WatchMask::ONLYDIR
}

struct State {
    watches: Watches,
    by_wd: HashMap<WatchDescriptor, PathBuf>,
    by_dir: HashMap<PathBuf, WatchDescriptor>,
}

/// The watch over the HEAD cache's folders, and its reading thread.
pub(super) struct QuietWatch {
    state: Arc<Mutex<State>>,
    /// Dropped with the watch: the reading thread's `poll` wakes and it ends.
    _stop: OwnedFd,
}

impl QuietWatch {
    /// Starts the reading thread (named `name`), which sends each event on `tx` until this is
    /// dropped or `tx`'s receiver is gone. It watches nothing until [`QuietWatch::add`].
    pub(super) fn start(tx: Sender<notify::Result<Event>>, name: &str) -> std::io::Result<Self> {
        let mut inotify = Inotify::init()?;
        let mut pipe = [0 as RawFd; 2];
        // SAFETY: `pipe` has room for the two descriptors pipe2 writes.
        if unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: pipe2 succeeded, so both descriptors are open and owned only here.
        let (read_end, write_end) =
            unsafe { (OwnedFd::from_raw_fd(pipe[0]), OwnedFd::from_raw_fd(pipe[1])) };
        let state = Arc::new(Mutex::new(State {
            watches: inotify.watches(),
            by_wd: HashMap::new(),
            by_dir: HashMap::new(),
        }));
        let thread_state = state.clone();
        // task-owner: the QuietWatch; ends when it is dropped (its stop pipe) or `tx`'s receiver
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
                    let mut state = thread_state.lock().unwrap_or_else(PoisonError::into_inner);
                    for event in events {
                        if event.mask.contains(EventMask::Q_OVERFLOW) {
                            out.push(Err(notify::Error::generic("inotify queue overflow")));
                            continue;
                        }
                        let Some(dir) = state.by_wd.get(&event.wd).cloned() else { continue };
                        if event.mask.contains(EventMask::IGNORED) {
                            // The folder is gone, or its watch was removed: its values are read
                            // again (a removed watch's folder is no longer cached).
                            state.by_wd.remove(&event.wd);
                            if state.by_dir.get(&dir) == Some(&event.wd) {
                                state.by_dir.remove(&dir);
                            }
                            out.push(Ok(removed(dir)));
                            continue;
                        }
                        if event.mask.intersects(EventMask::DELETE_SELF | EventMask::MOVE_SELF) {
                            out.push(Ok(removed(dir)));
                            continue;
                        }
                        let Some(name) = event.name else { continue };
                        let kind =
                            if event.mask.intersects(EventMask::DELETE | EventMask::MOVED_FROM) {
                                EventKind::Remove(RemoveKind::Any)
                            } else if event.mask.contains(EventMask::CREATE) {
                                EventKind::Create(CreateKind::Any)
                            } else {
                                EventKind::Modify(ModifyKind::Any)
                            };
                        out.push(Ok(Event::new(kind).add_path(dir.join(name))));
                    }
                }
                for sent in out {
                    if tx.send(sent).is_err() {
                        return;
                    }
                }
            }
        })?;
        Ok(Self { state, _stop: write_end })
    }

    /// Watches `dir` (non-recursive).
    pub(super) fn add(&self, dir: &Path) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.by_dir.contains_key(dir) {
            return Ok(());
        }
        let wd = state.watches.add(dir, mask())?;
        // Two paths of one folder share its watch descriptor: the last one names it.
        if let Some(old) = state.by_wd.insert(wd.clone(), dir.to_path_buf()) {
            state.by_dir.remove(&old);
        }
        state.by_dir.insert(dir.to_path_buf(), wd);
        Ok(())
    }

    /// Takes the watch off `dir`.
    pub(super) fn remove(&self, dir: &Path) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(wd) = state.by_dir.remove(dir) {
            state.by_wd.remove(&wd);
            let _ = state.watches.remove(wd);
        }
    }
}

fn removed(dir: PathBuf) -> Event {
    Event::new(EventKind::Remove(RemoveKind::Folder)).add_path(dir)
}

#[cfg(test)]
mod tests {
    use super::QuietWatch;
    use std::sync::mpsc::{RecvTimeoutError, channel};
    use std::time::Duration;

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let stamp =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-quiet-head-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::canonicalize(dir).unwrap()
    }

    /// A read of a watched folder's files sends nothing; a HEAD renamed over (as git writes it)
    /// and a HEAD written in place each send their path.
    #[test]
    fn reads_send_nothing_and_head_writes_send_their_path() {
        let dir = temp_dir("reads");
        std::fs::write(dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(dir.join("config"), "[core]\n").unwrap();
        let (tx, rx) = channel();
        let watch = QuietWatch::start(tx, "quiet-head-test").unwrap();
        watch.add(&dir).unwrap();
        for _ in 0..20 {
            let _ = std::fs::read(dir.join("HEAD")).unwrap();
            let _ = std::fs::read(dir.join("config")).unwrap();
        }
        assert!(
            matches!(rx.recv_timeout(Duration::from_millis(300)), Err(RecvTimeoutError::Timeout)),
            "a read sent an event"
        );

        std::fs::write(dir.join("HEAD.lock"), "ref: refs/heads/next\n").unwrap();
        std::fs::rename(dir.join("HEAD.lock"), dir.join("HEAD")).unwrap();
        let mut paths = Vec::new();
        while let Ok(event) = rx.recv_timeout(Duration::from_millis(300)) {
            paths.extend(event.unwrap().paths);
        }
        assert!(paths.contains(&dir.join("HEAD")), "{paths:?}");

        std::fs::write(dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        let event = rx.recv_timeout(Duration::from_secs(2)).unwrap().unwrap();
        assert!(event.paths.contains(&dir.join("HEAD")), "{event:?}");
        drop(watch);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A watched folder removed sends a `Remove` of the folder, so its values are read again.
    #[test]
    fn a_removed_folder_sends_its_own_path() {
        let dir = temp_dir("gone");
        let (tx, rx) = channel();
        let watch = QuietWatch::start(tx, "quiet-head-test").unwrap();
        watch.add(&dir).unwrap();
        std::fs::remove_dir(&dir).unwrap();
        let mut removed = false;
        while let Ok(event) = rx.recv_timeout(Duration::from_secs(2)) {
            let event = event.unwrap();
            if matches!(event.kind, notify::EventKind::Remove(_)) && event.paths.contains(&dir) {
                removed = true;
                break;
            }
        }
        assert!(removed, "no remove of the folder");
        drop(watch);
    }
}
