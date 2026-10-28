//! The inline write fast path of a connection's outbound queue
//! (plans/cmux-next/chrome-parity/p05-ipc.md, task 140).
//!
//! Chromium's mojo/core/channel_posix.cc `ChannelPosix::Write` writes a
//! message on the calling thread when `outgoing_messages_` is empty and
//! leaves only what the socket did not take (EAGAIN, a partial write) to the
//! IO thread. Here a producer writes its item itself, under the outbound
//! state lock, when nothing is queued and the `mux-line-out` writer is not
//! writing: no queue, no condvar, no writer wake-up. The send never waits
//! for room. When the socket takes none or part of it, the rest is the next
//! thing the writer thread writes, ahead of every queued item.

#[cfg(unix)]
use super::BatchPoll;
use super::BoundedOutbound;
use super::BoundedOutboundState;
use super::OutboundItem;
use crate::diagnostics::IpcStats;
use crate::panic_free::RecoverPoison;
use crate::platform::transport;
#[cfg(any(test, not(unix)))]
use cmux_threads::sync::Mutex;
use cmux_threads::sync::MutexGuard;
use std::io;
use std::io::Write;
use std::sync::Arc;

#[cfg(all(test, unix))]
#[path = "inline_write_tests.rs"]
mod tests;

/// The socket descriptor an inline write goes to.
#[cfg(unix)]
type SocketFd = std::os::fd::RawFd;
#[cfg(not(unix))]
type SocketFd = ();

/// The connection's socket for inline writes: its own handle of the socket
/// the writer thread writes, and the largest message it may take.
pub(in crate::server) struct InlineSocket {
    /// Keeps `fd` open; the connection shuts the socket down when it ends.
    _stream: Box<dyn transport::Stream>,
    fd: SocketFd,
    max_bytes: usize,
    ipc: Arc<IpcStats>,
}

impl InlineSocket {
    /// `stream` as an inline socket for messages of at most `chunk_bytes`
    /// (the connection's preemption boundary, so a rest left by a partial
    /// write is never more than one chunk). `None` when `stream` is not a
    /// socket or the platform cannot send to it without waiting.
    pub(in crate::server) fn new(
        stream: Box<dyn transport::Stream>,
        chunk_bytes: usize,
        ipc: Arc<IpcStats>,
    ) -> Option<Self> {
        let fd = platform::socket_fd(stream.as_ref())?;
        let max_bytes = chunk_bytes.min(platform::nonblocking_bound(fd)?);
        Some(Self { _stream: stream, fd, max_bytes, ipc })
    }

    /// One send of `bytes` that never waits for room: the bytes the socket
    /// took, 0 when it had none. The syscall counts in `server-stats`.
    fn send(&self, bytes: &[u8]) -> io::Result<usize> {
        match self.ipc.counted(&mut NonblockingSend(self.fd)).write(bytes) {
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(0),
            result => result,
        }
    }
}

/// The writer side of the queue state: whether the writer thread is writing
/// an item, and the bytes an inline write left for it.
#[derive(Default)]
pub(super) struct WriterState {
    busy: bool,
    rest: Option<Vec<u8>>,
    /// Times the writer thread woke from its idle wait (tests: an inline
    /// write must wake nobody).
    #[cfg(test)]
    wakeups: usize,
}

/// The writer thread's turn (where a connection has a writer thread, and
/// in tests): what it writes (a rest an inline write left,
/// then the batch it took), and while it lives no producer writes inline.
#[cfg(any(test, not(unix)))]
pub(in crate::server) struct WriterTurn<'a> {
    state: &'a Mutex<BoundedOutboundState>,
    /// The tail of a message an inline write began: written as is, before
    /// the batch, and counted when the inline write began it.
    pub(in crate::server) rest: Option<Vec<u8>>,
}

#[cfg(any(test, not(unix)))]
impl Drop for WriterTurn<'_> {
    fn drop(&mut self) {
        self.state.lock().recover_poison().writer.busy = false;
    }
}

impl BoundedOutbound {
    /// A queue whose producers write inline to `inline` when it is idle.
    pub(in crate::server) fn with_inline(chunk_bytes: usize, inline: Option<InlineSocket>) -> Self {
        Self { inline, ..Self::with_chunk_bytes(chunk_bytes) }
    }

    /// Whether a message of `wire_bytes` may be written inline once queued:
    /// an inline socket takes it, nothing is queued or left, and the writer
    /// thread is not writing. Read under the lock, before the push.
    pub(super) fn inline_ready(&self, state: &BoundedOutboundState, wire_bytes: usize) -> bool {
        self.inline.as_ref().is_some_and(|inline| wire_bytes <= inline.max_bytes) && state.is_idle()
    }

