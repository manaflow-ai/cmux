//! Linux: the HEAD watch's inotify watcher, asking only for the events that can change a HEAD.
//!
//! Not `notify`'s inotify watcher: notify 8.2 always adds `IN_OPEN` to the mask, so every open
//! and close of a file in a watched git dir (`git status`, an editor's or a prompt's look at the
//! repository, a CI runner reading the checkout) woke the daemon's notify thread and the
//! `git-head-watch` thread, which only then dropped the read (`Fired::add`). An idle daemon whose
//! terminal sat in a busy repository woke in every window of `tests/idle_wakeups.rs` (cmux-tui
//! artifacts runs 46128450939 and 46132247802). The same class as `acpmux/src/quiet_dirs.rs` and
//! `cmux-config/src/watch/inotify.rs`.
//!
//! Each directory is watched for entries made, removed or moved, files closed after a write, and
//! the directory itself removed or moved: git renames `HEAD.lock` over `HEAD` (a move in), a
//! plain write of `HEAD` closes it, `git init` makes `.git`. Each event reaches the sender as a
//! `notify::Event` naming the path (the directory joined with the entry's name), of the kind
//! notify gives it, so [`super::Fired`] reads both watchers alike; a queue overflow is sent as an
//! error (every value stale).
//!
//! The reading thread blocks in `poll` on the inotify descriptor and a pipe; dropping the watch
//! writes to the pipe, and the thread ends and drops its sender (which ends `run_watch`).

use crate::panic_free::RecoverPoison;
use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};
use std::collections::HashMap;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

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

pub(super) struct QuietWatch {
    state: Arc<Mutex<State>>,
    stop: OwnedFd,
}

impl QuietWatch {
    /// Starts the reading thread (named `name`), which sends each event on `tx` until this is
    /// dropped or `tx`'s receiver is gone. Watches nothing until [`Self::add`].
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
        let (read_end, write_end) = unsafe {
            use std::os::fd::FromRawFd;
            (OwnedFd::from_raw_fd(pipe[0]), OwnedFd::from_raw_fd(pipe[1]))
        };
        let state = Arc::new(Mutex::new(State {
            watches: inotify.watches(),
            by_wd: HashMap::new(),
            by_dir: HashMap::new(),
        }));
        let thread_state = state.clone();
        // task-owner: the QuietWatch (the session's HeadWatch); ends when it is dropped (its stop
        // pipe) or `tx`'s receiver is gone.
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
                let mut out = Vec::new();
                {
                    let mut state = thread_state.lock().recover_poison();
                    for event in events {
                        if event.mask.contains(EventMask::Q_OVERFLOW) {
                            out.push(Err(notify::Error::generic("inotify queue overflow")));
                            continue;
                        }
                        let Some(dir) = state.by_wd.get(&event.wd).cloned() else { continue };
                        if event.mask.contains(EventMask::IGNORED) {
                            // The directory is gone (its DELETE_SELF came first) or unwatched.
                            if state.by_dir.get(&dir) == Some(&event.wd) {
                                state.by_dir.remove(&dir);
                            }
                            state.by_wd.remove(&event.wd);
                            continue;
                        }
                        if let Some(sent) = to_event(event.mask, &dir, event.name) {
                            out.push(Ok(sent));
                        }
                    }
                }
                for sent in out {
                    if tx.send(sent).is_err() {
                        return;
                    }
                }
            }
        })?;
        Ok(Self { state, stop: write_end })
    }

    /// Watches `dir` (non-recursive).
    pub(super) fn add(&self, dir: &Path) -> std::io::Result<()> {
        let mut state = self.state.lock().recover_poison();
        if state.by_dir.contains_key(dir) {
            return Ok(());
        }
        let wd = state.watches.add(dir, mask())?;
        // A second path to the same inode shares its descriptor: the newest name is reported.
        if let Some(old) = state.by_wd.insert(wd.clone(), dir.to_path_buf()) {
            state.by_dir.remove(&old);
        }
        state.by_dir.insert(dir.to_path_buf(), wd);
        Ok(())
    }

    /// Takes the watch off `dir`.
    pub(super) fn remove(&self, dir: &Path) {
        let mut state = self.state.lock().recover_poison();
        if let Some(wd) = state.by_dir.remove(dir) {
            state.by_wd.remove(&wd);
            let _ = state.watches.remove(wd);
        }
    }
}

impl Drop for QuietWatch {
    fn drop(&mut self) {
        // SAFETY: `stop` is an open pipe write end owned by self; one byte from a valid buffer.
        let _ = unsafe { libc::write(self.stop.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
    }
}

/// The `notify::Event` for `mask` on `dir`'s entry `name` (or `dir` itself), of the kind notify's
/// own inotify watcher gives; `None` for an event that changes nothing `dir` holds.
fn to_event(mask: EventMask, dir: &Path, name: Option<&std::ffi::OsStr>) -> Option<notify::Event> {
    use notify::event::{CreateKind, ModifyKind, RemoveKind, RenameMode};
    use notify::{Event, EventKind};
    if mask.intersects(EventMask::DELETE_SELF | EventMask::MOVE_SELF) {
        // A watched directory that went away: `Fired::add` takes a removed path as one.
        return Some(Event::new(EventKind::Remove(RemoveKind::Folder)).add_path(dir.to_path_buf()));
    }
    let path = dir.join(name?);
    let kind = if mask.intersects(EventMask::CREATE) {
        EventKind::Create(CreateKind::Any)
    } else if mask.intersects(EventMask::MOVED_TO) {
        EventKind::Modify(ModifyKind::Name(RenameMode::To))
    } else if mask.intersects(EventMask::MOVED_FROM) {
        EventKind::Modify(ModifyKind::Name(RenameMode::From))
    } else if mask.intersects(EventMask::DELETE) {
        EventKind::Remove(RemoveKind::Any)
    } else if mask.intersects(EventMask::CLOSE_WRITE) {
        // Once per write, not per `write(2)` (notify's MODIFY): a change of the file, not the
        // read `Fired::add` drops.
        EventKind::Modify(ModifyKind::Data(notify::event::DataChange::Any))
    } else {
        return None;
    };
    Some(Event::new(kind).add_path(path))
}
