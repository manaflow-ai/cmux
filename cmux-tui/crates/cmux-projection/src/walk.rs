//! The Mac's stat-only walk of a projected folder (RFD 0007, fix #2 of "Leo's real ~/Projects"):
//! every entry is looked at once, with `fstatat` through the descriptor of the folder holding it,
//! and never opened, read or hashed; folders are walked on a bounded set of threads.
//!
//! What goes in is the caller's ([`Rules`]): which folders are entered and which entries are left
//! out. A folder is opened by name in the folder that listed it, never through a symlink
//! (`O_NOFOLLOW`), and listed through that descriptor, so a folder swapped for a symlink after its
//! parent was listed is never walked through and nothing outside the top folder is reached.
//!
//! Carries the approach of `cmux-tui/src/link/sync_cli/stat_walk.rs` from #45882 (Austin's
//! `cmux-projfs`): identity, size and times from the one `fstatat` through the parent folder.

use std::ffi::{CStr, CString, OsStr, OsString};
use std::io;
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd, RawFd};
use std::os::unix::ffi::{OsStrExt as _, OsStringExt as _};
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, PoisonError};

/// The threads a walk uses unless told otherwise: past about eight, a Mac's disk answers no
/// faster (the bench in `examples/walk_bench.rs` measures 1 to 16).
pub const DEFAULT_THREADS: usize = 8;

/// What one `fstatat` said of an entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stat {
    /// Permission bits (`0o7777` at most).
    pub mode: u32,
    pub size: u64,
    /// Modification time, nanoseconds since the epoch.
    pub mtime_ns: i64,
    pub dev: u64,
    pub ino: u64,
}

/// One entry the walk found that is not a folder it entered.
#[derive(Debug, PartialEq, Eq)]
pub enum Found<S> {
    /// A regular file.
    File(Stat),
    /// A symlink, with its text (`None` when it is not UTF-8).
    Link { text: Option<String>, stat: Stat },
    /// A socket, FIFO or device.
    Special,
    /// A name that is not UTF-8 (the path is lossy).
    NotUtf8,
    /// Left out by [`Rules`].
    Skipped(S),
}

/// What the walk enters and keeps.
pub trait Rules: Sync {
    /// Why something is left out.
    type Skip: Send;
    /// Why the folder `name` (at `relative`, in the folder at `parent` on this disk) is not
    /// entered, or `None` to enter it.
    fn folder(&self, relative: &str, parent: &Path, name: &str) -> Option<Self::Skip>;
    /// Why the entry at `relative` that is not a folder is left out, or `None` to keep it.
    fn entry(&self, relative: &str) -> Option<Self::Skip>;
}

/// Every entry below `top` but the folders entered, by its path relative to `top`
/// (`/`-separated), in no particular order, walked on `threads` threads. The first error (a
/// folder that cannot be listed, a stat that fails other than for a name gone meanwhile) ends the
/// walk.
pub fn walk<R: Rules>(
    top: &Path,
    rules: &R,
    threads: usize,
) -> io::Result<Vec<(String, Found<R::Skip>)>> {
    let root = open_dir(libc::AT_FDCWD, &CString::new(top.as_os_str().as_bytes())?)?
        .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
    let queue = Queue {
        state: Mutex::new(State {
            jobs: vec![Job { dir: Folder::Open(root), relative: String::new() }],
            busy: 0,
            failed: None,
        }),
        wake: Condvar::new(),
    };
    let threads = threads.clamp(1, 64);
    let parts: Vec<Vec<(String, Found<R::Skip>)>> = std::thread::scope(|scope| {
        let workers: Vec<_> =
            (0..threads).map(|_| scope.spawn(|| worker(top, rules, &queue))).collect();
        workers.into_iter().map(|worker| worker.join().unwrap_or_default()).collect()
    });
    let mut state = queue.state.into_inner().unwrap_or_else(PoisonError::into_inner);
    if let Some(error) = state.failed.take() {
        return Err(error);
    }
    let mut found = Vec::with_capacity(parts.iter().map(Vec::len).sum());
    for part in parts {
        found.extend(part);
    }
    Ok(found)
}

/// A folder to list: open already (the top), or a name in a folder held open.
enum Folder {
    Open(OwnedFd),
    Child { parent: Arc<OwnedFd>, name: CString },
}

struct Job {
    dir: Folder,
    /// Its path from the top (empty for the top).
    relative: String,
}

struct State {
    /// Last in, first out: the walk goes deep first, so few folders are held open at once.
    jobs: Vec<Job>,
    /// Workers listing a folder now (each may add jobs).
    busy: usize,
    failed: Option<io::Error>,
}

struct Queue {
    state: Mutex<State>,
    wake: Condvar,
}

