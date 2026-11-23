//! Watching single files and directories (not recursively), and the sync
//! thread's one wait: for a change, the stop, or the next scan's deadline.
//!
//! macOS: kqueue (`EVFILT_VNODE` on each watched path, opened `O_EVTONLY`,
//! and `EVFILT_USER` for the stop), straight on libc. FSEvents would make the
//! app link CoreServices for the one archive every app target links, and
//! notify's kqueue backend is a crate feature that would also switch every
//! other cmux-tui crate's recursive watches off FSEvents.
//! Elsewhere: notify (inotify on Linux) and a channel for the stop.
//!
//! This file needs only std, libc and notify, so it can be compile-checked
//! for an Apple target on its own.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// What woke the sync thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Wake {
    /// `free`: end the thread.
    Stop,
    /// These watched files changed; `moved` when one was deleted or
    /// renamed (its watch must be made again on the path).
    Changed { paths: Vec<PathBuf>, moved: bool },
    /// The watcher lost events: every source may have changed.
    #[cfg_attr(
        target_os = "macos",
        allow(dead_code, reason = "kqueue loses no events: each watch coalesces its own")
    )]
    Rescan,
    /// The watch cannot go on (a short reason, no path).
    #[cfg_attr(
        not(target_os = "macos"),
        allow(
            dead_code,
            reason = "only the kqueue wait fails for good; notify's errors are a rescan"
        )
    )]
    Failed(String),
}

#[cfg(target_os = "macos")]
pub(crate) use kqueue::{FileWatch, Stopper};
#[cfg(not(target_os = "macos"))]
pub(crate) use portable::{FileWatch, Stopper};

#[cfg(target_os = "macos")]
mod kqueue {
    use super::Wake;
    use std::collections::BTreeMap;
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::Duration;

    /// The stop event's ident.
    const STOP: usize = 1;
    /// A write, a size change, a delete, a rename, or the volume gone. Not
    /// `NOTE_ATTRIB`: reading the file can touch its access time.
    const VNODE: u32 = libc::NOTE_WRITE
        | libc::NOTE_EXTEND
        | libc::NOTE_DELETE
        | libc::NOTE_RENAME
        | libc::NOTE_REVOKE;
    const MOVED: u32 = libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE;

    fn change(ident: usize, filter: i16, flags: u16, fflags: u32) -> libc::kevent {
        libc::kevent { ident, filter, flags, fflags, data: 0, udata: std::ptr::null_mut() }
    }

