//! A headless owner that nobody can reach again stops.
//!
//! Its socket is how every client finds it, and its state directory holds
//! the session it serves. A test harness that starts an owner under a
//! temporary root (the capability probe's `/tmp/cdc.*`) and dies without
//! stopping it leaves the owner running; once that root is removed, no
//! client can ever connect to it again, and a later `server ensure` starts
//! a second owner beside it. Seven such probe owners were found on the
//! fleet on 2026-10-31, up to four days old, five of them under a removed
//! root (on aws-m4pro-5 two of them also spun, see headless.rs
//! `fatal_faults_end_the_owner`).
//!
//! So the owner keeps the identity (device and inode) its socket, the
//! folder that holds the socket, and its session state directory had when
//! it started. Once any of them is removed, renamed away or replaced by
//! another file, and no client is connected (the owner's own journal
//! plugin aside), it stops the way a plain `server stop` does
//! (`stop_orphaned_owner`): no terminal is ended and no terminal host is
//! signalled, so each host follows its own orphan rule (host_orphan_policy.rs).
//! While a client is still connected the owner keeps serving it; the
//! client's departure is the event that stops it. An `--exit-with-pid`
//! owner also ends with the process it was started for (starter_exit.rs);
//! this rule covers the owners that have no such process.
//!
//! The `--owner-ready-fd` pipe says nothing about this: the owner writes
//! its one readiness byte and closes it (`local_owner::signal_ready`), and
//! the `server ensure` that reads it exits at once by design.
//!
//! Event-driven, never a timer. One thread blocks in `kevent` (macOS) or
//! `poll` on an inotify descriptor (Linux) with no timeout. It wakes on a
//! change to an entry of the socket's folder (kqueue cannot open a socket,
//! so the folder's entry changes stand in for it), on the removal or rename
//! of the folder or of the state directory, on a client arriving or
//! leaving, and on [`LostPaths::stop`]. Each wake drains what woke it
//! before it waits again, so a descriptor left readable can never spin it.
//! A rename of a folder above these (not their removal) is not seen. A path
//! that cannot be read at start is never watched, so a path the owner never
//! had is never taken for a loss. macOS and Linux only.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// One path's identity: its device and inode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Identity {
    dev: u64,
    ino: u64,
}

/// The identity of `path` itself (a symlink is not followed); `None` when
/// it cannot be read.
fn identity(path: &Path) -> Option<Identity> {
    use std::os::unix::fs::MetadataExt;
    std::fs::symlink_metadata(path).ok().map(|meta| Identity { dev: meta.dev(), ino: meta.ino() })
}

/// The paths that make an owner reachable, with the identity each had when
/// the owner started.
#[derive(Debug)]
pub(crate) struct Reachable {
    paths: Vec<(PathBuf, Identity)>,
}

impl Reachable {
    /// The identities of `paths` now, leaving out any that cannot be read;
    /// `None` when none can.
    pub(crate) fn now(paths: &[&Path]) -> Option<Self> {
        let paths: Vec<(PathBuf, Identity)> = paths
            .iter()
            .filter_map(|path| identity(path).map(|id| (path.to_path_buf(), id)))
            .collect();
        (!paths.is_empty()).then_some(Self { paths })
    }

    /// The first path that is no longer the file it was, and why.
    pub(crate) fn lost(&self) -> Option<String> {
        self.paths.iter().find_map(|(path, was)| match identity(path) {
            None => Some(format!("{} was removed", path.display())),
            Some(now) if now != *was => Some(format!("{} was replaced", path.display())),
            Some(_) => None,
        })
    }
}

/// What the watcher thread and the client observer share.
struct Shared {
    stopping: AtomicBool,
    wake: watch::Wake,
}

