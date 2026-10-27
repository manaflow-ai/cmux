//! A watch on the entry list of a few directories, waited on by the forwarder
//! task itself (`AsyncFd`, no thread). Only entries appearing, going or
//! moving, and the directory's own end, queue an event: an open, a read or a
//! write of a file in a watched directory queues nothing, so a busy parent
//! such as /tmp or $TMPDIR does not wake the relay for unrelated work.
//!
//! - Linux: inotify with an entry mask (no IN_OPEN, IN_ACCESS, IN_MODIFY,
//!   IN_ATTRIB or IN_CLOSE_*, which notify 8 always adds). A parent of a
//!   missing root asks only for entries appearing (IN_CREATE, IN_MOVED_TO).
//! - macOS: a kqueue EVFILT_VNODE watch per directory (NOTE_WRITE fires when
//!   the directory's own entries change). FSEvents, notify's macOS backend,
//!   watches the whole subtree with no latency, so every file event below
//!   /private/tmp woke the relay.
//!
//! Chromium does the same split in base/files/file_path_watcher_inotify.cc
//! and file_path_watcher_kqueue.cc. Elsewhere `EntryWatch::new` fails and
//! the forwarder rescans on its backoff.

use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

/// Which entry changes of a directory wake the watch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Mask {
    /// A socket root: entries appearing, going or moving in or out.
    Entries,
    /// The parent of a missing root: entries appearing (Linux; kqueue cannot
    /// tell a removal from a creation, so macOS wakes for both).
    Appear,
}

/// One event of a watched directory.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Fired {
    /// An entry of `dir` changed; `name` is the entry where the platform
    /// names it (inotify), None where it does not (kqueue).
    Entry { dir: PathBuf, name: Option<OsString> },
    /// `dir` was deleted, moved or unmounted; its watch is gone.
    Gone { dir: PathBuf },
    /// The kernel dropped events (inotify queue overflow).
    #[cfg_attr(not(target_os = "linux"), allow(dead_code, reason = "only inotify drops events"))]
    Overflow,
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(super) use platform::EntryWatch;

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(super) struct EntryWatch;

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
impl EntryWatch {
    pub(super) fn new() -> io::Result<Self> {
        Err(io::Error::from(io::ErrorKind::Unsupported))
    }

    pub(super) fn add(&mut self, _dir: &Path, _mask: Mask) -> io::Result<()> {
        Err(io::Error::from(io::ErrorKind::Unsupported))
    }

    pub(super) fn remove(&mut self, _dir: &Path) {}

