//! Part of `Hub`; see `hub/mod.rs`. One thread waits for the end of every watched background
//! task's runner (`bg_notify.rs`), not one thread per task.
//!
//! A runner holds `<id>.lock` until it wrote its exit, and the kernel frees it when the runner
//! dies (`bg_run.rs`): the lock stays what says a task ended. What wakes the check is the runner's
//! exit, learned from its pid ([`bg_run::Record::runner_pid`]): `EVFILT_PROC`/`NOTE_EXIT` on one
//! kqueue on macOS, a pidfd on one epoll on Linux. On each exit, and once right after a runner is
//! registered (it may have ended before), the lock is tried without blocking: free, the task's end
//! goes out; still held (a reused pid, a runner that is not the lock's holder), the task falls back
//! to a thread of its own that blocks on the lock, as every task did before.
//!
//! Why: on the owner's Mac under load (2026-11-22, load 93-100, swap full) the daemon ran 40
//! `acpmux-bg-watch` threads, each parked in `flock` for a task still running. Nothing polls here
//! either.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// What runs once a watched lock is free: it must return at once (it runs on the watch thread).
pub(super) type Done = Box<dyn FnOnce() + Send>;

/// Watches lock `lock`, held by runner `runner_pid`, and calls `done` once nothing holds it.
/// `runner_pid` 0 (a record from before runners wrote it) or a platform with no exit watch takes
/// a thread of its own.
pub(super) fn watch(lock: PathBuf, runner_pid: u32, done: Done) {
    if runner_pid != 0
        && let Some(watcher) = Watcher::shared()
    {
        return watcher.add(lock, runner_pid, done);
    }
    fallback(lock, done);
}

/// The thread of its own: blocks on the lock, then calls `done`.
fn fallback(lock: PathBuf, done: Done) {
    let spawned = std::thread::Builder::new().name("acpmux-bg-watch".into()).spawn(move || {
        wait_unlocked(&lock);
        done();
    });
    if let Err(e) = spawned {
        tracing::warn!("a background task's end cannot be watched: {e}");
    }
}

/// Whether nothing holds the lock at `path` (a missing file holds nothing), without waiting.
pub(super) fn unlocked(path: &Path) -> bool {
    let Ok(file) = crate::home_fs::OpenOptions::new().read(true).write(true).open(path) else {
        return true;
    };
    // An error other than "held" cannot be waited on: free.
    !cmux_file_lock::FileLock::held_elsewhere(&file, cmux_file_lock::Kind::Exclusive)
        .unwrap_or(false)
}

/// Blocks until nothing holds the lock at `path` (a missing file holds nothing), then lets go.
pub(super) fn wait_unlocked(path: &Path) {
    let Ok(file) = crate::home_fs::OpenOptions::new().read(true).write(true).open(path) else {
        return;
    };
    // Taken, then dropped at once (unlocked), so a liveness probe sees it free.
    drop(cmux_file_lock::FileLock::take(file, cmux_file_lock::Kind::Exclusive));
}

/// A watched task: its lock, what runs once it is free, and (Linux) its runner's pidfd.
struct Entry {
    lock: PathBuf,
    done: Done,
    #[cfg(target_os = "linux")]
    _pidfd: std::os::fd::OwnedFd,
}

/// The one exit watch of this process.
struct Watcher {
    /// The kqueue (macOS) or epoll (Linux) the thread waits on.
    queue: std::os::fd::OwnedFd,
    entries: Mutex<Entries>,
}

#[derive(Default)]
struct Entries {
    next: u64,
    by_token: HashMap<u64, Entry>,
}