/// The running watcher; [`LostPaths::stop`] ends and joins it.
pub(crate) struct LostPaths {
    shared: Arc<Shared>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl LostPaths {
    pub(crate) fn stop(mut self) {
        self.shared.stopping.store(true, Ordering::SeqCst);
        self.shared.wake.trigger();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Starts the watch for this headless owner, serving on `socket`. `None`
/// when there is nothing to watch or the watch cannot start (logged).
pub(crate) fn start_for_owner(mux: &Arc<cmux_tui_core::Mux>, socket: &Path) -> Option<LostPaths> {
    let folder = socket.parent().filter(|folder| !folder.as_os_str().is_empty());
    let state = mux.session_state_directory();
    let mut paths: Vec<&Path> = vec![socket];
    paths.extend(folder);
    paths.extend(state.as_deref());
    let reachable = Reachable::now(&paths)?;
    let mut dirs: Vec<watch::Dir> = Vec::new();
    if let Some(folder) = folder {
        dirs.push(watch::Dir { path: folder.to_path_buf(), entries: true });
    }
    if let Some(state) = state {
        dirs.push(watch::Dir { path: state, entries: false });
    }
    let session = mux.session.clone();
    let (wake, events) = match watch::Wake::new().and_then(|wake| {
        let events = match watch::Events::start(&wake, &dirs) {
            Ok(events) => events,
            // A folder removed before its watch began is the loss itself.
            Err(_) if reachable.lost().is_some() => watch::Events::none(),
            Err(error) => return Err(error),
        };
        Ok((wake, events))
    }) {
        Ok(started) => started,
        Err(error) => {
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: owner {session} cannot watch its socket and state directory: {error}"
            );
            return None;
        }
    };
    let shared = Arc::new(Shared { stopping: AtomicBool::new(false), wake });
    let observer = Arc::downgrade(&shared);
    mux.add_client_presence_observer(move || {
        if let Some(shared) = observer.upgrade() {
            shared.wake.trigger();
        }
    });
    let watched = Arc::downgrade(mux);
    let waiter = shared.clone();
    let thread = std::thread::Builder::new()
        .name("owner-lost-paths".into())
        .spawn(move || run(&waiter, events, &reachable, &watched, &session))
        .ok();
    Some(LostPaths { shared, thread })
}

/// Waits until the owner is unreachable and unused, then stops it; returns
/// once it did or [`LostPaths::stop`] was called.
fn run(
    shared: &Shared,
    mut events: watch::Events,
    reachable: &Reachable,
    mux: &std::sync::Weak<cmux_tui_core::Mux>,
    session: &str,
) {
    let mut lost: Option<String> = None;
    let mut watching_files = true;
    loop {
        if shared.stopping.load(Ordering::SeqCst) {
            return;
        }
        if lost.is_none() {
            lost = reachable.lost();
            if lost.is_some() {
                // Only a client's departure matters now. Closing the folder
                // watches also means a removed or revoked vnode can never
                // wake this thread again.
                events = watch::Events::none();
                watching_files = false;
            }
        }
        if let Some(why) = &lost {
            let Some(mux) = mux.upgrade() else { return };
            // Refused while a client is connected or a client's handoff
            // runs: that client's departure wakes this thread again.
            if mux.user_client_count() == 0
                && cmux_tui_core::server::stop_orphaned_owner(&mux, || true)
            {
                crate::client_log::stderr_log!(
                    "lifecycle",
                    "{BIN}: stopped owner {session}: {why}, so no client can reach it; its terminals keep running"
                );
                return;
            }
        }
        if !events.wait(&shared.wake) {
            if !watching_files {
                // The wake itself failed, and would fail again at once: end
                // the watch rather than retry without blocking.
                return;
            }
            // The file watch failed: client arrivals and departures still
            // wake the thread, so a loss already seen is still acted on.
            events = watch::Events::none();
            watching_files = false;
        }
    }
}

#[cfg(target_os = "macos")]
mod watch {
    //! kqueue: one descriptor holds the folder watches and the user event
    //! that client changes and the stop trigger.

    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::PathBuf;

    const WAKE: usize = 1;

    pub(super) struct Dir {
        pub(super) path: PathBuf,
        /// Also wake on a change to its entries (the socket's folder).
        pub(super) entries: bool,
    }

    /// The kqueue, shared with the observer that triggers its user event.
    pub(super) struct Wake(OwnedFd);

    fn change(kq: i32, ident: usize, filter: i16, flags: u16, fflags: u32) -> std::io::Result<()> {
        let change =
            libc::kevent { ident, filter, flags, fflags, data: 0, udata: std::ptr::null_mut() };
        // SAFETY: one valid change, no event list, no timeout.
        let rc = unsafe { libc::kevent(kq, &change, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
        if rc < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
    }

    impl Wake {
        pub(super) fn new() -> std::io::Result<Self> {
            // SAFETY: kqueue has no preconditions.
            let raw = unsafe { libc::kqueue() };
            if raw < 0 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: kqueue returned a new descriptor that nothing else owns.
            let kq = unsafe { OwnedFd::from_raw_fd(raw) };
            // SAFETY: a valid descriptor; FD_CLOEXEC keeps it out of terminal hosts.
            unsafe { libc::fcntl(raw, libc::F_SETFD, libc::FD_CLOEXEC) };
            change(raw, WAKE, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0)?;
            Ok(Self(kq))
        }

        pub(super) fn trigger(&self) {
            let _ = change(self.0.as_raw_fd(), WAKE, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER);
        }
    }

    /// The open folders, watched while held.
    pub(super) struct Events {
        kq: i32,
        _dirs: Vec<std::fs::File>,
    }

    impl Events {
        pub(super) fn start(wake: &Wake, dirs: &[Dir]) -> std::io::Result<Self> {
            let kq = wake.0.as_raw_fd();
            let mut files = Vec::new();
            for dir in dirs {
                let mut fflags = libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE;
                if dir.entries {
                    fflags |= libc::NOTE_WRITE;
                }
                // O_EVTONLY: the watch never keeps the volume from unmounting.
                let file = std::fs::OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_EVTONLY | libc::O_CLOEXEC)
                    .open(&dir.path)?;
                let ident = file.as_raw_fd() as usize;
                change(kq, ident, libc::EVFILT_VNODE, libc::EV_ADD | libc::EV_CLEAR, fflags)?;
                files.push(file);
            }
            Ok(Self { kq, _dirs: files })
        }

        /// Client changes and the stop trigger only (the file watch failed).
        pub(super) fn none() -> Self {
            Self { kq: -1, _dirs: Vec::new() }
        }

        /// Blocks until one event arrives. False when the wait failed.
        pub(super) fn wait(&mut self, wake: &Wake) -> bool {
            let kq = if self.kq < 0 { wake.0.as_raw_fd() } else { self.kq };
            let mut event = libc::kevent {
                ident: 0,
                filter: 0,
                flags: 0,
                fflags: 0,
                data: 0,
                udata: std::ptr::null_mut(),
            };
            loop {
                // SAFETY: room for one event; a null timeout blocks until one
                // arrives. EV_CLEAR resets each event once it is returned.
                let count = unsafe {
                    libc::kevent(kq, std::ptr::null(), 0, &mut event, 1, std::ptr::null())
                };
                if count >= 0 {
                    return true;
                }
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    // A wait that fails at once would fail again: no retry.
                    eprintln!("cmux-tui: the owner's socket watch stopped: kevent: {error}");
                    return false;
                }
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod watch {
    //! inotify for the folders and an eventfd for client changes and the
    //! stop trigger, waited on together with `poll`.

    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::PathBuf;

    pub(super) struct Dir {
        pub(super) path: PathBuf,
        /// Also wake on a change to its entries (the socket's folder).
        pub(super) entries: bool,
    }

    /// The eventfd, shared with the observer that writes it.
    pub(super) struct Wake(OwnedFd);

    impl Wake {
        pub(super) fn new() -> std::io::Result<Self> {
            // SAFETY: eventfd has no preconditions.
            let raw = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
            if raw < 0 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: eventfd returned a new descriptor that nothing else owns.
            Ok(Self(unsafe { OwnedFd::from_raw_fd(raw) }))
        }

        pub(super) fn trigger(&self) {
            let one: u64 = 1;
            // SAFETY: a valid eventfd and an 8-byte value.
            let _ = unsafe {
                libc::write(self.0.as_raw_fd(), (&raw const one).cast(), size_of::<u64>())
            };
        }

        /// Resets the counter, so the eventfd is not readable until the next
        /// trigger.
        fn drain(&self) {
            let mut count: u64 = 0;
            // SAFETY: a valid non-blocking eventfd and an 8-byte buffer.
            let _ = unsafe {
                libc::read(self.0.as_raw_fd(), (&raw mut count).cast(), size_of::<u64>())
            };
        }
    }

    pub(super) struct Events {
        inotify: Option<OwnedFd>,
    }

    impl Events {
        pub(super) fn start(_wake: &Wake, dirs: &[Dir]) -> std::io::Result<Self> {
            // SAFETY: inotify_init1 has no preconditions.
            let raw = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
            if raw < 0 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: inotify_init1 returned a new descriptor that nothing else owns.
            let inotify = unsafe { OwnedFd::from_raw_fd(raw) };
            for dir in dirs {
                // Entry changes and the folder's own end only: never open,
                // access or modify events, which no loss needs.
                let mut mask = libc::IN_DELETE_SELF | libc::IN_MOVE_SELF | libc::IN_ONLYDIR;
                if dir.entries {
                    mask |=
                        libc::IN_CREATE | libc::IN_DELETE | libc::IN_MOVED_FROM | libc::IN_MOVED_TO;
                }
                let path = std::ffi::CString::new(dir.path.as_os_str().as_bytes())
                    .map_err(std::io::Error::other)?;
                // SAFETY: a valid inotify descriptor and a NUL-terminated path.
                if unsafe { libc::inotify_add_watch(raw, path.as_ptr(), mask) } < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(Self { inotify: Some(inotify) })
        }

        /// Client changes and the stop trigger only (the file watch failed).
        pub(super) fn none() -> Self {
            Self { inotify: None }
        }

        /// Blocks until a folder event or a trigger arrives, then drains
        /// both. False when the file watch failed.
        pub(super) fn wait(&mut self, wake: &Wake) -> bool {
            let unused = -1;
            let mut fds = [
                libc::pollfd { fd: wake.0.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd {
                    fd: self.inotify.as_ref().map_or(unused, AsRawFd::as_raw_fd),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            loop {
                // SAFETY: two pollfds (a negative fd is ignored); -1 blocks
                // until one is ready.
                let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
                if ready >= 0 {
                    break;
                }
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    eprintln!("cmux-tui: the owner's socket watch stopped: poll: {error}");
                    return false;
                }
            }
            if fds[0].revents != 0 {
                wake.drain();
            }
            let Some(inotify) = &self.inotify else { return true };
            if fds[1].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                eprintln!("cmux-tui: the owner's socket watch stopped: inotify descriptor failed");
                return false;
            }
            // Drain every queued event, so the descriptor is not readable
            // until the next one.
            let mut buf = [0u8; 4096];
            loop {
                // SAFETY: a valid non-blocking descriptor and a buffer of `buf.len()` bytes.
                let n =
                    unsafe { libc::read(inotify.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
                if n > 0 {
                    continue;
                }
                if n == 0 {
                    return true;
                }
                let error = std::io::Error::last_os_error();
                match error.kind() {
                    std::io::ErrorKind::Interrupted => {}
                    std::io::ErrorKind::WouldBlock => return true,
                    _ => {
                        eprintln!("cmux-tui: the owner's socket watch stopped: read: {error}");
                        return false;
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Reachable;

    #[test]
    fn a_removed_or_replaced_path_is_lost_and_an_unchanged_one_is_not() {
        let root = tempfile::tempdir().unwrap();
        let state = root.path().join("state");
        std::fs::create_dir(&state).unwrap();
        let socket = root.path().join("owner.sock");
        std::fs::write(&socket, "").unwrap();
        let reachable = Reachable::now(&[socket.as_path(), state.as_path()]).unwrap();
        assert_eq!(reachable.lost(), None);
        // Replaced: another file renamed over it (made while the first one
        // exists, so it cannot reuse the first one's inode).
        std::fs::write(root.path().join("other"), "").unwrap();
        std::fs::rename(root.path().join("other"), &socket).unwrap();
        assert!(reachable.lost().unwrap().ends_with("was replaced"), "{:?}", reachable.lost());
        let reachable = Reachable::now(&[state.as_path()]).unwrap();
        std::fs::remove_dir_all(&state).unwrap();
        assert!(reachable.lost().unwrap().ends_with("was removed"), "{:?}", reachable.lost());
    }

    #[test]
    fn a_path_that_cannot_be_read_at_start_is_never_watched() {
        let root = tempfile::tempdir().unwrap();
        let missing = root.path().join("missing");
        assert!(Reachable::now(&[missing.as_path()]).is_none());
        let reachable = Reachable::now(&[missing.as_path(), root.path()]).unwrap();
        assert_eq!(reachable.lost(), None, "a path never seen is not a loss");
    }
}
