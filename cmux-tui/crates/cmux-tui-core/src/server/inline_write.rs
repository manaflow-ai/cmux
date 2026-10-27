//! The inline write fast path of one connection's outbound queue
//! (plans/cmux-next/chrome-parity/p05-ipc.md, task 140).
//!
//! A producer whose item would be the next one written anyway, on a writer
//! that is idle, writes it itself without waiting: one nonblocking `sendmsg`
//! under the queue's lock, no hand-off to `mux-line-out` and no wakeup of it.
//! The socket takes all of it (an idle connection), or a prefix: the rest
//! stays for the writer thread, which writes it before anything else. This is
//! Mojo's `ChannelPosix::Write` (chromium mojo/core/channel_posix.cc): it
//! calls `WriteNoLock` on the caller's thread when `outgoing_messages_` is
//! empty and queues the unwritten rest for the IO thread on EAGAIN.
//!
//! A nonblocking write needs a nonblocking socket: macOS ignores
//! `MSG_DONTWAIT` on Unix stream sockets, and a descriptor's file status
//! flags are shared by every clone of it. The connection's socket is put in
//! nonblocking mode, as Mojo's channel sets it (`base::SetNonBlocking`), and
//! its reader and writer thread wait for readiness with `poll` where a
//! blocking call waited inside the kernel ([`wait_readable`],
//! [`WaitingWrite`]).

use super::BoundedOutboundState;
use super::OutboundItem;
use crate::diagnostics::IpcStats;
use crate::platform::transport;
use std::io::{self, IoSlice, Write};
use std::sync::Arc;

/// Writes an item's bytes on the caller's thread without waiting.
pub(in crate::server) trait InlineWrite: Send + Sync {
    /// Writes a prefix of `item`'s wire bytes without waiting: the bytes
    /// written, 0 when the socket has no room. An item it wrote any of is
    /// counted as sent.
    fn write_now(&self, item: &OutboundItem) -> io::Result<usize>;
}

/// An item that left the queue for the writer thread, and how many of its
/// wire bytes an inline write already sent.
pub(in crate::server) struct Pending {
    pub(in crate::server) item: OutboundItem,
    pub(in crate::server) written: usize,
}

/// The inline path's part of the queue state.
#[derive(Default)]
pub(in crate::server) struct InlinePath {
    /// The connection's socket, while the connection is open.
    pub(in crate::server) writer: Option<Box<dyn InlineWrite>>,
    /// The writer thread is writing an item it took: no inline write may
    /// start until it asks for the next one.
    pub(in crate::server) writer_busy: bool,
    /// What an inline write left unsent; the writer thread writes it first.
    pub(in crate::server) rest: Option<Pending>,
}

impl BoundedOutboundState {
    /// Whether an item queued now would be the only one, with nobody
    /// writing: its producer may write it (task 140). Every queue empty is
    /// stricter than every equal-or-higher one; a lower item queued means the
    /// writer thread is awake for it, so there is no wakeup to save.
    pub(in crate::server) fn inline_idle(&self) -> bool {
        self.inline.writer.is_some()
            && !self.inline.writer_busy
            && self.inline.rest.is_none()
            && !self.closed
            && !self.has_queued()
    }

    /// Whether anything waits for the writer thread: a queued item or the
    /// rest of one (tests).
    #[cfg(test)]
    pub(in crate::server) fn left_for_writer(&self) -> bool {
        self.inline.rest.is_some() || self.has_queued()
    }

    fn has_queued(&self) -> bool {
        let ready = self.lanes.ready(!self.control.is_empty());
        !self.initial.is_empty() || ready.input || ready.control || ready.bulk || ready.background
    }

    /// After an item was queued: when the queue was idle before it
    /// (`was_idle`), writes it now. True when the writer thread has work:
    /// the queue was busy, the socket took only part of the item, or a
    /// frame's later chunks wait. A failed write closes the queue.
    pub(in crate::server) fn send_now(&mut self, was_idle: bool) -> io::Result<bool> {
        if !was_idle {
            return Ok(true);
        }
        let Some(item) = self.pop() else { return Ok(self.has_queued()) };
        let Some(writer) = self.inline.writer.as_ref() else {
            self.inline.rest = Some(Pending { item, written: 0 });
            return Ok(true);
        };
        let total = item.wire_parts()?.map_or(0, |parts| parts.len());
        let written = match writer.write_now(&item) {
            Ok(written) => written,
            Err(error) => {
                self.closed = true;
                self.inline.writer = None;
                return Err(error);
            }
        };
        if total == 0 || written < total {
            self.inline.rest = Some(Pending { item, written });
            return Ok(true);
        }
        Ok(self.has_queued())
    }
}

/// The wire bytes of one item: a frame's header, the payload (a line's
/// text), and a line's delimiter.
pub(in crate::server) struct WireParts<'a> {
    header: Option<[u8; cmux_ipc::HEADER_LEN]>,
    payload: &'a [u8],
    delimiter: &'static [u8],
}

