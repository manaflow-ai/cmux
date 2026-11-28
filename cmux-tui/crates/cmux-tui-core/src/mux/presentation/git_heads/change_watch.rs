//! Linux: the git HEAD watch's inotify watch, asking only for the events that can change a HEAD
//! or make a `.git`: entries made, removed and moved, a file written and closed, and the folder
//! itself removed or moved. Each event reaches the sender as a `notify::Event` naming the path
//! (the folder joined with the entry's name, or the folder when it went away); a queue overflow
//! is sent as a rescan.
//!
//! Not `notify`'s inotify watcher: it always asks for `IN_OPEN` (notify 8.2), and a watched git
//! dir is opened by every git command and every reader of its HEAD (another daemon's refresh,
//! an editor, a prompt). Each open woke `notify`'s thread and this watch's thread, though none is
//! a change: an idle daemon whose tab was in a busy repository ran both threads in every window
//! (`tests/idle_wakeups.rs`: `git-head-watch` and `notify-rs inoti` in each of 3 windows of 12 s,
//! 11 to 26 switches a window, on feat-cmux-next from 11-27 22Z). The class and its first fix:
//! acpmux `quiet_dirs.rs`.
//!
//! The reading thread blocks in `poll` on the inotify descriptor and a pipe; dropping the watch
//! writes to the pipe, and the thread ends and drops its sender.

use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};
use std::collections::HashMap;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, PoisonError};

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

#[derive(Default)]
struct State {
    by_dir: HashMap<PathBuf, WatchDescriptor>,
    by_wd: HashMap<WatchDescriptor, PathBuf>,
}

/// A non-recursive watch of a set of folders, for changes only.
pub(super) struct ChangeWatch {
    watches: Watches,
    state: Arc<Mutex<State>>,
    stop: OwnedFd,
}

impl ChangeWatch {
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
        let (read_end, write_end) = unsafe {
            use std::os::fd::FromRawFd;
            (OwnedFd::from_raw_fd(pipe[0]), OwnedFd::from_raw_fd(pipe[1]))
        };
        let watches = inotify.watches();
        let state = Arc::new(Mutex::new(State::default()));
        let thread_state = state.clone();
        // task-owner: the ChangeWatch; ends when it is dropped (its stop pipe) or `tx`'s receiver
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
                let mut out = Vec::new();
                {
                    let mut state = thread_state.lock().unwrap_or_else(PoisonError::into_inner);
                    for event in events {
                        if event.mask.contains(EventMask::Q_OVERFLOW) {
                            out.push(
                                notify::Event::new(notify::EventKind::Other)
                                    .set_flag(notify::event::Flag::Rescan),
                            );
                            continue;
                        }
                        let Some(dir) = state.by_wd.get(&event.wd).cloned() else { continue };
                        if event.mask.intersects(
                            EventMask::IGNORED | EventMask::DELETE_SELF | EventMask::MOVE_SELF,
                        ) {
                            // The folder went away (or its watch did): its values must be read again.
                            if event.mask.contains(EventMask::IGNORED)
                                && let Some(path) = state.by_wd.remove(&event.wd)
                                && state.by_dir.get(&path) == Some(&event.wd)
                            {
                                state.by_dir.remove(&path);
                            }
                            out.push(
                                notify::Event::new(notify::EventKind::Remove(
                                    notify::event::RemoveKind::Folder,
                                ))
                                .add_path(dir),
                            );
                            continue;
                        }
                        let path = event.name.map_or_else(|| dir.clone(), |name| dir.join(name));
                        let kind =
                            if event.mask.intersects(EventMask::DELETE | EventMask::MOVED_FROM) {
                                notify::EventKind::Remove(notify::event::RemoveKind::Any)
                            } else if event.mask.intersects(EventMask::CREATE | EventMask::MOVED_TO)
                            {
                                notify::EventKind::Create(notify::event::CreateKind::Any)
                            } else {
                                notify::EventKind::Modify(notify::event::ModifyKind::Any)
                            };
                        out.push(notify::Event::new(kind).add_path(path));
                    }
                }
                for event in out {
                    if tx.send(Ok(event)).is_err() {
                        return;
                    }
                }
            }
        })?;
        Ok(Self { watches, state, stop: write_end })
    }

    /// Watches `dir`; false when the kernel refused it (a missing folder, the watch limit).
    pub(super) fn add(&mut self, dir: &Path) -> bool {
        let Ok(wd) = self.watches.add(dir, mask()) else { return false };
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.by_wd.insert(wd.clone(), dir.to_path_buf());
        state.by_dir.insert(dir.to_path_buf(), wd);
        true
    }

    /// Stops watching `dir`.
    pub(super) fn remove(&mut self, dir: &Path) {
        let wd = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(wd) = state.by_dir.remove(dir) else { return };
            state.by_wd.remove(&wd);
            wd
        };
        let _ = self.watches.remove(wd);
    }
}

impl Drop for ChangeWatch {
    fn drop(&mut self) {
        // SAFETY: `stop` is the open write end of the pipe; one byte from a valid buffer.
        let _ = unsafe { libc::write(self.stop.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
    }
}