    /// Ends a push: when `inline` (`inline_ready` before a push that
    /// queued one item), writes that item on this thread and wakes nobody
    /// unless it left a rest; else wakes the writer. A failed send closes
    /// the queue, so the writer thread ends the connection.
    pub(super) fn finish_push(
        &self,
        mut state: MutexGuard<'_, BoundedOutboundState>,
        inline: bool,
    ) -> io::Result<()> {
        let written = match (&self.inline, inline) {
            (Some(socket), true) => state.write_inline(socket),
            _ => Ok(false),
        };
        // The inline pop freed budget: its room waiters and space hooks wake
        // once the lock is released, as the writer's turn wakes them.
        let woken = state.take_space_woken();
        if written.as_ref().is_ok_and(|&done| done) {
            drop(state);
            woken.wake();
            return Ok(());
        }
        if written.is_err() {
            state.closed = true;
        }
        drop(state);
        // The rest or the queued item is the writer's: the writer thread's
        // condvar, or the mux-io loop's doorbell (server/mux_io.rs).
        self.notify_item();
        woken.wake();
        written.map(|_| ())
    }

    /// The writer thread's next turn: waits for a rest or an item, then
    /// takes the rest and a batch of the ready items behind it into `batch`
    /// (`BoundedOutboundState::take_batch`). `None` once the
    /// queue closed with nothing left. No producer writes inline until the
    /// turn drops. The wait is an idle wait, so a writer that disallows
    /// blocking may take it (p02-threads 308).
    #[cfg(any(test, not(unix)))]
    pub(in crate::server) fn recv_turn(
        &self,
        batch: &mut Vec<OutboundItem>,
    ) -> Option<WriterTurn<'_>> {
        batch.clear();
        let mut state = self.state.lock().recover_poison();
        loop {
            let rest = state.writer.rest.take();
            if state.take_batch(batch) || rest.is_some() {
                state.writer.busy = true;
                let woken = state.take_space_woken();
                drop(state);
                self.changed.notify_all();
                woken.wake();
                return Some(WriterTurn { state: &self.state, rest });
            }
            if state.closed {
                return None;
            }
            // The writer thread waits for its own next item: an idle wait,
            // allowed on a thread that may not block.
            state = self.changed.idle().wait(state).recover_poison();
            #[cfg(test)]
            {
                state.writer.wakeups += 1;
            }
        }
    }

    /// [`Self::recv_turn`] for a writer that never waits (the mux-io loop,
    /// server/mux_io.rs): takes a rest an inline write left into `rest` and
    /// the ready items behind it into `batch`. While the loop holds a turn
    /// (from `Taken` until a later poll finds the queue `Empty`) no producer
    /// writes inline, so nothing passes the bytes the loop still writes.
    #[cfg(unix)]
    pub(in crate::server) fn try_recv_turn(
        &self,
        batch: &mut Vec<OutboundItem>,
        rest: &mut Option<Vec<u8>>,
    ) -> BatchPoll {
        batch.clear();
        let mut state = self.state.lock().recover_poison();
        *rest = state.writer.rest.take();
        if state.take_batch(batch) || rest.is_some() {
            state.writer.busy = true;
            // Producers that got room (a stream's space hook, an ordered
            // terminal's room waker) run once the lock is released.
            let woken = state.take_space_woken();
            drop(state);
            self.changed.notify_all();
            woken.wake();
            return BatchPoll::Taken;
        }
        state.writer.busy = false;
        if state.closed { BatchPoll::Closed } else { BatchPoll::Empty }
    }

    /// Times the writer thread woke from its idle wait in `recv_turn`.
    #[cfg(test)]
    pub(in crate::server) fn writer_wakeups(&self) -> usize {
        self.state.lock().recover_poison().writer.wakeups
    }
}

impl BoundedOutboundState {
    /// Nothing queued anywhere, no rest, and the writer is not writing.
    fn is_idle(&self) -> bool {
        let lanes = self.lanes.ready(!self.control.is_empty());
        !self.closed
            && !self.writer.busy
            && self.writer.rest.is_none()
            && self.initial.is_empty()
            && !(lanes.input || lanes.control || lanes.bulk || lanes.background)
    }

