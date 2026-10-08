//! Event-driven wait for a host's move into its scope (cx-4eho).
//!
//! `StartTransientUnit` only queues the job; the host may get `Launch` (and
//! fork its shell) only after the kernel moved it. Instead of polling, the
//! daemon watches the cgroup v2 tree with inotify: `IN_CREATE` on the
//! cgroup root (for the slice), on the slice directory (for the scope), on
//! the scope directory (for its `cgroup.events`), and `IN_MODIFY` on the
//! scope's `cgroup.events`, which the kernel rewrites when the scope
//! becomes populated. A watch is armed on a path only after the path
//! exists, and each level is watched before the next level is checked, so
//! a child that appears between two checks still wakes the wait. The
//! watches are added BEFORE the `StartTransientUnit` call, so no event can
//! be missed; after every wake the state is read again (event order is not
//! trusted). The wait is one `poll()` deadline; on timeout, on a cgroup v1
//! host, or when inotify cannot be set up, the caller fails open.

use std::ffi::CString;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Why a placement wait did not confirm the move.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PlacementMiss {
    /// No unified (v2) cgroup hierarchy at the root.
    NotCgroupV2,
    /// inotify could not be set up (limits, permissions).
    NoInotify,
    /// The scope did not become populated before the deadline.
    TimedOut,
}

/// Watches set up before the move is requested.
pub(crate) struct PlacementWatch {
    inotify: OwnedFd,
    root: PathBuf,
    slice: PathBuf,
    scope: PathBuf,
    watching_slice: bool,
    watching_scope: bool,
    watching_events: bool,
}

fn add_watch(fd: &OwnedFd, path: &Path, mask: u32) -> bool {
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else { return false };
    // SAFETY: a valid inotify descriptor and a NUL-terminated path.
    unsafe { libc::inotify_add_watch(fd.as_raw_fd(), path.as_ptr(), mask) >= 0 }
}

impl PlacementWatch {
    /// Watch for `scope` (a directory name) under `slice` below the cgroup
    /// `root`. Call before asking systemd to start the scope.
    pub(crate) fn new(root: &Path, slice: &str, scope: &str) -> Result<Self, PlacementMiss> {
        if !root.join("cgroup.controllers").is_file() {
            return Err(PlacementMiss::NotCgroupV2);
        }
        // SAFETY: inotify_init1 takes flags only and returns a new descriptor.
        let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
        if fd < 0 {
            return Err(PlacementMiss::NoInotify);
        }
        // SAFETY: inotify_init1 returned a fresh descriptor this process owns.
        let inotify = unsafe { OwnedFd::from_raw_fd(fd) };
        let slice = root.join(slice);
        let mut watch = Self {
            scope: slice.join(scope),
            slice,
            root: root.to_path_buf(),
            inotify,
            watching_slice: false,
            watching_scope: false,
            watching_events: false,
        };
        if !add_watch(&watch.inotify, &watch.root, libc::IN_CREATE) {
            return Err(PlacementMiss::NoInotify);
        }
        watch.extend();
        Ok(watch)
    }

    /// Add the deeper watches whose directories exist now.
    fn extend(&mut self) {
        if !self.watching_slice && self.slice.is_dir() {
            self.watching_slice = add_watch(&self.inotify, &self.slice, libc::IN_CREATE);
        }
        if !self.watching_scope && self.scope.is_dir() {
            // Do not assume `cgroup.events` exists with its directory: watch
            // the directory, so a file that appears later still wakes us.
            self.watching_scope = add_watch(&self.inotify, &self.scope, libc::IN_CREATE);
        }
        let events = self.scope.join("cgroup.events");
        if !self.watching_events && events.is_file() {
            self.watching_events = add_watch(&self.inotify, &events, libc::IN_MODIFY);
        }
    }

    fn populated(&self) -> bool {
        std::fs::read_to_string(self.scope.join("cgroup.events"))
            .is_ok_and(|events| events.lines().any(|line| line.trim() == "populated 1"))
    }

