//! Linux: inotify with masks that leave out opens, reads and read-only
//! closes. notify 8 adds IN_OPEN to every watch, so a watched busy directory
//! (/etc while /etc/cmux is missing: every exec opens /etc/ld.so.cache) woke
//! its thread on each process start, and the daemon's own reads of its
//! settings file queued events too. With these masks the kernel queues
//! nothing for an open, so an idle daemon does not wake.
//!
//! A directory watch cannot name an entry: the kernel queues its events for
//! every entry, and an event the watch thread drops is still a wake of that
//! thread. So a directory is watched only for its entries being created,
//! removed or renamed, and each watched regular file has a watch of its own
//! (of the file, not of its directory) for a close after a write and a
//! metadata change, as on macOS (`kqueue.rs`). A write, a close or a
//! metadata change of any other entry queues nothing: another program's busy
//! log beside a watched file (Codex appends to ~/.codex several times a
//! second) does not wake the daemon. IN_MODIFY is left out: a writer that
//! keeps the file open is seen when it closes it. A watched name that is not
//! a regular file (a folder, a socket) has no watch of its own: its entry
//! being made, removed or renamed hints, a metadata change of it does not.
//!
//! A file that may exist and got no watch of its own (inotify refuses a file
//! the process may not read, a folder that may not be searched hides its
//! names, the user's watches can run out) is seen through its directory:
//! that directory's watch then also has the close and metadata events, for
//! each of its entries.
//!
//! A watch's mask only grows: each add has IN_MASK_ADD, and no call takes a
//! bit away from a watch that exists. A call that sets a mask goes through a
//! path, the path can name another inode by then (a link that another
//! program points elsewhere), and for the time of that call a watch would be
//! without a bit that it needs: an event in that time is lost. So a
//! directory that got the close and metadata events keeps them until its
//! watch goes (the directory is removed or replaced, or the watcher ends),
//! also after its file has a watch of its own.
//!
//! [`super::Watcher::start_with_writes`] adds IN_MODIFY to each file's own
//! watch, so a write that its writer keeps open (a database's write-ahead
//! log) hints.
//!
//! A file's watch is on the file that was at its name when it was armed.
//! When the name gets another file (a save by rename, a delete and create),
//! the directory's event counts, and `run` arms the watches again before it
//! hints: the consumer reads after the new file is watched, so no write to it
//! is missed. A watched name that is a symbolic link is followed: the watch
//! is on the file it names, wherever that is.
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
const IN_MODIFY: u32 = 0x0000_0002;
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
const IN_MASK_ADD: u32 = 0x2000_0000;
const IN_CLOEXEC: c_int = 0o2_000_000;
const POLLIN: c_short = 0x001;
const POLLERR: c_short = 0x008;
const POLLHUP: c_short = 0x010;
const POLLNVAL: c_short = 0x020;

/// A directory that holds a watched file: its entries being created, removed
/// or renamed, and the directory itself going away. Nothing an entry that
/// stays in place can cause.
const FILE_DIR_MASK: u32 = IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_CREATE
    | IN_DELETE
    | IN_DELETE_SELF
    | IN_MOVE_SELF
    | IN_ONLYDIR;