impl WireParts<'_> {
    pub(in crate::server) fn len(&self) -> usize {
        self.header.map_or(0, |header| header.len()) + self.payload.len() + self.delimiter.len()
    }

    /// The parts in wire order, the empty ones too.
    pub(in crate::server) fn slices(&self) -> [&[u8]; 3] {
        [self.header.as_ref().map_or(&[][..], |header| &header[..]), self.payload, self.delimiter]
    }
}

impl OutboundItem {
    /// The item's bytes on the wire; `None` for a flush, which writes none.
    pub(in crate::server) fn wire_parts(&self) -> io::Result<Option<WireParts<'_>>> {
        Ok(Some(match self {
            OutboundItem::Text(text) => {
                WireParts { header: None, payload: text.as_bytes(), delimiter: b"\n" }
            }
            OutboundItem::Frame(header, text) => WireParts {
                header: Some(header.encode()),
                payload: text.as_bytes(),
                delimiter: b"",
            },
            OutboundItem::Chunk { header, text, range } => WireParts {
                header: Some(header.encode()),
                payload: text.as_bytes().get(range.clone()).ok_or(io::ErrorKind::InvalidData)?,
                delimiter: b"",
            },
            OutboundItem::Flush(_) => return Ok(None),
        }))
    }

    /// Counts the item as sent in `ipc` (`server-stats` `ipc`), once,
    /// whichever thread writes its first byte.
    pub(in crate::server) fn count_sent(&self, ipc: &IpcStats) {
        match self {
            OutboundItem::Text(text) => ipc.line_sent(text.len() + 1),
            OutboundItem::Frame(header, _) | OutboundItem::Chunk { header, .. } => {
                ipc.frame_sent(header.kind(), header.frame_len());
            }
            OutboundItem::Flush(_) => {}
        }
    }
}

/// Writes what `pending` has not sent yet to `writer`, waiting as `writer`
/// does; a flush flushes `writer` and reports it done.
pub(in crate::server) fn write_pending<W: Write + ?Sized>(
    writer: &mut W,
    pending: Pending,
) -> io::Result<()> {
    let Pending { item, written } = pending;
    let Some(parts) = item.wire_parts()? else {
        writer.flush()?;
        if let OutboundItem::Flush(flushed) = item {
            let _ = flushed.send(());
        }
        return Ok(());
    };
    let mut skip = written;
    for part in parts.slices() {
        let start = skip.min(part.len());
        skip -= start;
        let rest = part.get(start..).unwrap_or_default();
        if !rest.is_empty() {
            writer.write_all(rest)?;
        }
    }
    Ok(())
}

/// The inline writer of a connected local socket: a clone of the
/// connection's socket in nonblocking mode, counted in `ipc` as the writer
/// thread's writes are. `None` for a stream that is not one socket (a test
/// double, a stream that replays a prefix) or on a platform without one.
#[cfg(unix)]
pub(in crate::server) fn socket_inline_writer(
    stream: &dyn transport::Stream,
    ipc: &Arc<IpcStats>,
) -> Option<Box<dyn InlineWrite>> {
    let socket = stream.try_clone_box().ok()?;
    let fd = socket.socket_fd()?;
    set_nonblocking(fd).ok()?;
    Some(Box::new(SocketInlineWriter { fd, _socket: socket, ipc: ipc.clone() }))
}

#[cfg(not(unix))]
pub(in crate::server) fn socket_inline_writer(
    _stream: &dyn transport::Stream,
    _ipc: &Arc<IpcStats>,
) -> Option<Box<dyn InlineWrite>> {
    None
}

#[cfg(unix)]
struct SocketInlineWriter {
    fd: std::os::fd::RawFd,
    /// Owns `fd`: the descriptor stays this socket for as long as the
    /// writer lives, even after the connection dropped its own clones.
    _socket: Box<dyn transport::Stream>,
    ipc: Arc<IpcStats>,
}

#[cfg(unix)]
impl InlineWrite for SocketInlineWriter {
    fn write_now(&self, item: &OutboundItem) -> io::Result<usize> {
        let Some(parts) = item.wire_parts()? else { return Ok(0) };
        let slices = parts.slices().map(IoSlice::new);
        let written = match self.ipc.counted(&mut NonblockingSend(self.fd)).write_vectored(&slices)
        {
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => 0,
            result => result?,
        };
        if written > 0 {
            item.count_sent(&self.ipc);
        }
        Ok(written)
    }
}

/// One `sendmsg` of the given slices on a nonblocking socket.
#[cfg(unix)]
struct NonblockingSend(std::os::fd::RawFd);

