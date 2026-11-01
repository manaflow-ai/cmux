//! macOS: kqueue vnode watches, no FSEvents. Every directory of the plan gets
//! a watch of its entries (`NOTE_WRITE` when an entry is created, removed or
//! renamed by any means; `NOTE_DELETE`, `NOTE_RENAME`, `NOTE_REVOKE` when the
//! directory itself goes away), and each watched name that is a regular file
//! gets a watch of its contents and metadata (a write in place changes no
//! entry of its directory).
//!
//! FSEvents (notify's macOS backend) was not enough:
//! - binding a Unix socket in a watched directory gave no hint, so the
//!   daemon's agent chat notices, which watch acpmux's socket with this
//!   module, never saw acpmux start while its folder was already there
//!   (`cmux_next_daemon_idle_has_no_periodic_wakeups`, `tests/watch.rs`);
//! - it goes through fseventsd, which falls behind a burst of writes anywhere
//!   on the volume, and stopping a stream purges its events with a call to
//!   fseventsd, so a watch could outlive its owner by seconds on a busy host
//!   (acpmux `agent_host/record_watch.rs` saw deletions late or never);
//! - it reports every change below a watched directory, so a missing
//!   directory's nearest ancestor (/Library while /Library/Managed
//!   Preferences is missing) woke the daemon for each write under it.
//!
//! A directory's `NOTE_WRITE` names no entry, so each directory keeps the
//! identity (device, inode, mode, change time) of its names that matter
//! (watched files and missing directories on the way to one), and the event
//! counts only when one of them changed: other entries of the directory (a
//! staged file beside the settings file, another program's socket) never
//! hint. A file's own events always count.
//!
//! One thread waits in `kevent`, with no timeout except to end a burst;
//! dropping the handle triggers a user event that ends it. Closing a
//! descriptor removes its watch and its queued events.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsString, c_int, c_long, c_void};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::{MAX_DELAY, Plan, QUIET};

// <sys/event.h> and <fcntl.h> (Darwin).
const EVFILT_VNODE: i16 = -4;
const EVFILT_USER: i16 = -10;
const EV_ADD: u16 = 0x0001;
const EV_CLEAR: u16 = 0x0020;
const NOTE_DELETE: u32 = 0x0000_0001;
const NOTE_WRITE: u32 = 0x0000_0002;
const NOTE_EXTEND: u32 = 0x0000_0004;
const NOTE_ATTRIB: u32 = 0x0000_0008;
const NOTE_RENAME: u32 = 0x0000_0020;
const NOTE_REVOKE: u32 = 0x0000_0040;
const NOTE_TRIGGER: u32 = 0x0100_0000;
const O_EVTONLY: c_int = 0x0000_8000;
const O_NONBLOCK: c_int = 0x0000_0004;
/// The user event's identifier (any value; only one user event exists).
const STOP: usize = usize::MAX;
/// The watched vnode itself went away (removed, renamed, its volume revoked).
const GONE: u32 = NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE;
/// A watched file's content or metadata changed, or it went away.
const FILE_FLAGS: u32 = NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | GONE;

#[repr(C)]
struct KEvent {
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: isize,
    udata: *mut c_void,
}

impl KEvent {
    fn new(ident: usize, filter: i16, flags: u16, fflags: u32) -> Self {
        Self { ident, filter, flags, fflags, data: 0, udata: std::ptr::null_mut() }
    }
}

#[repr(C)]
struct Timespec {
    tv_sec: i64,
    tv_nsec: c_long,
}

unsafe extern "C" {
    safe fn kqueue() -> c_int;
    fn kevent(
        kq: c_int,
        changelist: *const KEvent,
        nchanges: c_int,
        eventlist: *mut KEvent,
        nevents: c_int,
        timeout: *const Timespec,
    ) -> c_int;
}