impl Watcher {
    /// The process's watcher, its thread started at the first use; None where the platform has
    /// no exit watch or it failed to start.
    fn shared() -> Option<&'static Watcher> {
        static SHARED: OnceLock<Option<&'static Watcher>> = OnceLock::new();
        *SHARED.get_or_init(|| {
            let queue = match new_queue() {
                Ok(queue) => queue,
                Err(e) => {
                    tracing::warn!("background task ends take a thread each: {e}");
                    return None;
                }
            };
            let watcher: &'static Watcher =
                Box::leak(Box::new(Watcher { queue, entries: Mutex::default() }));
            let spawned = std::thread::Builder::new()
                .name("acpmux-bg-watch".into())
                .spawn(move || watcher.run());
            match spawned {
                Ok(_) => Some(watcher),
                Err(e) => {
                    tracing::warn!("background task ends take a thread each: {e}");
                    None
                }
            }
        })
    }

    fn lock_entries(&self) -> std::sync::MutexGuard<'_, Entries> {
        self.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn add(&self, lock: PathBuf, runner_pid: u32, done: Done) {
        // Registered first, then the lock tried: a runner that ended before the registration is
        // seen free here, one that ends after it wakes the thread.
        let token = {
            let mut entries = self.lock_entries();
            entries.next += 1;
            entries.next
        };
        match register(&self.queue, token, runner_pid) {
            Ok(registered) => {
                let entry = Entry {
                    lock: lock.clone(),
                    done,
                    #[cfg(target_os = "linux")]
                    _pidfd: registered,
                };
                #[cfg(not(target_os = "linux"))]
                let () = registered;
                self.lock_entries().by_token.insert(token, entry);
                if unlocked(&lock) {
                    self.settle(token);
                }
            }
            // No such process: the runner ended; its lock says whether the task did.
            Err(e) if e.raw_os_error() == Some(libc::ESRCH) => {
                if unlocked(&lock) {
                    done()
                } else {
                    fallback(lock, done)
                }
            }
            Err(e) => {
                tracing::debug!(%runner_pid, "a runner's exit cannot be watched: {e}");
                fallback(lock, done);
            }
        }
    }

    /// Token `token`'s runner exited (or its lock read free): its end goes out once the lock is
    /// free, else it waits on a thread of its own. Once per token: a second call finds nothing.
    fn settle(&self, token: u64) {
        let Some(entry) = self.lock_entries().by_token.remove(&token) else { return };
        // Linux: the pidfd's close takes it out of the epoll. macOS: a one-shot event left for a
        // token settled by its lock read wakes this once more and finds no entry.
        if unlocked(&entry.lock) { (entry.done)() } else { fallback(entry.lock, entry.done) }
    }

    fn run(&self) {
        loop {
            match wait(&self.queue) {
                Ok(tokens) => {
                    for token in tokens {
                        self.settle(token);
                    }
                }
                Err(e) if e.raw_os_error() == Some(libc::EINTR) => {}
                Err(e) => {
                    // Never spins: what is watched now waits on threads of their own.
                    tracing::warn!("the background task exit watch stopped: {e}");
                    let entries = std::mem::take(&mut self.lock_entries().by_token);
                    for (_, entry) in entries {
                        fallback(entry.lock, entry.done);
                    }
                    return;
                }
            }
        }
    }

    #[cfg(test)]
    fn watched(&self) -> usize {
        self.lock_entries().by_token.len()
    }
}

#[cfg(target_os = "macos")]
fn new_queue() -> std::io::Result<std::os::fd::OwnedFd> {
    use std::os::fd::FromRawFd;
    // SAFETY: kqueue has no preconditions.
    let raw = unsafe { libc::kqueue() };
    if raw < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: a new descriptor nothing else owns.
    let queue = unsafe { std::os::fd::OwnedFd::from_raw_fd(raw) };
    // SAFETY: fcntl on the descriptor just made.
    unsafe { libc::fcntl(raw, libc::F_SETFD, libc::FD_CLOEXEC) };
    Ok(queue)
}

#[cfg(target_os = "macos")]
fn proc_event(token: u64, pid: u32, flags: u16) -> libc::kevent {
    libc::kevent {
        ident: pid as usize,
        filter: libc::EVFILT_PROC,
        flags,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: token as usize as *mut libc::c_void,
    }
}

#[cfg(target_os = "macos")]
fn register(queue: &std::os::fd::OwnedFd, token: u64, pid: u32) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    let change = proc_event(token, pid, libc::EV_ADD | libc::EV_ONESHOT);
    // SAFETY: one valid change, no events asked back.
    let n = unsafe {
        libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
    };
    if n < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
}

#[cfg(target_os = "macos")]
fn wait(queue: &std::os::fd::OwnedFd) -> std::io::Result<Vec<u64>> {
    use std::os::fd::AsRawFd;
    // SAFETY: kevent is plain data.
    let mut events: [libc::kevent; 32] = unsafe { std::mem::zeroed() };
    // SAFETY: a valid kqueue and a buffer of `events.len()` events; no timeout.
    let n = unsafe {
        libc::kevent(
            queue.as_raw_fd(),
            std::ptr::null(),
            0,
            events.as_mut_ptr(),
            events.len() as libc::c_int,
            std::ptr::null(),
        )
    };
    if n < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(events[..n as usize].iter().map(|e| e.udata as usize as u64).collect())
}

#[cfg(target_os = "linux")]
fn new_queue() -> std::io::Result<std::os::fd::OwnedFd> {
    use std::os::fd::FromRawFd;
    // SAFETY: epoll_create1 has no preconditions.
    let raw = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
    if raw < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: a new descriptor nothing else owns.
    Ok(unsafe { std::os::fd::OwnedFd::from_raw_fd(raw) })
}

