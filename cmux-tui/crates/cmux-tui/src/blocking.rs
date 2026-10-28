//! Blocking work in cmux-tui, as Chrome marks and places it.
//!
//! - [`off_worker`] runs a run of blocking calls on tokio's blocking pool, so
//!   an async fn never waits on the disk on a worker (Chrome's `MayBlock()`
//!   task trait, base/task/task_traits.h).
//! - The functions below are the blocking std calls `cmux_blocking` has no
//!   wrapper for, each inside `cmux_blocking::scoped_blocking_call` with the
//!   op name and kind cmux-tui/lab/clippy/clippy.toml gives it (Chrome's
//!   `ScopedBlockingCall`, base/threading/scoped_blocking_call.h). Calls with
//!   a wrapper use `cmux_blocking::{fs, sync, thread}` directly.

// Most callers are Unix-only code.
#![cfg_attr(not(unix), allow(dead_code))]

use std::io;

/// Runs `work` on the blocking pool and returns its result. A panic in
/// `work` resumes here; a runtime that shuts down before `work` starts gives
/// an `io::Error`.
pub(crate) async fn off_worker<T, E>(
    work: impl FnOnce() -> Result<T, E> + Send + 'static,
) -> Result<T, E>
where
    T: Send + 'static,
    E: From<io::Error> + Send + 'static,
{
    match cmux_blocking::spawn_blocking(work).await {
        Ok(result) => result,
        Err(error) if error.is_panic() => std::panic::resume_unwind(error.into_panic()),
        Err(error) => Err(E::from(io::Error::other(error))),
    }
}

pub(crate) mod fs {
    use std::fs::{DirBuilder, File, OpenOptions, Permissions};
    use std::io;
    use std::path::{Path, PathBuf};

    use cmux_blocking::{BlockingKind, scoped_blocking_call};

    /// `OpenOptions::open`.
    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn open_with(options: &OpenOptions, path: impl AsRef<Path>) -> io::Result<File> {
        scoped_blocking_call("fs::open_with", BlockingKind::Fs, || options.open(path))
    }

    /// `DirBuilder::create`.
    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn create_dir_with(builder: &DirBuilder, path: impl AsRef<Path>) -> io::Result<()> {
        scoped_blocking_call("fs::create_dir_with", BlockingKind::Fs, || builder.create(path))
    }

    /// `File::sync_all`: waits until the disk has the file.
    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn sync_all(file: &File) -> io::Result<()> {
        scoped_blocking_call("fs::sync_all", BlockingKind::Fs, || file.sync_all())
    }

    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn set_permissions(
        path: impl AsRef<Path>,
        permissions: Permissions,
    ) -> io::Result<()> {
        scoped_blocking_call("fs::set_permissions", BlockingKind::Fs, || {
            std::fs::set_permissions(path, permissions)
        })
    }

    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn create_dir(path: impl AsRef<Path>) -> io::Result<()> {
        scoped_blocking_call("fs::create_dir", BlockingKind::Fs, || std::fs::create_dir(path))
    }

    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn remove_dir(path: impl AsRef<Path>) -> io::Result<()> {
        scoped_blocking_call("fs::remove_dir", BlockingKind::Fs, || std::fs::remove_dir(path))
    }

    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn hard_link(original: impl AsRef<Path>, link: impl AsRef<Path>) -> io::Result<()> {
        scoped_blocking_call("fs::hard_link", BlockingKind::Fs, || {
            std::fs::hard_link(original, link)
        })
    }

    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn read_link(path: impl AsRef<Path>) -> io::Result<PathBuf> {
        scoped_blocking_call("fs::read_link", BlockingKind::Fs, || std::fs::read_link(path))
    }
}

pub(crate) mod thread {
    use cmux_blocking::{BlockingKind, scoped_blocking_call};

    /// `JoinHandle::join`: parks until the thread ends.
    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn join<T>(handle: std::thread::JoinHandle<T>) -> std::thread::Result<T> {
        scoped_blocking_call("thread::join", BlockingKind::Join, || handle.join())
    }
}

pub(crate) mod sync {
    use std::sync::mpsc::{Receiver, RecvTimeoutError};
    use std::time::Duration;

    use cmux_blocking::{BlockingKind, scoped_blocking_call};

    /// `Receiver::recv_timeout`.
    #[track_caller]
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    pub(crate) fn recv_timeout<T>(
        receiver: &Receiver<T>,
        timeout: Duration,
    ) -> Result<T, RecvTimeoutError> {
        scoped_blocking_call("sync::recv_timeout", BlockingKind::Recv, || {
            // wakeup-allow: deadline the caller's own timed receive, passed through; the audit judges the caller's recv_timeout(
            receiver.recv_timeout(timeout)
        })
    }

    /// `Receiver::recv_timeout` for a remote session's reply. The session's
    /// requests also run on the `mux-pty-input` echo thread, which disallows
    /// blocking, so this wait is not checked: a checked one panics there in
    /// debug builds. It is a known blocking site until remote requests leave
    /// that thread.
    #[allow(clippy::disallowed_methods, reason = "the echo-thread remote reply wait, named here")]
    pub(crate) fn remote_reply_timeout<T>(
        receiver: &Receiver<T>,
        timeout: Duration,
    ) -> Result<T, RecvTimeoutError> {
        // wakeup-allow: deadline the caller's own timed receive, passed through; the audit judges the caller's remote_reply_timeout(
        receiver.recv_timeout(timeout)
    }
}

#[cfg(test)]
#[path = "blocking_tests.rs"]
mod tests;