impl Queue {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The next folder to list, or `None` once every folder is listed or the walk failed.
    fn next(&self) -> Option<Job> {
        let mut state = self.lock();
        loop {
            if state.failed.is_some() {
                return None;
            }
            if let Some(job) = state.jobs.pop() {
                state.busy = state.busy.saturating_add(1);
                return Some(job);
            }
            if state.busy == 0 {
                self.wake.notify_all();
                return None;
            }
            state = self.wake.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// A listed folder's outcome: the folders it found, or why it failed.
    fn done(&self, outcome: io::Result<Vec<Job>>) {
        let mut state = self.lock();
        state.busy = state.busy.saturating_sub(1);
        match outcome {
            Ok(jobs) => state.jobs.extend(jobs),
            Err(error) => {
                if state.failed.is_none() {
                    state.failed = Some(error);
                }
            }
        }
        self.wake.notify_all();
    }
}

fn worker<R: Rules>(top: &Path, rules: &R, queue: &Queue) -> Vec<(String, Found<R::Skip>)> {
    let mut found = Vec::new();
    while let Some(job) = queue.next() {
        queue.done(list(top, rules, job, &mut found));
    }
    found
}

/// Lists one folder into `found`; the folders in it to enter come back.
fn list<R: Rules>(
    top: &Path,
    rules: &R,
    job: Job,
    found: &mut Vec<(String, Found<R::Skip>)>,
) -> io::Result<Vec<Job>> {
    let dir = match job.dir {
        Folder::Open(fd) => fd,
        Folder::Child { parent, name } => match open_dir(parent.as_raw_fd(), &name) {
            Ok(Some(fd)) => fd,
            Ok(None) => return Ok(Vec::new()),
            // A symlink or file there since it was listed: as any entry.
            Err(error) if swapped(&error) => {
                if let Some(stat) = stat_at(parent.as_raw_fd(), &name)?
                    && stat.st_mode & libc::S_IFMT != libc::S_IFDIR
                    && let Some(entry) =
                        entry_of(rules, parent.as_raw_fd(), &name, &job.relative, &stat)?
                {
                    found.push((job.relative, entry));
                }
                return Ok(Vec::new());
            }
            Err(error) => return Err(error),
        },
    };
    let dir = Arc::new(dir);
    let here = top.join(&job.relative);
    let mut jobs = Vec::new();
    for name in names(dir.as_raw_fd())? {
        let relative = join(&job.relative, &name);
        let Some(relative) = relative else {
            let lossy = join_lossy(&job.relative, &name);
            found.push((lossy, Found::NotUtf8));
            continue;
        };
        let c_name = CString::new(name.into_vec())?;
        let Some(stat) = stat_at(dir.as_raw_fd(), &c_name)? else { continue };
        if stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
            let short = relative.rsplit('/').next().unwrap_or(&relative);
            if let Some(why) = rules.folder(&relative, &here, short) {
                found.push((relative, Found::Skipped(why)));
            } else {
                jobs.push(Job {
                    dir: Folder::Child { parent: Arc::clone(&dir), name: c_name },
                    relative,
                });
            }
            continue;
        }
        if let Some(entry) = entry_of(rules, dir.as_raw_fd(), &c_name, &relative, &stat)? {
            found.push((relative, entry));
        }
    }
    // Popped last in, first out: reversed, the folder's children go in name order.
    jobs.reverse();
    Ok(jobs)
}

/// The entry `name` of the folder `dir` (not a folder), as `stat` found it; `None` for a symlink
/// gone or replaced since.
fn entry_of<R: Rules>(
    rules: &R,
    dir: RawFd,
    name: &CStr,
    relative: &str,
    stat: &libc::stat,
) -> io::Result<Option<Found<R::Skip>>> {
    if let Some(why) = rules.entry(relative) {
        return Ok(Some(Found::Skipped(why)));
    }
    Ok(Some(match stat.st_mode & libc::S_IFMT {
        libc::S_IFREG => Found::File(stat_of(stat)),
        libc::S_IFLNK => match read_link(dir, name)? {
            Some(text) => Found::Link { text: String::from_utf8(text).ok(), stat: stat_of(stat) },
            // Not a symlink there any more, or gone: left out.
            None => return Ok(None),
        },
        _ => Found::Special,
    }))
}

fn join(prefix: &str, name: &OsStr) -> Option<String> {
    let name = name.to_str()?;
    Some(if prefix.is_empty() { name.to_owned() } else { format!("{prefix}/{name}") })
}

fn join_lossy(prefix: &str, name: &OsStr) -> String {
    let name = name.to_string_lossy();
    if prefix.is_empty() { name.into_owned() } else { format!("{prefix}/{name}") }
}

/// Whether opening a folder failed because something else is at its name now.
fn swapped(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR))
}