#[cfg(unix)]
impl Write for NonblockingSend {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.write_vectored(&[IoSlice::new(buf)])
    }

    fn write_vectored(&mut self, bufs: &[IoSlice<'_>]) -> io::Result<usize> {
        let mut iov: Vec<libc::iovec> = bufs
            .iter()
            .filter(|buf| !buf.is_empty())
            .map(|buf| libc::iovec {
                iov_base: buf.as_ptr() as *mut libc::c_void,
                iov_len: buf.len(),
            })
            .collect();
        if iov.is_empty() {
            return Ok(0);
        }
        // SAFETY: a zeroed msghdr is a valid empty header.
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = iov.as_mut_ptr();
        msg.msg_iovlen = iov.len() as _;
        loop {
            // SAFETY: `msg` points at `iov`, whose slices `bufs` lends for
            // the call; the socket is nonblocking, so the call never waits.
            let sent = unsafe { libc::sendmsg(self.0, &msg, SEND_FLAGS) };
            if sent >= 0 {
                return Ok(sent as usize);
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// `sendmsg` flags: a write to a gone peer is EPIPE, not SIGPIPE (cmux-ipc
/// fds.rs; macOS has no `MSG_NOSIGNAL`, and the daemon ignores SIGPIPE).
#[cfg(target_os = "linux")]
const SEND_FLAGS: libc::c_int = libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT;
#[cfg(all(unix, not(target_os = "linux")))]
const SEND_FLAGS: libc::c_int = 0;

#[cfg(unix)]
fn set_nonblocking(fd: std::os::fd::RawFd) -> io::Result<()> {
    // SAFETY: F_GETFL and F_SETFL read and set the flags of an open descriptor.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    // SAFETY: as above.
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Waits until `fd` has bytes to read or reached its end: the wait a
/// blocking read did in the kernel, for a socket an inline writer made
/// nonblocking.
#[cfg(unix)]
pub(in crate::server) fn wait_readable(fd: std::os::fd::RawFd) -> io::Result<()> {
    poll_until(fd, libc::POLLIN, None)
}

/// Waits until `fd` takes more bytes, at most `timeout` (None: no limit).
#[cfg(unix)]
fn wait_writable(fd: std::os::fd::RawFd, timeout: Option<std::time::Duration>) -> io::Result<()> {
    poll_until(fd, libc::POLLOUT, timeout)
}

#[cfg(unix)]
fn poll_until(
    fd: std::os::fd::RawFd,
    events: libc::c_short,
    timeout: Option<std::time::Duration>,
) -> io::Result<()> {
    let deadline = timeout.map(|timeout| std::time::Instant::now() + timeout);
    loop {
        let wait_ms = match deadline {
            None => -1,
            Some(deadline) => {
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                if left.is_zero() {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "the peer stopped reading",
                    ));
                }
                libc::c_int::try_from(left.as_millis().saturating_add(1))
                    .unwrap_or(libc::c_int::MAX)
            }
        };
        let mut pollfd = libc::pollfd { fd, events, revents: 0 };
        // wakeup-allow: deadline the socket's own write timeout, or none: the wait of the blocking call it replaces
        // SAFETY: poll reads and writes the one pollfd it is given, a local live for the call.
        let ready = unsafe { libc::poll(&mut pollfd, 1, wait_ms) };
        if ready > 0 {
            // Readiness, a hang-up or an error: the next read or write reports which.
            return Ok(());
        }
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

/// The socket's send timeout (`SO_SNDTIMEO`, which `set_write_timeout`
/// sets); `None` when it has none.
#[cfg(unix)]
fn send_timeout(fd: std::os::fd::RawFd) -> io::Result<Option<std::time::Duration>> {
    let mut value = libc::timeval { tv_sec: 0, tv_usec: 0 };
    let mut len = size_of::<libc::timeval>() as libc::socklen_t;
    // SAFETY: getsockopt writes at most `len` bytes into `value`, a local
    // live for the call.
    let status = unsafe {
        libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_SNDTIMEO, (&raw mut value).cast(), &mut len)
    };
    if status < 0 {
        return Err(io::Error::last_os_error());
    }
    let timeout = std::time::Duration::new(
        u64::try_from(value.tv_sec).unwrap_or_default(),
        u32::try_from(value.tv_usec).unwrap_or_default().saturating_mul(1_000),
    );
    Ok((!timeout.is_zero()).then_some(timeout))
}

/// The writer thread's writes to its socket: a write the socket has no room
/// for waits until it has, up to the socket's send timeout, as a blocking
/// write did; a socket in blocking mode is written as it is.
pub(in crate::server) struct WaitingWrite<'a> {
    stream: &'a mut dyn transport::Stream,
}

impl<'a> WaitingWrite<'a> {
    pub(in crate::server) fn new(stream: &'a mut dyn transport::Stream) -> Self {
        Self { stream }
    }

    #[cfg(unix)]
    fn wait_for_room(&self) -> io::Result<()> {
        let Some(fd) = self.stream.socket_fd() else {
            return Err(io::ErrorKind::WouldBlock.into());
        };
        wait_writable(fd, send_timeout(fd)?)
    }

    #[cfg(not(unix))]
    fn wait_for_room(&self) -> io::Result<()> {
        Err(io::ErrorKind::WouldBlock.into())
    }
}

impl Write for WaitingWrite<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        loop {
            match self.stream.write(buf) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => self.wait_for_room()?,
                result => return result,
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}
