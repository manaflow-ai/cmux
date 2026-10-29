//! The daemon's key echo path threads (p02-threads task 210).
//!
//! The threads a keystroke or its echoed output crosses (the connection
//! writer, the PTY input worker, attach writers, PTY readers, the terminal
//! host's parser, PTY, client output and client-input threads, frame
//! producers) start here: named, at [`ThreadQos::UserInteractive`], with
//! blocking disallowed. This is Chromium's display-critical thread
//! (`ThreadType::kDisplayCritical`, base/threading/platform_thread.h) with
//! `DisallowBlocking()` at its entry (base/threading/thread_restrictions.h).
//!
//! Terminal-host socket I/O is checked: the host-frames reader and
//! terminal-host-client-input read their socket through
//! [`cmux_threads::own_fd_read`] (`spawn_host_stream_reader`), and
//! terminal-host-client writes its output frames through
//! [`cmux_threads::own_fd_write`] (`with_own_host_stream`). The PTY and
//! control-socket I/O of the other echo threads is still plain std I/O,
//! which the detector does not see yet (follow-up task 210b in
//! plans/cmux-next/chrome-parity/p02-threads.md). Any checked blocking call on
//! an echo thread is a site in `cmux_threads::blocking::snapshot()`: recorded
//! by default, a panic under `CMUX_DAEMON_BLOCKING=panic` in debug builds
//! (queue MQ-13).

use std::io;

use cmux_threads::ThreadQos;

use crate::supervised::{self, Fatal, ShutdownBehavior, SupervisedThread};
use crate::thread_qos::ThreadType;

/// The class every echo path thread declares: [`ThreadType::InputCritical`].
pub const ECHO_PATH_QOS: ThreadQos = ThreadType::InputCritical.qos();

/// Starts echo path thread `name`: registered at [`ECHO_PATH_QOS`], blocking
/// disallowed before `f` runs.
pub fn spawn<F, T>(name: impl Into<String>, f: F) -> io::Result<SupervisedThread<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    supervised::spawn_at(name, ECHO_PATH_QOS, Fatal, ShutdownBehavior::Continue, move || {
        cmux_threads::disallow_blocking();
        f()
    })
}

/// [`spawn`] for a per-terminal echo thread that follows `desired`, the
/// terminal's class: it starts at [`ECHO_PATH_QOS`] and applies a change
/// itself with [`cmux_threads::apply_pending_qos`] after each wake (a hidden
/// terminal's threads run at utility).
pub fn spawn_following<F, T>(
    name: impl Into<String>,
    desired: cmux_threads::DesiredQos,
    f: F,
) -> io::Result<SupervisedThread<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    supervised::spawn_following(
        name,
        ECHO_PATH_QOS,
        desired,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            cmux_threads::disallow_blocking();
            f()
        },
    )
}

/// Runs `f` with `stream` as the current thread's own descriptor and
/// blocking disallowed, then restores the thread. The steady-state phase of
/// a thread whose setup may block (terminal-host-client: the handshake waits
/// for a parser boundary, its output loop does not).
#[cfg(any(unix, windows))]
pub(crate) fn with_own_host_stream<R>(
    stream: &crate::terminal_host_runtime::HostStream,
    f: impl FnOnce(&mut OwnHostStream<'_>) -> R,
) -> R {
    let mut own = OwnHostStream::register(stream);
    cmux_threads::with_blocking_disallowed(|| f(&mut own))
}

/// Starts echo path thread `name` that owns `stream`: the stream is the
/// thread's registered descriptor, then blocking is disallowed and `f` reads
/// the stream through `OwnHostStream`.
#[cfg(any(unix, windows))]
pub(crate) fn spawn_host_stream_reader<F, T>(
    name: impl Into<String>,
    stream: crate::terminal_host_runtime::HostStream,
    f: F,
) -> io::Result<SupervisedThread<T>>
where
    F: FnOnce(&mut OwnHostStream<'_>) -> T + Send + 'static,
    T: Send + 'static,
{
    let desired = cmux_threads::DesiredQos::new(ECHO_PATH_QOS);
    spawn_host_stream_reader_following(name, stream, desired, f)
}

/// [`spawn_host_stream_reader`] for a per-terminal reader that follows
/// `desired`, as [`spawn_following`].
#[cfg(any(unix, windows))]
pub(crate) fn spawn_host_stream_reader_following<F, T>(
    name: impl Into<String>,
    stream: crate::terminal_host_runtime::HostStream,
    desired: cmux_threads::DesiredQos,
    f: F,
) -> io::Result<SupervisedThread<T>>
where
    F: FnOnce(&mut OwnHostStream<'_>) -> T + Send + 'static,
    T: Send + 'static,
{
    supervised::spawn_following(
        name,
        ECHO_PATH_QOS,
        desired,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            // Registration is thread setup and must come before the disallow.
            let mut own = OwnHostStream::register(&stream);
            cmux_threads::disallow_blocking();
            f(&mut own)
        },
    )
}

/// The host stream a thread owns, read and written under the call-scoped
/// `AllowReason::OwnDescriptor` allowance. Windows streams have no
/// descriptor; there the I/O is the stream's own.
#[cfg(any(unix, windows))]
pub(crate) struct OwnHostStream<'s> {
    stream: &'s crate::terminal_host_runtime::HostStream,
    #[cfg(unix)]
    _registration: cmux_threads::OwnDescriptorToken<'s>,
}

#[cfg(any(unix, windows))]
impl<'s> OwnHostStream<'s> {
    fn register(stream: &'s crate::terminal_host_runtime::HostStream) -> Self {
        Self {
            stream,
            #[cfg(unix)]
            _registration: cmux_threads::register_own_descriptor(std::os::fd::AsFd::as_fd(stream)),
        }
    }
}

#[cfg(any(unix, windows))]
impl io::Read for OwnHostStream<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        #[cfg(unix)]
        {
            cmux_threads::own_fd_read(std::os::fd::AsFd::as_fd(self.stream), buf)
        }
        #[cfg(not(unix))]
        {
            use std::io::Read as _;
            let mut stream = self.stream;
            stream.read(buf)
        }
    }
}

#[cfg(any(unix, windows))]
impl io::Write for OwnHostStream<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        #[cfg(unix)]
        {
            cmux_threads::own_fd_write(std::os::fd::AsFd::as_fd(self.stream), buf)
        }
        #[cfg(not(unix))]
        {
            use std::io::Write as _;
            let mut stream = self.stream;
            stream.write(buf)
        }
    }

    /// Socket writes are unbuffered.
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
#[path = "echo_thread_tests.rs"]
mod tests;