#[cfg(target_os = "linux")]
fn register(
    queue: &std::os::fd::OwnedFd,
    token: u64,
    pid: u32,
) -> std::io::Result<std::os::fd::OwnedFd> {
    use std::os::fd::{AsRawFd, FromRawFd};
    let pid = libc::pid_t::try_from(pid).map_err(std::io::Error::other)?;
    // SAFETY: pidfd_open takes a pid and flags; it returns a new descriptor or -1.
    let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if raw < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let raw = i32::try_from(raw).map_err(std::io::Error::other)?;
    // SAFETY: a new descriptor nothing else owns (pidfds are close-on-exec).
    let pidfd = unsafe { std::os::fd::OwnedFd::from_raw_fd(raw) };
    let mut event = libc::epoll_event { events: libc::EPOLLIN as u32, u64: token };
    // SAFETY: a valid epoll, a valid pidfd and an event this call reads.
    if unsafe { libc::epoll_ctl(queue.as_raw_fd(), libc::EPOLL_CTL_ADD, raw, &mut event) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(pidfd)
}

#[cfg(target_os = "linux")]
fn wait(queue: &std::os::fd::OwnedFd) -> std::io::Result<Vec<u64>> {
    use std::os::fd::AsRawFd;
    let mut events = [libc::epoll_event { events: 0, u64: 0 }; 32];
    // SAFETY: a valid epoll and a buffer of `events.len()` events; no timeout.
    let n = unsafe {
        libc::epoll_wait(queue.as_raw_fd(), events.as_mut_ptr(), events.len() as libc::c_int, -1)
    };
    if n < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(events[..n as usize].iter().map(|e| e.u64).collect())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn new_queue() -> std::io::Result<std::os::fd::OwnedFd> {
    Err(std::io::Error::other("no process exit watch on this platform"))
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn register(_: &std::os::fd::OwnedFd, _: u64, _: u32) -> std::io::Result<()> {
    Err(std::io::Error::other("no process exit watch on this platform"))
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn wait(_: &std::os::fd::OwnedFd) -> std::io::Result<Vec<u64>> {
    Err(std::io::Error::other("no process exit watch on this platform"))
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn threads() -> usize {
        std::fs::read_dir("/proc/self/task").map(|d| d.count()).unwrap_or(0)
    }

    /// 64 running tasks take no thread each; each task's end goes out once its runner exits,
    /// and not before.
    #[test]
    fn one_thread_watches_every_runner() {
        if !Path::new("/usr/bin/flock").exists() && !Path::new("/bin/flock").exists() {
            eprintln!("skip: the util-linux lock command is missing");
            return;
        }
        let dir = cmux_unix_socket::short_test_dir("bg-exit-watch");
        let (tx, rx) = std::sync::mpsc::channel::<usize>();
        let mut runners = Vec::new();
        for i in 0..64 {
            let lock = dir.path().join(format!("{i}.lock"));
            std::fs::write(&lock, b"").unwrap();
            // The runner: holds the lock until its stdin closes.
            let child = cmux_process::Command::new("flock")
                .arg(&lock)
                .args(["sh", "-c", "read _"])
                .stdin(cmux_process::Stdio::piped())
                .spawn()
                .unwrap();
            runners.push((lock, child));
        }
        // flock(1) takes the lock after its start: wait until each holds it.
        let deadline = Instant::now() + Duration::from_secs(10);
        while runners.iter().any(|(lock, _)| unlocked(lock)) {
            assert!(Instant::now() < deadline, "the runners never took their locks");
            std::thread::sleep(Duration::from_millis(10));
        }
        // The watcher's own thread, started once.
        let _ = Watcher::shared().unwrap();
        let before = threads();
        for (i, (lock, child)) in runners.iter().enumerate() {
            let tx = tx.clone();
            watch(lock.clone(), child.id(), Box::new(move || tx.send(i).unwrap()));
        }
        assert_eq!(threads(), before, "a watched task took a thread of its own");
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "an end went out early");
        assert!(Watcher::shared().unwrap().watched() >= 64);
        // Each runner ends: its end goes out.
        let started = Instant::now();
        let mut ended = std::collections::BTreeSet::new();
        for (_, mut child) in runners {
            // Closes its stdin first: `read` ends, then the runner.
            child.wait().unwrap();
        }
        while ended.len() < 64 {
            let i = rx.recv_timeout(Duration::from_secs(5)).expect("a task's end never went out");
            assert!(ended.insert(i), "task {i}'s end went out twice");
        }
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    /// A runner that ended before its watch, and a pid that holds no lock, are settled by the
    /// lock: at once.
    #[test]
    fn an_ended_runner_settles_at_once() {
        let dir = cmux_unix_socket::short_test_dir("bg-exit-gone");
        let lock = dir.path().join("t.lock");
        std::fs::write(&lock, b"").unwrap();
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        // This process's pid: it runs, and holds no lock on the file.
        let tx2 = tx.clone();
        watch(lock.clone(), std::process::id(), Box::new(move || tx2.send(()).unwrap()));
        rx.recv_timeout(Duration::from_secs(2)).expect("a free lock's end never went out");
        // A pid that no process has.
        let mut child = cmux_process::Command::new("true").spawn().unwrap();
        let pid = child.id();
        child.wait().unwrap();
        watch(lock, pid, Box::new(move || tx.send(()).unwrap()));
        rx.recv_timeout(Duration::from_secs(2)).expect("an ended runner's end never went out");
    }
}
