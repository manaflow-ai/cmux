//! Linux: inotify with masks that leave out opens, reads and read-only
//! closes. notify 8 adds IN_OPEN to every watch, so a watched busy directory
//! (/etc while /etc/cmux is missing: every exec opens /etc/ld.so.cache) woke
//! its thread on each process start, and the daemon's own reads of its
//! settings file queued events too. With these masks the kernel queues
//! nothing for an open, so an idle daemon does not wake. IN_MODIFY is left
//! out too: a writer that keeps the file open is seen when it closes it.
//!
//! One thread owns the inotify descriptor and waits in `poll` on it and on
//! a stop socket; dropping the handle closes the socket's other end.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ffi::{CString, OsStr, OsString, c_char, c_int, c_short, c_ulong};
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::{MAX_DELAY, Plan, QUIET};

// <sys/inotify.h> and <poll.h>; the values are the same on every Linux
// architecture Rust targets except the O_CLOEXEC-based IN_CLOEXEC, which
// differs only on alpha, sparc and parisc.
const IN_ATTRIB: u32 = 0x0000_0004;
const IN_CLOSE_WRITE: u32 = 0x0000_0008;
const IN_MOVED_FROM: u32 = 0x0000_0040;
const IN_MOVED_TO: u32 = 0x0000_0080;
const IN_CREATE: u32 = 0x0000_0100;
const IN_DELETE: u32 = 0x0000_0200;
const IN_DELETE_SELF: u32 = 0x0000_0400;
const IN_MOVE_SELF: u32 = 0x0000_0800;
const IN_Q_OVERFLOW: u32 = 0x0000_4000;
const IN_IGNORED: u32 = 0x0000_8000;
const IN_ONLYDIR: u32 = 0x0100_0000;
const IN_CLOEXEC: c_int = 0o2_000_000;
const POLLIN: c_short = 0x001;
const POLLERR: c_short = 0x008;
const POLLHUP: c_short = 0x010;
const POLLNVAL: c_short = 0x020;

/// A directory that holds a watched file: content changes of its entries.
const FILE_DIR_MASK: u32 = IN_CLOSE_WRITE
    | IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_CREATE
    | IN_DELETE
    | IN_ATTRIB
    | IN_DELETE_SELF
    | IN_MOVE_SELF
    | IN_ONLYDIR;
/// The nearest existing ancestor of a missing directory: only an entry
/// appearing (the missing directory) or the ancestor itself going away.
const ANCESTOR_MASK: u32 = IN_CREATE | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR;

/// The fixed part of `struct inotify_event`: wd, mask, cookie, len.
const EVENT_HEADER: usize = 16;

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: c_short,
    revents: c_short,
}

unsafe extern "C" {
    safe fn inotify_init1(flags: c_int) -> c_int;
    fn inotify_add_watch(fd: c_int, path: *const c_char, mask: u32) -> c_int;
    safe fn inotify_rm_watch(fd: c_int, wd: c_int) -> c_int;
    fn poll(fds: *mut PollFd, nfds: c_ulong, timeout: c_int) -> c_int;
}

pub(super) struct Handle {
    stop: Option<UnixStream>,
    thread: Option<JoinHandle<()>>,
}

pub(super) fn start(
    files: Vec<PathBuf>,
    mut on_hint: impl FnMut() + Send + 'static,
) -> notify::Result<Handle> {
    let fd = inotify_init1(IN_CLOEXEC);
    if fd < 0 {
        return Err(notify::Error::io(io::Error::last_os_error()));
    }
    // SAFETY: `fd` is a new descriptor from inotify_init1 that nothing else
    // owns; the File closes it.
    let file = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let mut watches = Watches { file, by_dir: BTreeMap::new(), names: HashMap::new() };
    watches.rearm(&files).map_err(notify::Error::io)?;
    let (stop, stopped) = UnixStream::pair().map_err(notify::Error::io)?;
    // supervise-allow: owned by Handle, which keeps it and joins it at drop; a panic ends config change hints only, and the loaded config stays in effect.
    let thread = cmux_threads::spawn("cmux-config-watch", super::WATCH_THREAD_QOS, move || {
        on_hint();
        run(&mut watches, &stopped, &files, &mut on_hint);
    })
    .map_err(notify::Error::io)?;
    Ok(Handle { stop: Some(stop), thread: Some(thread) })
}

