//! The daemon's IO reactor, its write side (plans/cmux-next/chrome-parity/
//! p05-ipc.md, task p05-ipc-156): one thread flushes the outbound queue of
//! every line connection, so an open connection holds no writer thread.
//!
//! This is Mojo's write path on Chrome's IO thread. `ChannelPosix::Write`
//! (mojo/core/channel_posix.cc) writes what the socket takes now; when the
//! socket would block it keeps the rest and waits for writability
//! (`WaitForWriteOnIOThread`), and `OnFileCanWriteWithoutBlocking` resumes
//! at the byte it stopped. One message pump (base/message_loop/
//! message_pump_epoll.cc, message_pump_kqueue.cc) serves every channel. The
//! reactor itself is in server/io_reactor_poll.rs (Unix).
//!
//! The reactor writes only what it can write without blocking: a connected
//! Unix socket it can poll. Any other stream, a Windows socket today
//! (uds_windows has no nonblocking send to poll), is written by a
//! `mux-line-out` thread of its own, the blocking writer the reactor
//! replaced, so a peer that stops reading holds up only its own writer. So
//! is every connection that arrives after the reactor stopped (a failed
//! poll): the daemon keeps serving.
//!
//! Whoever writes it, a connection's output ends the same way: its queue
//! closes, its socket shuts down (the client reads the end and the
//! connection's reader stops) and its end guard drops (its writer closes,
//! its slot is free).

use std::io;
use std::net::Shutdown;
use std::sync::Arc;
#[cfg(unix)]
use std::sync::OnceLock;

use super::bounded_outbound::write_counted_batch;
use super::{BoundedOutbound, EchoWatch, STREAM_WRITE_TIMEOUT, WatchKind};
use crate::diagnostics::IpcStats;
use crate::platform::transport;

#[cfg(unix)]
#[path = "io_reactor_poll.rs"]
mod poll;
#[cfg(unix)]
pub(super) use poll::REACTOR_THREAD;

/// The writer thread of one connection the reactor does not write.
pub(super) const LINE_OUT_THREAD: &str = "mux-line-out";

/// The write side of one line connection, handed to its writer.
pub(super) struct LineOutput {
    pub(super) outbound: Arc<BoundedOutbound>,
    /// A handle on the connection's socket the writer writes and, at the
    /// end, shuts down.
    pub(super) socket: Box<dyn transport::Stream>,
    pub(super) ipc: Arc<IpcStats>,
    /// Each write is one 100 ms hang scope of the mux's watchdog.
    pub(super) hangs: EchoWatch,
    /// Dropped once the connection's output ended, after its socket shut
    /// down: it closes the connection's writer and frees its slot.
    pub(super) _end: Box<dyn Send>,
}

impl Drop for LineOutput {
    fn drop(&mut self) {
        self.outbound.close();
        let _ = self.socket.shutdown(Shutdown::Both);
        // `_end` drops after this: the writer closes, the slot frees.
    }
}

/// The reactor of one mux: started by its first connection, stopped when
/// the mux drops and its last connection ended.
#[derive(Default)]
pub(crate) struct IoReactor {
    #[cfg(unix)]
    started: OnceLock<poll::Handle>,
}

impl std::fmt::Debug for IoReactor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut debug = f.debug_struct("IoReactor");
        #[cfg(unix)]
        debug.field("started", &self.started.get().is_some());
        debug.finish()
    }
}

impl IoReactor {
    /// Writes `output`'s queue from now on: on the reactor when it can poll
    /// the socket, else on a writer thread of its own. An error (no writer
    /// thread could start) drops `output`, which ends it.
    pub(super) fn serve(&self, output: LineOutput) -> io::Result<()> {
        match self.adopt(output) {
            Ok(()) => Ok(()),
            Err(output) => write_on_own_thread(output),
        }
    }

    /// Hands `output` to the reactor, or back when the reactor cannot write
    /// it (no socket to poll, or the reactor could not start or stopped).
    #[cfg(unix)]
    fn adopt(&self, output: LineOutput) -> Result<(), LineOutput> {
        let Some(fd) = output.socket.socket_fd() else { return Err(output) };
        match self.handle() {
            Ok(handle) => handle.adopt(output, fd),
            Err(error) => {
                eprintln!("cmux-tui: {REACTOR_THREAD} could not start: {error}");
                Err(output)
            }
        }
    }

    #[cfg(not(unix))]
    fn adopt(&self, output: LineOutput) -> Result<(), LineOutput> {
        Err(output)
    }

    #[cfg(unix)]
    fn handle(&self) -> io::Result<&poll::Handle> {
        if let Some(handle) = self.started.get() {
            return Ok(handle);
        }
        // Two first connections may both start one; the second stops its own.
        if let Err(lost) = self.started.set(poll::Handle::start()?) {
            lost.stop();
        }
        self.started
            .get()
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "the IO reactor stopped"))
    }

    /// Times the reactor's poll returned since it started: an idle daemon
    /// adds none.
    #[cfg(all(test, unix))]
    pub(super) fn wakeups(&self) -> u64 {
        self.started.get().map_or(0, poll::Handle::wakeups)
    }

    /// Connections whose output the reactor writes now.
    #[cfg(all(test, unix))]
    pub(super) fn connections(&self) -> usize {
        self.started.get().map_or(0, poll::Handle::connections)
    }

    /// Stops the reactor (as the mux's drop does) and waits until its
    /// thread is gone: the connections served after it get writer threads.
    #[cfg(all(test, unix))]
    pub(super) fn stop_and_wait(&self) {
        if let Some(handle) = self.started.get() {
            handle.stop();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            while !handle.stopped() {
                assert!(std::time::Instant::now() < deadline, "the reactor never stopped");
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        }
    }
}

impl Drop for IoReactor {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(handle) = self.started.get() {
            handle.stop();
        }
    }
}

/// Writes `output` on a `mux-line-out` thread of its own, blocking, under
/// the socket's write timeout (2 s, `SO_SNDTIMEO`): the writer the reactor
/// replaced, for a stream the reactor cannot write. The output ends however
/// the thread ends, a panic included.
fn write_on_own_thread(output: LineOutput) -> io::Result<()> {
    crate::echo_thread::spawn(LINE_OUT_THREAD, move || {
        let mut output = output;
        let _hang_watch =
            cmux_hang_watch::register_thread(cmux_hang_watch::ThreadKind::Io, LINE_OUT_THREAD);
        // Every ready item up to 256 KiB leaves in one writev (p05-ipc-088).
        let mut batch = Vec::new();
        // mq14-allow: the writer's idle wait for its own queue (BoundedOutbound::recv_batch).
        while output.outbound.recv_batch(&mut batch) {
            // Each batch's write is a 100 ms hang scope; the wait above is not.
            let _batch = output.hangs.item(WatchKind::LineOutThread);
            // One scope per write, as long as the socket's write timeout.
            let write = cmux_hang_watch::watch(STREAM_WRITE_TIMEOUT);
            let written = write_counted_batch(&mut *output.socket, &output.ipc, &batch);
            drop(write);
            // The written texts go now, not when the next item arrives.
            batch.clear();
            if written.is_err() {
                break;
            }
        }
    })
    .map(drop)
}

#[cfg(all(test, unix))]
#[path = "io_reactor_tests.rs"]
mod tests;