fn change(kq: RawFd, event: &KEvent) -> io::Result<()> {
    // SAFETY: one valid change, no event list, no timeout.
    let result = unsafe { kevent(kq, event, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
    if result < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}

pub(super) struct Handle {
    kq: Arc<OwnedFd>,
    thread: Option<JoinHandle<()>>,
}

pub(super) fn start(
    files: Vec<PathBuf>,
    mut on_hint: impl FnMut() + Send + 'static,
) -> notify::Result<Handle> {
    let raw = kqueue();
    if raw < 0 {
        return Err(notify::Error::io(io::Error::last_os_error()));
    }
    // SAFETY: kqueue returned a new descriptor that nothing else owns.
    let kq = Arc::new(unsafe { OwnedFd::from_raw_fd(raw) });
    change(raw, &KEvent::new(STOP, EVFILT_USER, EV_ADD | EV_CLEAR, 0))
        .map_err(notify::Error::io)?;
    let mut watches =
        Watches { kq: Arc::clone(&kq), dirs: BTreeMap::new(), files: BTreeMap::new() };
    watches.rearm(&files).map_err(notify::Error::io)?;
    let thread = std::thread::Builder::new()
        .name("cmux-config-watch".to_string())
        .spawn(move || {
            on_hint();
            run(&mut watches, &files, &mut on_hint);
        })
        .map_err(notify::Error::io)?;
    Ok(Handle { kq, thread: Some(thread) })
}

impl Drop for Handle {
    fn drop(&mut self) {
        let _ = change(self.kq.as_raw_fd(), &KEvent::new(STOP, EVFILT_USER, 0, NOTE_TRIGGER));
        if let Some(thread) = self.thread.take() {
            // The last owner may drop the watcher from its own callback.
            if thread.thread().id() != std::thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

enum Wake {
    /// A watched descriptor's event: its identifier and flags.
    Event(usize, u32),
    Timeout,
    Stop,
}

fn run(watches: &mut Watches, files: &[PathBuf], on_hint: &mut impl FnMut()) {
    loop {
        match wait(watches.kq.as_raw_fd(), None) {
            Wake::Stop => return,
            Wake::Timeout => continue,
            Wake::Event(ident, fflags) => {
                if !watches.matters(ident, fflags) {
                    continue;
                }
            }
        }
        // One hint per burst: wait until the events stop for QUIET.
        let started = Instant::now();
        loop {
            let left = MAX_DELAY.saturating_sub(started.elapsed()).min(QUIET);
            if left.is_zero() {
                break;
            }
            match wait(watches.kq.as_raw_fd(), Some(left)) {
                Wake::Stop => return,
                Wake::Timeout => break,
                // Keeps the names' identities current; the burst goes on.
                Wake::Event(ident, fflags) => {
                    watches.matters(ident, fflags);
                }
            }
        }
        // A directory that appeared or vanished, or a file replaced, moves
        // the watch.
        let _ = watches.rearm(files);
        on_hint();
    }
}

/// Blocks for the next event, the stop event or `timeout`.
fn wait(kq: RawFd, timeout: Option<Duration>) -> Wake {
    let mut event = KEvent::new(0, 0, 0, 0);
    let limit = timeout.map(|timeout| Timespec {
        tv_sec: i64::try_from(timeout.as_secs()).unwrap_or(i64::MAX),
        tv_nsec: c_long::from(timeout.subsec_nanos()),
    });
    let limit_ptr = limit.as_ref().map_or(std::ptr::null(), |limit| limit as *const Timespec);
    // SAFETY: room for one event; the timeout is null (wait for an event) or
    // a live timespec.
    let count = unsafe { kevent(kq, std::ptr::null(), 0, &mut event, 1, limit_ptr) };
    if count < 0 {
        return match io::Error::last_os_error().kind() {
            io::ErrorKind::Interrupted => Wake::Timeout,
            _ => Wake::Stop,
        };
    }
    if count == 0 {
        Wake::Timeout
    } else if event.filter == EVFILT_USER {
        Wake::Stop
    } else {
        Wake::Event(event.ident, event.fflags)
    }
}

/// What an entry is, as far as a change goes: a new file, socket or folder
/// at the name, a replacement by rename, a removal or a metadata change all
/// give another value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Identity {
    dev: u64,
    ino: u64,
    mode: u32,
    ctime: (i64, i64),
}

impl Identity {
    fn of(metadata: &fs::Metadata) -> Self {
        Self {
            dev: metadata.dev(),
            ino: metadata.ino(),
            mode: metadata.mode(),
            ctime: (metadata.ctime(), metadata.ctime_nsec()),
        }
    }

    fn at(path: &Path) -> Option<Self> {
        fs::symlink_metadata(path).ok().map(|metadata| Self::of(&metadata))
    }
}

/// A watched directory: its descriptor (the watch) and the names that matter
/// in it, each as it was when last looked at.
struct Dir {
    file: File,
    names: BTreeMap<OsString, Option<Identity>>,
}

struct Watches {
    kq: Arc<OwnedFd>,
    dirs: BTreeMap<PathBuf, Dir>,
    /// Watched names that are regular files, by path.
    files: BTreeMap<PathBuf, File>,
}

impl Watches {
    /// Whether an event on descriptor `ident` is a change to hint for: a
    /// watched file changed, a watched directory went away, or one of a
    /// directory's names changed. A descriptor closed meanwhile (its watch
    /// moved) matches nothing.
    fn matters(&mut self, ident: usize, fflags: u32) -> bool {
        if self.files.values().any(|file| file.as_raw_fd() as usize == ident) {
            return true;
        }
        let Some((path, dir)) =
            self.dirs.iter_mut().find(|(_, dir)| dir.file.as_raw_fd() as usize == ident)
        else {
            return false;
        };
        if fflags & GONE != 0 {
            return true;
        }
        let mut changed = false;
        for (name, seen) in &mut dir.names {
            let now = Identity::at(&path.join(name));
            if now != *seen {
                *seen = now;
                changed = true;
            }
        }
        changed
    }

    /// Points the watches at the directories and files of the current plan.
    /// A directory or file still at its path (same device and inode) keeps
    /// its watch; one replaced at the path is watched again. Names are looked
    /// at after their directory's watch is armed, so a change in between
    /// leaves no event that counts: the caller hints after every rearm,
    /// which covers it. A directory that cannot be watched (no permission) is
    /// skipped; the error is returned only when no directory is watched.
    fn rearm(&mut self, files: &[PathBuf]) -> io::Result<()> {
        let plan = Plan::of(files);
        let mut first_error = None;
        let mut dirs = BTreeMap::new();
        let mut watched_files = BTreeMap::new();
        for (path, interest) in plan.0 {
            let dir = match self.dirs.remove(&path).filter(|dir| still_at(&dir.file, &path)) {
                Some(mut dir) => {
                    dir.names.retain(|name, _| interest.names.contains(name));
                    for name in &interest.names {
                        dir.names
                            .entry(name.clone())
                            .or_insert_with(|| Identity::at(&path.join(name)));
                    }
                    dir
                }
                None => match self.watch(&path, NOTE_WRITE | GONE) {
                    Ok(file) => {
                        let names = interest
                            .names
                            .iter()
                            .map(|name| (name.clone(), Identity::at(&path.join(name))))
                            .collect();
                        Dir { file, names }
                    }
                    Err(error) => {
                        first_error.get_or_insert(error);
                        continue;
                    }
                },
            };
            if interest.holds_file {
                self.rearm_files(&path, &interest.names, &mut watched_files);
            }
            dirs.insert(path, dir);
        }
        // The old watches close here, after the new ones are armed.
        self.dirs = dirs;
        self.files = watched_files;
        match first_error {
            Some(error) if self.dirs.is_empty() => Err(error),
            _ => Ok(()),
        }
    }

    /// Moves the watches of `dir`'s names that are regular files into
    /// `armed`, reusing a watch whose file is still at its path. A socket, a
    /// folder or a missing name has none (a socket's contents are not a
    /// setting, and `open` refuses one).
    fn rearm_files(
        &mut self,
        dir: &Path,
        names: &BTreeSet<OsString>,
        armed: &mut BTreeMap<PathBuf, File>,
    ) {
        for name in names {
            let path = dir.join(name);
            if !fs::metadata(&path).is_ok_and(|metadata| metadata.is_file()) {
                continue;
            }
            let file = match self.files.remove(&path).filter(|file| still_at(file, &path)) {
                Some(file) => file,
                None => match self.watch(&path, FILE_FLAGS) {
                    Ok(file) => file,
                    Err(_) => continue,
                },
            };
            armed.insert(path, file);
        }
    }

    /// Opens `path` for events only and adds its vnode watch.
    fn watch(&self, path: &Path, fflags: u32) -> io::Result<File> {
        // O_NONBLOCK: a name replaced by a FIFO between the check and the
        // open must not block the watch thread.
        let file = OpenOptions::new().read(true).custom_flags(O_EVTONLY | O_NONBLOCK).open(path)?;
        let watch = KEvent::new(file.as_raw_fd() as usize, EVFILT_VNODE, EV_ADD | EV_CLEAR, fflags);
        change(self.kq.as_raw_fd(), &watch)?;
        Ok(file)
    }
}

/// Whether `file` is still what `path` names (following symlinks, as the
/// open did).
fn still_at(file: &File, path: &Path) -> bool {
    match (file.metadata(), fs::metadata(path)) {
        (Ok(open), Ok(now)) => open.dev() == now.dev() && open.ino() == now.ino(),
        _ => false,
    }
}