impl Drop for Handle {
    fn drop(&mut self) {
        // Closing this end makes the thread's poll return.
        self.stop.take();
        if let Some(thread) = self.thread.take() {
            // The last owner may drop the watcher from its own callback.
            if thread.thread().id() != std::thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

struct Watches {
    file: File,
    /// Watched directory -> (watch descriptor, mask).
    by_dir: BTreeMap<PathBuf, (c_int, u32)>,
    /// Watch descriptor -> the entry names that matter in its directory.
    names: HashMap<c_int, BTreeSet<OsString>>,
}

enum Wake {
    Events,
    Timeout,
    Stop,
}

fn run(watches: &mut Watches, stop: &UnixStream, files: &[PathBuf], on_hint: &mut impl FnMut()) {
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        match wait(watches.file.as_raw_fd(), stop.as_raw_fd(), None) {
            Wake::Stop => return,
            Wake::Timeout => continue,
            Wake::Events => {}
        }
        match watches.read(&mut buffer) {
            Err(_) => return,
            Ok(false) => continue,
            Ok(true) => {}
        }
        // One hint per burst: wait until the events stop for QUIET.
        let started = Instant::now();
        loop {
            let left = MAX_DELAY.saturating_sub(started.elapsed()).min(QUIET);
            if left.is_zero() {
                break;
            }
            match wait(watches.file.as_raw_fd(), stop.as_raw_fd(), Some(left)) {
                Wake::Stop => return,
                Wake::Timeout => break,
                Wake::Events => {
                    if watches.read(&mut buffer).is_err() {
                        return;
                    }
                }
            }
        }
        // A directory that appeared or vanished moves the watch.
        let _ = watches.rearm(files);
        on_hint();
    }
}

/// Blocks until `events` is readable, `stop` is closed or `timeout` passes.
fn wait(events: RawFd, stop: RawFd, timeout: Option<Duration>) -> Wake {
    let mut fds = [
        PollFd { fd: events, events: POLLIN, revents: 0 },
        PollFd { fd: stop, events: POLLIN, revents: 0 },
    ];
    let millis = timeout
        .map_or(-1, |timeout| c_int::try_from(timeout.as_millis().max(1)).unwrap_or(c_int::MAX));
    // SAFETY: `fds` is a live array of two pollfd structs and nfds is its
    // length; poll only writes their revents fields.
    let ready = unsafe { poll(fds.as_mut_ptr(), fds.len() as c_ulong, millis) };
    if ready < 0 {
        return match io::Error::last_os_error().kind() {
            io::ErrorKind::Interrupted => Wake::Timeout,
            _ => Wake::Stop,
        };
    }
    let [watch, stopper] = &fds;
    if stopper.revents != 0 || watch.revents & (POLLERR | POLLHUP | POLLNVAL) != 0 {
        Wake::Stop
    } else if watch.revents & POLLIN != 0 {
        Wake::Events
    } else {
        Wake::Timeout
    }
}

impl Watches {
    /// Reads the queued events; true when one of them matters.
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<bool> {
        let length = loop {
            match (&self.file).read(buffer) {
                Ok(length) => break length,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error),
            }
        };
        let mut relevant = false;
        let mut rest = buffer.get(..length).unwrap_or_default();
        while let Some((header, tail)) = rest.split_first_chunk::<EVENT_HEADER>() {
            let [w0, w1, w2, w3, m0, m1, m2, m3, _, _, _, _, l0, l1, l2, l3] = *header;
            let wd = c_int::from_ne_bytes([w0, w1, w2, w3]);
            let mask = u32::from_ne_bytes([m0, m1, m2, m3]);
            let name_length = u32::from_ne_bytes([l0, l1, l2, l3]) as usize;
            let Some((name, next)) = tail.split_at_checked(name_length) else { break };
            rest = next;
            // The name is NUL-padded.
            let end = name.iter().position(|byte| *byte == 0).unwrap_or(name.len());
            let name = OsStr::from_bytes(name.get(..end).unwrap_or_default());
            relevant |= self.note(wd, mask, name);
        }
        Ok(relevant)
    }

    /// Whether one event matters; forgets a watch the kernel ended.
    fn note(&mut self, wd: c_int, mask: u32, name: &OsStr) -> bool {
        if mask & IN_Q_OVERFLOW != 0 {
            return true;
        }
        if mask & (IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF) != 0 {
            // A moved directory keeps its watch under the old inode; drop it
            // so the next rearm watches whatever is at the path now.
            return self.forget(wd, mask & IN_MOVE_SELF != 0);
        }
        self.names.get(&wd).is_some_and(|names| names.contains(name))
    }

    /// Drops the record of watch `wd` (and the kernel watch when `remove`);
    /// false when `wd` is not a current watch (a watch this side removed).
    fn forget(&mut self, wd: c_int, remove: bool) -> bool {
        if self.names.remove(&wd).is_none() {
            return false;
        }
        self.by_dir.retain(|_, (watch, _)| *watch != wd);
        if remove {
            inotify_rm_watch(self.file.as_raw_fd(), wd);
        }
        true
    }

    /// Points the watches at the directories of the current plan. Every
    /// planned directory is added again (the kernel returns the same watch
    /// for the same inode), so a directory replaced at the same path is
    /// watched even when its old inode's IN_DELETE_SELF is late or lost. A
    /// directory that cannot be watched (no permission) is skipped; the
    /// error is returned only when no directory is watched.
    fn rearm(&mut self, files: &[PathBuf]) -> io::Result<()> {
        let plan = Plan::of(files);
        let mut first_error = None;
        let mut armed = BTreeMap::new();
        for (dir, interest) in plan.0 {
            let mask = if interest.holds_file { FILE_DIR_MASK } else { ANCESTOR_MASK };
            match self.add_watch(&dir, mask) {
                Ok(wd) => {
                    self.names.insert(wd, interest.names);
                    armed.insert(dir, (wd, mask));
                }
                Err(error) => {
                    first_error.get_or_insert(error);
                }
            }
        }
        // Then drop the watches no longer wanted (only after the new ones
        // are in place, so a file is never left without a watch).
        let kept: BTreeSet<c_int> = armed.values().map(|(wd, _)| *wd).collect();
        for (_, (wd, _)) in std::mem::replace(&mut self.by_dir, armed) {
            if !kept.contains(&wd) {
                self.names.remove(&wd);
                inotify_rm_watch(self.file.as_raw_fd(), wd);
            }
        }
        match first_error {
            Some(error) if self.by_dir.is_empty() => Err(error),
            _ => Ok(()),
        }
    }

    /// Adds or replaces (same inode) the watch on `dir` with `mask`.
    fn add_watch(&self, dir: &Path, mask: u32) -> io::Result<c_int> {
        let path = CString::new(dir.as_os_str().as_bytes())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        // SAFETY: `path` is a NUL-terminated string that outlives the call.
        let wd = unsafe { inotify_add_watch(self.file.as_raw_fd(), path.as_ptr(), mask) };
        if wd < 0 { Err(io::Error::last_os_error()) } else { Ok(wd) }
    }
}