fn check(result: libc::c_int) -> io::Result<libc::c_int> {
    if result < 0 { Err(io::Error::last_os_error()) } else { Ok(result) }
}

/// The folder `name` of `dir`, never through a symlink; `None` when it is missing.
fn open_dir(dir: RawFd, name: &CStr) -> io::Result<Option<OwnedFd>> {
    // SAFETY: a valid descriptor (or AT_FDCWD) and C string; the result is checked.
    let fd = unsafe {
        libc::openat(
            dir,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    match check(fd) {
        // SAFETY: a new descriptor this handle owns.
        Ok(fd) => Ok(Some(unsafe { OwnedFd::from_raw_fd(fd) })),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// `fstatat` of `name` in `dir`, not following a symlink; `None` when it is gone.
fn stat_at(dir: RawFd, name: &CStr) -> io::Result<Option<libc::stat>> {
    // SAFETY: zeroed stat is a valid out value.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: a valid descriptor, C string and out pointer.
    let result = unsafe { libc::fstatat(dir, name.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW) };
    match check(result) {
        Ok(_) => Ok(Some(stat)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// The text of the symlink `name` in `dir`; `None` when it is gone or no longer a symlink.
fn read_link(dir: RawFd, name: &CStr) -> io::Result<Option<Vec<u8>>> {
    let mut buffer = vec![0u8; 4096];
    loop {
        // SAFETY: a valid descriptor, C string and buffer of `buffer.len()` bytes.
        let read = unsafe {
            libc::readlinkat(dir, name.as_ptr(), buffer.as_mut_ptr().cast(), buffer.len())
        };
        if read < 0 {
            let error = io::Error::last_os_error();
            return match error.raw_os_error() {
                Some(libc::ENOENT | libc::EINVAL) => Ok(None),
                _ => Err(error),
            };
        }
        let read = usize::try_from(read).unwrap_or(0);
        if read < buffer.len() {
            buffer.truncate(read);
            return Ok(Some(buffer));
        }
        let longer = buffer.len().saturating_mul(2);
        buffer.resize(longer, 0);
    }
}

/// A `mode_t`, `dev_t` or `ino_t` (their widths and signs vary) as u64.
fn widen<T: TryInto<u64>>(value: T) -> u64 {
    value.try_into().unwrap_or_default()
}

fn stat_of(stat: &libc::stat) -> Stat {
    Stat {
        mode: u32::try_from(widen(stat.st_mode) & 0o7777).unwrap_or(0),
        size: widen(stat.st_size),
        mtime_ns: stat.st_mtime.saturating_mul(1_000_000_000).saturating_add(stat.st_mtime_nsec),
        dev: widen(stat.st_dev),
        ino: widen(stat.st_ino),
    }
}

/// The names in the folder `dir` (never `.` or `..`), read through a descriptor of its own.
fn names(dir: RawFd) -> io::Result<Vec<OsString>> {
    // SAFETY: a valid descriptor and C string; the result is checked.
    let fd = check(unsafe {
        libc::openat(dir, c".".as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC)
    })?;
    // SAFETY: a new descriptor; on success the stream owns it.
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        let error = io::Error::last_os_error();
        // SAFETY: a failed `fdopendir` did not take the descriptor.
        unsafe { libc::close(fd) };
        return Err(error);
    }
    let stream = Stream(stream);
    let mut names = Vec::new();
    loop {
        clear_errno();
        // SAFETY: the stream is open and only this loop reads it.
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            let error = io::Error::last_os_error();
            if error.raw_os_error().unwrap_or(0) == 0 {
                return Ok(names);
            }
            return Err(error);
        }
        // SAFETY: `d_name` is the entry's NUL-terminated name, valid until the next `readdir`,
        // and copied before it.
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name != b"." && name != b".." {
            names.push(OsString::from_vec(name.to_vec()));
        }
    }
}

/// A folder's stream ([`names`]), closed when dropped.
struct Stream(*mut libc::DIR);

impl Drop for Stream {
    fn drop(&mut self) {
        // SAFETY: this owns the stream `fdopendir` answered.
        unsafe { libc::closedir(self.0) };
    }
}

/// Clears this thread's `errno`: `readdir` answers null both at the end and on an error, told
/// apart only by `errno`.
#[cfg(target_vendor = "apple")]
fn clear_errno() {
    // SAFETY: libc answers this thread's writable errno.
    unsafe { *libc::__error() = 0 };
}

/// Clears this thread's `errno` (see the macOS one).
#[cfg(not(target_vendor = "apple"))]
fn clear_errno() {
    // SAFETY: libc answers this thread's writable errno.
    unsafe { *libc::__errno_location() = 0 };
}

#[cfg(test)]
#[path = "walk_tests.rs"]
mod tests;