/// A watched regular file itself: a close after a write and a metadata
/// change. Also added to the directory's watch when one of its watched
/// names cannot have a watch of its own (`Watches::arm_files`).
const FILE_MASK: u32 = IN_CLOSE_WRITE | IN_ATTRIB;
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
    writes: bool,
    mut on_hint: impl FnMut() + Send + 'static,
) -> notify::Result<Handle> {
    let mut watches = Watches::new(writes).map_err(notify::Error::io)?;
    watches.rearm(&files).map_err(notify::Error::io)?;
    let (stop, stopped) = UnixStream::pair().map_err(notify::Error::io)?;
    let thread = std::thread::Builder::new()
        .name("cmux-config-watch".to_string())
        .spawn(move || {
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
    /// Watched path (a directory, or a watched file itself) -> (watch
    /// descriptor, the mask the last rearm asked of it; the kernel's mask
    /// can hold more, because a mask only grows).
    by_dir: BTreeMap<PathBuf, (c_int, u32)>,
    /// Watch descriptor -> the entry names that matter in its directory
    /// (a file's own watch: the empty name its events carry).
    names: HashMap<c_int, BTreeSet<OsString>>,
    /// Each watched regular file's own watch also has IN_MODIFY.
    writes: bool,
    /// `note_fault` wrote its line.
    fault_noted: bool,
}

/// The watches of one `Watches::rearm`.
#[derive(Default)]
struct Pass {
    /// The next `Watches::by_dir`.
    armed: BTreeMap<PathBuf, (c_int, u32)>,
    /// Watch descriptor -> the mask and the names this pass asked of it. Two
    /// planned paths can be one inode (a link to a planned directory): the
    /// kernel has one watch for an inode, so both paths' names count in it.
    asked: HashMap<c_int, (u32, BTreeSet<OsString>)>,
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
        // A directory that appeared or vanished moves the watch, and a
        // watched name that got another file gets its watch. Before the
        // hint: the consumer then reads a file that is already watched.
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
    /// A new inotify descriptor with no watch yet.
    fn new(writes: bool) -> io::Result<Self> {
        let fd = inotify_init1(IN_CLOEXEC);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `fd` is a new descriptor from inotify_init1 that nothing else
        // owns; the File closes it.
        let file = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
        Ok(Self {
            file,
            by_dir: BTreeMap::new(),
            names: HashMap::new(),
            writes,
            fault_noted: false,
        })
    }

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
    /// directory is watched before its names, so a name that appears in
    /// between is an event of the directory. A directory that cannot be
    /// watched (no permission) is skipped; the error is returned only when no
    /// directory is watched.
    fn rearm(&mut self, files: &[PathBuf]) -> io::Result<()> {
        let plan = Plan::of(files);
        let mut first_error = None;
        let mut pass = Pass::default();
        for (dir, interest) in plan.0 {
            let mask = if interest.holds_file { FILE_DIR_MASK } else { ANCESTOR_MASK };
            match self.arm(&dir, mask, &interest.names, &mut pass) {
                Ok(_) => {
                    if interest.holds_file && !self.arm_files(&dir, &interest.names, &mut pass) {
                        // More bits for the watch `dir` has, which needs no
                        // new watch. When it fails, the entry events stay
                        // watched.
                        let _ = self.arm(&dir, mask | FILE_MASK, &interest.names, &mut pass);
                    }
                }
                Err(error) => {
                    first_error.get_or_insert(error);
                }
            }
        }
        let Pass { armed, asked } = pass;
        // Then drop the watches no longer wanted (only after the new ones
        // are in place, so a file is never left without a watch).
        let kept: BTreeSet<c_int> = armed.values().map(|(wd, _)| *wd).collect();
        let dropped: BTreeSet<c_int> = std::mem::replace(&mut self.by_dir, armed)
            .into_values()
            .map(|(wd, _)| wd)
            .chain(asked.into_keys())
            .filter(|wd| !kept.contains(wd))
            .collect();
        for wd in dropped {
            self.names.remove(&wd);
            inotify_rm_watch(self.file.as_raw_fd(), wd);
        }
        match first_error {
            Some(error) if self.by_dir.is_empty() => Err(error),
            _ => Ok(()),
        }
    }

    /// Watches `path` for `mask` and counts its events that carry one of
    /// `names`, together with what this pass already asked of the same inode
    /// (the kernel has one mask, and `names` has one set, for a watch).
    ///
    /// The mask is only added to the one the inode's watch has (IN_MASK_ADD),
    /// and nothing takes a bit away later (the module's text says why).
    fn arm(
        &mut self,
        path: &Path,
        mask: u32,
        names: &BTreeSet<OsString>,
        pass: &mut Pass,
    ) -> io::Result<c_int> {
        let wd = self.add_watch(path, mask | IN_MASK_ADD)?;
        let (mut mask, mut names) = (mask, names.clone());
        if let Some((asked, counted)) = pass.asked.get(&wd) {
            mask |= asked;
            names.extend(counted.iter().cloned());
        }
        self.names.insert(wd, names.clone());
        pass.asked.insert(wd, (mask, names));
        pass.armed.insert(path.to_path_buf(), (wd, mask));
        Ok(wd)
    }

    /// Gives each of `names` in `dir` that is a regular file now a watch of
    /// its own (`FILE_MASK`, with IN_MODIFY when `writes`), following a
    /// symbolic link. A socket, a folder or a missing name has none: its
    /// entry in `dir` is what matters. A file replaced by rename changes an
    /// entry of `dir`, whose watch then rearms and watches the new file.
    ///
    /// False when a file that may exist got no watch: the look at the name
    /// failed for a cause other than "no such name" (a folder that may not be
    /// searched hides its names), or inotify refused it (a file the process
    /// may not read; no watch left for the user). The caller then watches
    /// `dir` for the same events, as for each of its entries.
    fn arm_files(&mut self, dir: &Path, names: &BTreeSet<OsString>, pass: &mut Pass) -> bool {
        // A file's own events carry no name.
        let own = BTreeSet::from([OsString::new()]);
        let mask = if self.writes { FILE_MASK | IN_MODIFY } else { FILE_MASK };
        let mut all = true;
        for name in names {
            let path = dir.join(name);
            let armed = match std::fs::metadata(&path) {
                Ok(metadata) if metadata.is_file() => self.arm(&path, mask, &own, pass).map(|_| ()),
                Ok(_) => Ok(()),
                Err(error) => Err(error),
            };
            match armed {
                Ok(()) => {}
                // No such name (or gone since the look): an entry event of
                // `dir` says when there is one.
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => {
                    all = false;
                    self.note_fault(&path, &error);
                }
            }
        }
        all
    }

    /// Writes one line, one time for this watcher, when a name got no watch
    /// of its own for a cause other than its mode (the user's inotify watches
    /// ran out: ENOSPC). Its directory is then watched for each entry, so the
    /// writes of other programs there wake this thread again.
    fn note_fault(&mut self, path: &Path, error: &io::Error) {
        if error.kind() == io::ErrorKind::PermissionDenied
            || std::mem::replace(&mut self.fault_noted, true)
        {
            return;
        }
        eprintln!(
            "cmux-config: watch: no watch for {}: {error}; its folder is watched for every entry",
            path.display()
        );
    }

    /// Adds the watch on `path` (a directory, or a watched file itself). The
    /// callers pass IN_MASK_ADD, so the mask of a watch its inode has only
    /// grows.
    fn add_watch(&self, path: &Path, mask: u32) -> io::Result<c_int> {
        let path = CString::new(path.as_os_str().as_bytes())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        // SAFETY: `path` is a NUL-terminated string that outlives the call.
        let wd = unsafe { inotify_add_watch(self.file.as_raw_fd(), path.as_ptr(), mask) };
        if wd < 0 { Err(io::Error::last_os_error()) } else { Ok(wd) }
    }
}

#[cfg(test)]
mod tests;