    /// Wait until the scope is populated, at most `timeout`.
    pub(crate) fn wait(mut self, timeout: Duration) -> Result<(), PlacementMiss> {
        let deadline = Instant::now() + timeout;
        let mut buffer = [0u8; 4096];
        loop {
            // Re-read the state after every wake; event order is not trusted.
            self.extend();
            if self.populated() {
                return Ok(());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(PlacementMiss::TimedOut);
            }
            let millis = libc::c_int::try_from(remaining.as_millis().max(1)).unwrap_or(i32::MAX);
            let mut poll =
                libc::pollfd { fd: self.inotify.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            // SAFETY: one valid pollfd for the duration of the call.
            let ready = unsafe { libc::poll(&mut poll, 1, millis) };
            if ready < 0
                && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
            {
                return Err(PlacementMiss::NoInotify);
            }
            // Drain the queued events; their content is not needed.
            // SAFETY: the buffer outlives the call and its length is passed.
            while unsafe {
                libc::read(self.inotify.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len())
            } > 0
            {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "cmux-placement-{name}-{}-{:?}",
            std::process::id(),
            Instant::now()
        ));
        std::fs::create_dir_all(&root).ok();
        root
    }

    #[test]
    fn the_wait_ends_on_the_kernel_event_when_the_scope_becomes_populated() {
        let root = temp_root("ok");
        std::fs::write(root.join("cgroup.controllers"), "cpu memory\n").ok();
        let watch = PlacementWatch::new(&root, "s.slice", "h.scope");
        assert!(watch.is_ok(), "{:?}", watch.as_ref().err());
        let writer_root = root.clone();
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            let scope = writer_root.join("s.slice").join("h.scope");
            std::fs::create_dir_all(&scope).ok();
            std::fs::write(scope.join("cgroup.events"), "populated 0\nfrozen 0\n").ok();
            std::thread::sleep(Duration::from_millis(50));
            std::fs::write(scope.join("cgroup.events"), "populated 1\nfrozen 0\n").ok();
        });
        let started = Instant::now();
        let result = watch.map(|watch| watch.wait(Duration::from_secs(5)));
        writer.join().ok();
        assert_eq!(result, Ok(Ok(())));
        assert!(started.elapsed() < Duration::from_secs(4), "the wait did not end on the event");
        std::fs::remove_dir_all(&root).ok();
    }

    /// cx-nvhp: the scope directory can be visible before its
    /// `cgroup.events` file. The watch must still see the file appear and
    /// then its change, instead of sleeping to the deadline.
    #[test]
    fn the_wait_ends_on_the_event_when_cgroup_events_appears_after_the_scope() {
        let root = temp_root("late-events");
        std::fs::write(root.join("cgroup.controllers"), "cpu memory\n").ok();
        let scope = root.join("s.slice").join("h.scope");
        std::fs::create_dir_all(&scope).ok();
        let watch = PlacementWatch::new(&root, "s.slice", "h.scope");
        assert!(watch.is_ok(), "{:?}", watch.as_ref().err());
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            std::fs::write(scope.join("cgroup.events"), "populated 0\nfrozen 0\n").ok();
            std::thread::sleep(Duration::from_millis(50));
            std::fs::write(scope.join("cgroup.events"), "populated 1\nfrozen 0\n").ok();
        });
        let started = Instant::now();
        let result = watch.map(|watch| watch.wait(Duration::from_secs(5)));
        writer.join().ok();
        assert_eq!(result, Ok(Ok(())));
        assert!(started.elapsed() < Duration::from_secs(4), "the wait did not end on the event");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_scope_that_never_fills_times_out_and_fails_open() {
        let root = temp_root("timeout");
        std::fs::write(root.join("cgroup.controllers"), "cpu\n").ok();
        let result = PlacementWatch::new(&root, "s.slice", "h.scope")
            .map(|watch| watch.wait(Duration::from_millis(150)));
        assert_eq!(result, Ok(Err(PlacementMiss::TimedOut)));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_cgroup_v1_host_is_reported_without_waiting() {
        let root = temp_root("v1");
        let started = Instant::now();
        let result = PlacementWatch::new(&root, "s.slice", "h.scope").map(|_| ());
        assert_eq!(result, Err(PlacementMiss::NotCgroupV2));
        assert!(started.elapsed() < Duration::from_millis(100));
        std::fs::remove_dir_all(&root).ok();
    }
}