    /// Registers `changes` on `kq`.
    fn register(kq: &OwnedFd, changes: &[libc::kevent]) -> io::Result<()> {
        let count = libc::c_int::try_from(changes.len()).map_err(io::Error::other)?;
        // SAFETY: `changes` holds `count` events; no event list is read.
        let done = unsafe {
            libc::kevent(
                kq.as_raw_fd(),
                changes.as_ptr(),
                count,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        };
        if done < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
    }

    /// Wakes the sync thread's wait with its stop event.
    pub(crate) struct Stopper {
        kq: Arc<OwnedFd>,
    }

    impl Stopper {
        pub(crate) fn stop(&self) {
            let _ = register(&self.kq, &[change(STOP, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER)]);
        }
    }

    /// The watched files, each open `O_EVTONLY` (closing it drops its watch).
    pub(crate) struct FileWatch {
        kq: Arc<OwnedFd>,
        files: BTreeMap<PathBuf, File>,
        paths: BTreeMap<usize, PathBuf>,
    }

    impl FileWatch {
        pub(crate) fn new() -> io::Result<(Self, Stopper)> {
            // SAFETY: no arguments; the result is checked.
            let raw = unsafe { libc::kqueue() };
            if raw < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: a new descriptor that nothing else owns.
            let kq = Arc::new(unsafe { OwnedFd::from_raw_fd(raw) });
            register(&kq, &[change(STOP, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0)])?;
            let stopper = Stopper { kq: Arc::clone(&kq) };
            Ok((Self { kq, files: BTreeMap::new(), paths: BTreeMap::new() }, stopper))
        }

        pub(crate) fn watch(&mut self, path: &Path) -> io::Result<()> {
            let file =
                std::fs::OpenOptions::new().read(true).custom_flags(libc::O_EVTONLY).open(path)?;
            let ident = usize::try_from(file.as_raw_fd()).map_err(io::Error::other)?;
            register(
                &self.kq,
                &[change(ident, libc::EVFILT_VNODE, libc::EV_ADD | libc::EV_CLEAR, VNODE)],
            )?;
            self.paths.insert(ident, path.to_path_buf());
            if let Some(old) = self.files.insert(path.to_path_buf(), file) {
                self.forget(&old);
            }
            Ok(())
        }

        pub(crate) fn unwatch(&mut self, path: &Path) {
            if let Some(file) = self.files.remove(path) {
                self.forget(&file);
            }
        }

        fn forget(&mut self, file: &File) {
            if let Ok(ident) = usize::try_from(file.as_raw_fd()) {
                self.paths.remove(&ident);
            }
        }

        /// Blocks until a watched file changes, the stop, or `timeout`.
        pub(crate) fn wait(&mut self, timeout: Option<Duration>) -> Vec<Wake> {
            // SAFETY: an all-zero kevent and timespec are valid values.
            let mut events: [libc::kevent; 16] = unsafe { std::mem::zeroed() };
            // SAFETY: as above.
            let mut time: libc::timespec = unsafe { std::mem::zeroed() };
            let deadline = timeout.map(|timeout| {
                time.tv_sec =
                    libc::time_t::try_from(timeout.as_secs()).unwrap_or(libc::time_t::MAX);
                time.tv_nsec = libc::c_long::from(timeout.subsec_nanos());
                std::ptr::from_ref(&time)
            });
            let capacity = libc::c_int::try_from(events.len()).unwrap_or(0);
            // SAFETY: `events` has room for `capacity` events; `deadline` is
            // null or points at `time`, alive for the call.
            let count = unsafe {
                libc::kevent(
                    self.kq.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    events.as_mut_ptr(),
                    capacity,
                    deadline.unwrap_or(std::ptr::null()),
                )
            };
            let Ok(count) = usize::try_from(count) else {
                // EINTR: wait again. Any other failure of a wait on our own
                // queue does not pass; the engine reports it and ends.
                let error = io::Error::last_os_error();
                return if error.kind() == io::ErrorKind::Interrupted {
                    Vec::new()
                } else {
                    vec![Wake::Failed(format!("watch: {}", error.kind()))]
                };
            };
            let mut wakes = Vec::new();
            for event in events.iter().take(count) {
                // By value: `kevent` is packed on x86_64, so no reference to a field.
                let (ident, filter, fflags) = (event.ident, event.filter, event.fflags);
                if filter == libc::EVFILT_USER {
                    return vec![Wake::Stop];
                }
                if let Some(path) = self.paths.get(&ident) {
                    wakes.push(Wake::Changed {
                        paths: vec![path.clone()],
                        moved: fflags & MOVED != 0,
                    });
                }
            }
            wakes
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod portable {
    use super::Wake;
    use notify::event::{EventKind, MetadataKind, ModifyKind};
    use notify::{RecursiveMode, Watcher};
    use std::io;
    use std::path::Path;
    use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
    use std::time::Duration;

    enum Message {
        File(notify::Result<notify::Event>),
        Stop,
    }

    /// Wakes the sync thread's wait with a stop message.
    pub(crate) struct Stopper {
        messages: Sender<Message>,
    }

    impl Stopper {
        pub(crate) fn stop(&self) {
            let _ = self.messages.send(Message::Stop);
        }
    }

    /// notify's watcher for this platform, its events on a channel.
    pub(crate) struct FileWatch {
        watcher: notify::RecommendedWatcher,
        inbox: Receiver<Message>,
    }

    /// A write, create, rename or delete; not a read or an access-time
    /// touch (the scan's own read of the file must not schedule another scan).
    fn is_change(kind: &EventKind) -> bool {
        match kind {
            EventKind::Create(_) | EventKind::Remove(_) | EventKind::Any => true,
            EventKind::Modify(ModifyKind::Metadata(MetadataKind::AccessTime)) => false,
            EventKind::Modify(_) => true,
            EventKind::Access(_) | EventKind::Other => false,
        }
    }

    impl FileWatch {
        pub(crate) fn new() -> io::Result<(Self, Stopper)> {
            let (messages, inbox) = mpsc::channel();
            let events = messages.clone();
            let watcher =
                notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                    let _ = events.send(Message::File(event));
                })
                .map_err(io::Error::other)?;
            Ok((Self { watcher, inbox }, Stopper { messages }))
        }

        pub(crate) fn watch(&mut self, path: &Path) -> io::Result<()> {
            self.watcher.watch(path, RecursiveMode::NonRecursive).map_err(io::Error::other)
        }

        pub(crate) fn unwatch(&mut self, path: &Path) {
            let _ = self.watcher.unwatch(path);
        }

        /// Blocks until a watched file changes, the stop, or `timeout`.
        pub(crate) fn wait(&mut self, timeout: Option<Duration>) -> Vec<Wake> {
            let message = match timeout {
                Some(timeout) => match self.inbox.recv_timeout(timeout) {
                    Ok(message) => message,
                    Err(RecvTimeoutError::Timeout) => return Vec::new(),
                    Err(RecvTimeoutError::Disconnected) => return vec![Wake::Stop],
                },
                None => match self.inbox.recv() {
                    Ok(message) => message,
                    Err(_) => return vec![Wake::Stop],
                },
            };
            match message {
                Message::Stop => vec![Wake::Stop],
                // The watcher failed or its queue overflowed.
                Message::File(Err(_)) => vec![Wake::Rescan],
                Message::File(Ok(event)) if event.need_rescan() => vec![Wake::Rescan],
                Message::File(Ok(event)) if is_change(&event.kind) => {
                    let moved = matches!(
                        event.kind,
                        EventKind::Remove(_) | EventKind::Modify(ModifyKind::Name(_))
                    );
                    vec![Wake::Changed { paths: event.paths, moved }]
                }
                Message::File(Ok(_)) => Vec::new(),
            }
        }
    }
}

/// `path` with `suffix` appended to its file name (`Cookies-wal`).
pub(crate) fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

/// Keeps a watch on what exists of one database's files: the database, its
/// `-wal`, and their directory (a new entry there, such as a `-wal` the
/// browser creates, is noticed and watched). `rearm` watches each again (a
/// watch follows a deleted or renamed file, not the path). True when the
/// database or its `-wal` appeared or went since the last refresh.
pub(crate) fn refresh(
    watch: &mut FileWatch,
    watched: &mut BTreeSet<PathBuf>,
    database: &Path,
    rearm: bool,
) -> bool {
    let mut changed = false;
    let files = [database.to_path_buf(), sidecar(database, "-wal")];
    let dir = database.parent().map(Path::to_path_buf);
    for (is_file, path) in
        files.into_iter().map(|path| (true, path)).chain(dir.map(|dir| (false, dir)))
    {
        let exists = path.exists();
        let was = watched.contains(&path);
        if is_file && was != exists {
            changed = true;
        }
        if was && (rearm || !exists) {
            watch.unwatch(&path);
            watched.remove(&path);
        }
        if exists && !watched.contains(&path) && watch.watch(&path).is_ok() {
            watched.insert(path);
        }
    }
    changed
}

/// How long to wait for `deadline` from `now` (none: until an event).
pub(crate) fn timeout(deadline: Option<Duration>, now: Duration) -> Option<Duration> {
    deadline.map(|at| at.saturating_sub(now))
}
