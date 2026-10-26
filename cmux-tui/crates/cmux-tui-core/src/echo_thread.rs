//! The daemon's key echo path threads (p02-threads task 210).
//!
//! Every thread a keystroke or its echoed output crosses (the connection
//! reader and writer, the PTY input worker, attach writers, PTY readers, the
//! terminal host's parser, PTY and client-input threads, frame producers)
//! starts here: named, at [`ThreadQos::UserInteractive`], with blocking
//! disallowed for its whole life. This is Chromium's display-critical thread
//! (`ThreadType::kDisplayCritical`, base/threading/platform_thread.h) with
//! `DisallowBlocking()` at its entry (base/threading/thread_restrictions.h).
//!
//! The one wait such a thread is built around, a read on the stream it owns,
//! goes through [`cmux_threads::own_fd_read`] on that registered descriptor
//! (`spawn_host_stream_reader`). Any other blocking call it makes is a site
//! in `cmux_threads::blocking::snapshot()`: recorded by default, a panic
//! under `CMUX_DAEMON_BLOCKING=panic` in debug builds (queue MQ-13).

use std::io;
use std::thread::JoinHandle;

use cmux_threads::ThreadQos;

/// The class every echo path thread declares.
pub const ECHO_PATH_QOS: ThreadQos = ThreadQos::UserInteractive;

/// Starts echo path thread `name`: registered at [`ECHO_PATH_QOS`], blocking
/// disallowed before `f` runs.
pub fn spawn<F, T>(name: impl Into<String>, f: F) -> io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    cmux_threads::spawn(name, ECHO_PATH_QOS, move || {
        cmux_threads::disallow_blocking();
        f()
    })
}

/// Starts echo path thread `name` that owns `stream`: the stream is the
/// thread's registered descriptor, then blocking is disallowed and `f` reads
/// the stream through `OwnHostStream`.
#[cfg(any(unix, windows))]
pub(crate) fn spawn_host_stream_reader<F, T>(
    name: impl Into<String>,
    stream: crate::terminal_host_runtime::HostStream,
    f: F,
) -> io::Result<JoinHandle<T>>
where
    F: FnOnce(&mut OwnHostStream<'_>) -> T + Send + 'static,
    T: Send + 'static,
{
    cmux_threads::spawn(name, ECHO_PATH_QOS, move || {
        // Registration is thread setup and must come before the disallow.
        let mut own = OwnHostStream::register(&stream);
        cmux_threads::disallow_blocking();
        f(&mut own)
    })
}

/// The host stream a thread owns, read under the call-scoped
/// `AllowReason::OwnDescriptor` allowance. Windows streams have no
/// descriptor; there the read is the stream's own.
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

#[cfg(test)]
#[path = "echo_thread_tests.rs"]
mod tests;