    /// Pops the one queued item and sends it: true when the socket took all
    /// of it; else what it did not take is the writer's next write.
    fn write_inline(&mut self, socket: &InlineSocket) -> io::Result<bool> {
        let Some(item) = self.pop() else { return Ok(true) };
        let mut bytes = Vec::new();
        match item {
            OutboundItem::Text(text) => {
                socket.ipc.line_sent(text.len() + 1);
                bytes.reserve_exact(text.len() + 1);
                bytes.extend_from_slice(text.as_bytes());
                bytes.push(b'\n');
            }
            OutboundItem::Frame(header, text) => {
                socket.ipc.frame_sent(header.kind(), header.frame_len());
                bytes.reserve_exact(header.frame_len());
                bytes.extend_from_slice(&header.encode());
                bytes.extend_from_slice(text.as_bytes());
            }
            OutboundItem::Chunk { header, text, range } => {
                socket.ipc.frame_sent(header.kind(), header.frame_len());
                let payload = text.as_bytes().get(range).ok_or(io::ErrorKind::InvalidData)?;
                bytes.reserve_exact(header.frame_len());
                bytes.extend_from_slice(&header.encode());
                bytes.extend_from_slice(payload);
            }
            OutboundItem::Flush(flushed) => {
                let _ = flushed.send(());
                return Ok(true);
            }
        }
        let sent = socket.send(&bytes)?;
        if sent < bytes.len() {
            self.writer.rest = Some(bytes.split_off(sent));
            return Ok(false);
        }
        Ok(true)
    }

    /// Drops a rest (the connection is being aborted).
    pub(super) fn drop_rest(&mut self) {
        self.writer.rest = None;
    }
}

/// A `Write` whose one call is one nonblocking send on the socket.
struct NonblockingSend(SocketFd);

impl Write for NonblockingSend {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        platform::send(self.0, bytes)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use crate::platform::transport;
    use std::io;
    use std::os::fd::RawFd;

    pub(super) fn socket_fd(stream: &dyn transport::Stream) -> Option<RawFd> {
        stream.socket_fd()
    }

    /// Linux honors `MSG_DONTWAIT` on a Unix stream socket: any size.
    pub(super) fn nonblocking_bound(_fd: RawFd) -> Option<usize> {
        Some(usize::MAX)
    }

    pub(super) fn send(fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
        super::send_retrying(fd, bytes, libc::MSG_DONTWAIT | libc::MSG_NOSIGNAL)
    }
}

#[cfg(target_vendor = "apple")]
mod platform {
    use crate::platform::transport;
    use std::io;
    use std::os::fd::RawFd;

    /// The send low-water mark this path asks for: room for a key's echo,
    /// a reply or one bulk chunk.
    const LOW_WATER: libc::c_int = 64 * 1024;

    pub(super) fn socket_fd(stream: &dyn transport::Stream) -> Option<RawFd> {
        stream.socket_fd()
    }

    /// XNU ignores `MSG_DONTWAIT` on a send, but `sosend` does not wait
    /// when the room `poll` reports (at least the send low-water mark,
    /// `sowriteable`) holds the whole message. The bound is that mark,
    /// raised to `LOW_WATER` where the socket allows.
    pub(super) fn nonblocking_bound(fd: RawFd) -> Option<usize> {
        let size = size_of::<libc::c_int>() as libc::socklen_t;
        let wanted = LOW_WATER;
        // SAFETY: setsockopt reads `size` bytes from `wanted`, live for the call.
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_SNDLOWAT,
                (&raw const wanted).cast(),
                size,
            )
        };
        let mut mark: libc::c_int = 0;
        let mut length = size;
        // SAFETY: getsockopt writes at most `length` bytes into `mark`, live for the call.
        let read = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_SNDLOWAT,
                (&raw mut mark).cast(),
                &raw mut length,
            )
        };
        (read == 0 && mark > 0).then_some(mark as usize)
    }

    pub(super) fn send(fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
        let mut ready = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
        // SAFETY: poll reads and writes the one pollfd it is given; timeout 0 never waits.
        let polled = unsafe { libc::poll(&raw mut ready, 1, 0) };
        if polled < 0 {
            return Err(io::Error::last_os_error());
        }
        if polled == 0 || ready.revents & libc::POLLOUT == 0 {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        super::send_retrying(fd, bytes, libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT)
    }
}

#[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
mod platform {
    use crate::platform::transport;
    use std::io;

    /// No inline path here: every item goes through the writer thread.
    pub(super) fn socket_fd(_stream: &dyn transport::Stream) -> Option<super::SocketFd> {
        None
    }

    pub(super) fn nonblocking_bound(_fd: super::SocketFd) -> Option<usize> {
        None
    }

    pub(super) fn send(_fd: super::SocketFd, _bytes: &[u8]) -> io::Result<usize> {
        Err(io::ErrorKind::Unsupported.into())
    }
}

/// One `send(2)` with `flags`, repeated only when a signal interrupted it.
#[cfg(any(target_os = "linux", target_vendor = "apple"))]
fn send_retrying(fd: SocketFd, bytes: &[u8], flags: libc::c_int) -> io::Result<usize> {
    loop {
        // SAFETY: `bytes` is `bytes.len()` readable bytes for the call.
        let sent = unsafe { libc::send(fd, bytes.as_ptr().cast(), bytes.len(), flags) };
        if sent >= 0 {
            return Ok(sent as usize);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}