    pub(super) async fn wait(&mut self) -> io::Result<Vec<Fired>> {
        std::future::pending().await
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn path_cstring(path: &Path) -> io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(io::Error::other)
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn owned_fd(raw: libc::c_int) -> io::Result<std::os::fd::OwnedFd> {
    use std::os::fd::FromRawFd;
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the caller passes a descriptor a syscall just returned, which
    // nothing else owns.
    Ok(unsafe { std::os::fd::OwnedFd::from_raw_fd(raw) })
}

#[cfg(target_os = "linux")]
mod platform {
    use std::collections::HashMap;
    use std::ffi::OsString;
    use std::io;
    use std::os::fd::{AsRawFd, OwnedFd, RawFd};
    use std::os::unix::ffi::OsStringExt;
    use std::path::{Path, PathBuf};

    use tokio::io::unix::AsyncFd;

    use super::{Fired, Mask, owned_fd, path_cstring};

    /// The directory's own end, for both masks.
    const SELF_MASK: u32 = libc::IN_DELETE_SELF | libc::IN_MOVE_SELF | libc::IN_ONLYDIR;
    /// The fixed part of `struct inotify_event`: wd, mask, cookie, len.
    const EVENT_HEADER: usize = 16;

    pub(in super::super) struct EntryWatch {
        inotify: AsyncFd<OwnedFd>,
        dirs: HashMap<libc::c_int, PathBuf>,
    }

    impl EntryWatch {
        /// Needs a tokio runtime with I/O enabled.
        pub(in super::super) fn new() -> io::Result<Self> {
            // SAFETY: inotify_init1 has no preconditions.
            let raw = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
            Ok(Self { inotify: AsyncFd::new(owned_fd(raw)?)?, dirs: HashMap::new() })
        }

        /// Watches `dir` (a blocking path lookup). Adding a watched directory
        /// again replaces its mask.
        pub(in super::super) fn add(&mut self, dir: &Path, mask: Mask) -> io::Result<()> {
            let entries = match mask {
                Mask::Entries => {
                    libc::IN_CREATE | libc::IN_DELETE | libc::IN_MOVED_FROM | libc::IN_MOVED_TO
                }
                Mask::Appear => libc::IN_CREATE | libc::IN_MOVED_TO,
            };
            let path = path_cstring(dir)?;
            // SAFETY: a valid inotify descriptor and a NUL-terminated path.
            let wd = unsafe {
                libc::inotify_add_watch(
                    self.inotify.get_ref().as_raw_fd(),
                    path.as_ptr(),
                    entries | SELF_MASK,
                )
            };
            if wd < 0 {
                return Err(io::Error::last_os_error());
            }
            self.dirs.retain(|_, watched| watched != dir);
            self.dirs.insert(wd, dir.to_path_buf());
            Ok(())
        }

        pub(in super::super) fn remove(&mut self, dir: &Path) {
            let fd = self.inotify.get_ref().as_raw_fd();
            self.dirs.retain(|wd, watched| {
                if watched != dir {
                    return true;
                }
                // SAFETY: a valid inotify descriptor; a stale wd only fails.
                unsafe { libc::inotify_rm_watch(fd, *wd) };
                false
            });
        }

        /// Waits until a watched directory has events and returns them all.
        /// Cancel-safe: events are read only after the wait completes.
        pub(in super::super) async fn wait(&mut self) -> io::Result<Vec<Fired>> {
            loop {
                let mut ready = self.inotify.readable().await?;
                let fired = drain(ready.get_inner().as_raw_fd(), &mut self.dirs)?;
                ready.clear_ready();
                if !fired.is_empty() {
                    return Ok(fired);
                }
            }
        }
    }

    /// Reads every queued event (the descriptor is non-blocking).
    fn drain(fd: RawFd, dirs: &mut HashMap<libc::c_int, PathBuf>) -> io::Result<Vec<Fired>> {
        let mut fired = Vec::new();
        // Room for at least one event with the longest name.
        let mut buffer = [0_u8; 4096];
        loop {
            // SAFETY: a valid descriptor and a buffer of `buffer.len()` bytes.
            let read = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
            let Ok(length) = usize::try_from(read) else {
                let error = io::Error::last_os_error();
                match error.kind() {
                    io::ErrorKind::Interrupted => continue,
                    io::ErrorKind::WouldBlock => return Ok(fired),
                    _ => return Err(error),
                }
            };
            if length == 0 {
                return Ok(fired);
            }
            parse(&buffer[..length], fd, dirs, &mut fired);
        }
    }

    fn parse(
        mut bytes: &[u8],
        fd: RawFd,
        dirs: &mut HashMap<libc::c_int, PathBuf>,
        fired: &mut Vec<Fired>,
    ) {
        let word = |bytes: &[u8], at: usize| -> Option<[u8; 4]> {
            bytes.get(at..at + 4).and_then(|word| word.try_into().ok())
        };
        while bytes.len() >= EVENT_HEADER {
            let (Some(wd), Some(mask), Some(len)) =
                (word(bytes, 0), word(bytes, 4), word(bytes, 12))
            else {
                return;
            };
            let (wd, mask) = (libc::c_int::from_ne_bytes(wd), u32::from_ne_bytes(mask));
            let len = usize::try_from(u32::from_ne_bytes(len)).unwrap_or(usize::MAX);
            let Some(name) = bytes.get(EVENT_HEADER..EVENT_HEADER.saturating_add(len)) else {
                return;
            };
            bytes = &bytes[EVENT_HEADER + len..];
            if mask & libc::IN_Q_OVERFLOW != 0 {
                fired.push(Fired::Overflow);
                continue;
            }
            // IN_IGNORED of a removed watch, or an event queued before it.
            let Some(dir) = dirs.get(&wd) else { continue };
            if mask
                & (libc::IN_DELETE_SELF | libc::IN_MOVE_SELF | libc::IN_UNMOUNT | libc::IN_IGNORED)
                != 0
            {
                let dir = dir.clone();
                dirs.remove(&wd);
                // A moved directory keeps its watch; end it as for a deleted one.
                // SAFETY: a valid inotify descriptor; a removed wd only fails.
                unsafe { libc::inotify_rm_watch(fd, wd) };
                fired.push(Fired::Gone { dir });
                continue;
            }
            let name: Vec<u8> = name.iter().copied().take_while(|byte| *byte != 0).collect();
            fired.push(Fired::Entry {
                dir: dir.clone(),
                name: (!name.is_empty()).then(|| OsString::from_vec(name)),
            });
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::collections::HashMap;
    use std::io;
    use std::os::fd::{AsRawFd, OwnedFd, RawFd};
    use std::path::{Path, PathBuf};

    use tokio::io::unix::AsyncFd;

    use super::{Fired, Mask, owned_fd, path_cstring};

    /// NOTE_WRITE: the directory's entries changed. The rest: its own end.
    const FFLAGS: u32 =
        libc::NOTE_WRITE | libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE;
    const GONE: u32 = libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE;

    pub(in super::super) struct EntryWatch {
        kqueue: AsyncFd<OwnedFd>,
        /// The open directory (its descriptor is the event's ident) and its path.
        dirs: HashMap<RawFd, (OwnedFd, PathBuf)>,
    }

    fn empty_event() -> libc::kevent {
        libc::kevent {
            ident: 0,
            filter: 0,
            flags: 0,
            fflags: 0,
            data: 0,
            udata: std::ptr::null_mut(),
        }
    }

    impl EntryWatch {
        /// Needs a tokio runtime with I/O enabled. A kqueue descriptor is
        /// readable while it has events, so tokio's own kqueue waits on it.
        pub(in super::super) fn new() -> io::Result<Self> {
            // SAFETY: kqueue has no preconditions.
            let raw = unsafe { libc::kqueue() };
            Ok(Self { kqueue: AsyncFd::new(owned_fd(raw)?)?, dirs: HashMap::new() })
        }

        /// Watches `dir` (a blocking open). Both masks ask for the same
        /// vnode events: kqueue does not tell an entry's creation from its
        /// removal.
        pub(in super::super) fn add(&mut self, dir: &Path, _mask: Mask) -> io::Result<()> {
            self.remove(dir);
            let path = path_cstring(dir)?;
            // O_EVTONLY: the descriptor never keeps the volume from unmounting.
            // SAFETY: a NUL-terminated path; the flags take no mode argument.
            let raw = unsafe {
                libc::open(path.as_ptr(), libc::O_EVTONLY | libc::O_DIRECTORY | libc::O_CLOEXEC)
            };
            let directory = owned_fd(raw)?;
            let mut change = empty_event();
            change.ident = directory.as_raw_fd() as usize;
            change.filter = libc::EVFILT_VNODE;
            change.flags = libc::EV_ADD | libc::EV_CLEAR;
            change.fflags = FFLAGS;
            // SAFETY: one valid change, no event list, no timeout.
            let added = unsafe {
                libc::kevent(
                    self.kqueue.get_ref().as_raw_fd(),
                    &change,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                )
            };
            if added < 0 {
                return Err(io::Error::last_os_error());
            }
            self.dirs.insert(directory.as_raw_fd(), (directory, dir.to_path_buf()));
            Ok(())
        }

        /// Closing the directory's descriptor ends its vnode watch.
        pub(in super::super) fn remove(&mut self, dir: &Path) {
            self.dirs.retain(|_, (_, watched)| watched != dir);
        }

        /// Waits until a watched directory has events and returns them all.
        /// Cancel-safe: events are read only after the wait completes.
        pub(in super::super) async fn wait(&mut self) -> io::Result<Vec<Fired>> {
            loop {
                let mut ready = self.kqueue.readable().await?;
                let fired = drain(ready.get_inner().as_raw_fd(), &mut self.dirs)?;
                ready.clear_ready();
                if !fired.is_empty() {
                    return Ok(fired);
                }
            }
        }
    }

    /// Takes every pending event with a zero timeout.
    fn drain(
        kqueue: RawFd,
        dirs: &mut HashMap<RawFd, (OwnedFd, PathBuf)>,
    ) -> io::Result<Vec<Fired>> {
        let mut fired = Vec::new();
        let poll = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        let mut events: [libc::kevent; 16] = std::array::from_fn(|_| empty_event());
        loop {
            // SAFETY: room for `events.len()` events; a zero timeout returns at once.
            let count = unsafe {
                libc::kevent(
                    kqueue,
                    std::ptr::null(),
                    0,
                    events.as_mut_ptr(),
                    events.len() as libc::c_int,
                    &poll,
                )
            };
            let Ok(count) = usize::try_from(count) else {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            };
            if count == 0 {
                return Ok(fired);
            }
            for event in &events[..count] {
                let Ok(ident) = RawFd::try_from(event.ident) else { continue };
                let Some((_, dir)) = dirs.get(&ident) else { continue };
                if event.fflags & GONE != 0 {
                    let dir = dir.clone();
                    dirs.remove(&ident);
                    fired.push(Fired::Gone { dir });
                } else {
                    fired.push(Fired::Entry { dir: dir.clone(), name: None });
                }
            }
        }
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests {
    use super::*;
    use std::io::{Read as _, Write as _};
    use std::time::Duration;

    fn scratch(label: &str) -> PathBuf {
        let base = std::env::temp_dir()
            .join(format!("chatmux-entry-watch-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        base
    }

    /// Creates the files that `touch_many` then opens, reads and rewrites.
    fn churn_existing_files(dir: &Path) -> Vec<PathBuf> {
        let files: Vec<PathBuf> =
            (0..8).map(|index| dir.join(format!("busy-{index}.txt"))).collect();
        for file in &files {
            std::fs::write(file, b"seed").unwrap();
        }
        files
    }

    fn touch_many(files: &[PathBuf]) {
        for _ in 0..50 {
            for file in files {
                let mut writer =
                    std::fs::OpenOptions::new().write(true).truncate(true).open(file).unwrap();
                writer.write_all(b"unrelated work").unwrap();
                drop(writer);
                let mut text = String::new();
                std::fs::File::open(file).unwrap().read_to_string(&mut text).unwrap();
            }
        }
    }

    /// The parent of a missing root is a busy directory (/tmp, $TMPDIR):
    /// opens, reads and writes of its files do not wake the watch at all;
    /// the root appearing does.
    #[tokio::test]
    async fn file_work_in_a_watched_parent_queues_no_event() {
        let base = scratch("parent");
        let files = churn_existing_files(&base);
        let mut watch = EntryWatch::new().unwrap();
        watch.add(&base, Mask::Appear).unwrap();

        touch_many(&files);
        assert!(
            tokio::time::timeout(Duration::from_millis(300), watch.wait()).await.is_err(),
            "400 opens and writes of existing files woke the watch"
        );

        let root = base.join("cmux-tui-77");
        std::fs::create_dir(&root).unwrap();
        let fired = tokio::time::timeout(Duration::from_secs(10), watch.wait())
            .await
            .expect("the new root wakes the watch")
            .unwrap();
        assert!(
            fired.iter().all(|fired| matches!(fired, Fired::Entry { dir, .. } if *dir == base))
        );
        if cfg!(target_os = "linux") {
            assert!(fired.contains(&Fired::Entry {
                dir: base.clone(),
                name: Some(OsString::from("cmux-tui-77")),
            }));
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    /// A watched root: a socket bound wakes it, the root's removal ends its
    /// watch, and file work on existing entries stays quiet.
    #[tokio::test]
    async fn a_root_wakes_for_a_socket_and_ends_with_its_removal() {
        let base = scratch("root");
        let root = base.join("cmux-tui-78");
        std::fs::create_dir(&root).unwrap();
        let files = churn_existing_files(&root);
        let mut watch = EntryWatch::new().unwrap();
        watch.add(&root, Mask::Entries).unwrap();

        touch_many(&files);
        assert!(tokio::time::timeout(Duration::from_millis(300), watch.wait()).await.is_err());

        let listener = std::os::unix::net::UnixListener::bind(root.join("work.sock")).unwrap();
        let fired = tokio::time::timeout(Duration::from_secs(10), watch.wait())
            .await
            .expect("the bound socket wakes the watch")
            .unwrap();
        assert!(matches!(&fired[0], Fired::Entry { dir, .. } if *dir == root));
        drop(listener);

        std::fs::remove_dir_all(&root).unwrap();
        let gone = async {
            loop {
                let fired = watch.wait().await.unwrap();
                if fired.contains(&Fired::Gone { dir: root.clone() }) {
                    return;
                }
            }
        };
        tokio::time::timeout(Duration::from_secs(10), gone).await.expect("the root's end is seen");
        let _ = std::fs::remove_dir_all(&base);
    }
}
