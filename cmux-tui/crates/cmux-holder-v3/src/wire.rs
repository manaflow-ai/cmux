//! The holder's wire: 16-byte frames on one Unix stream socket, file
//! descriptors passed with `SCM_RIGHTS` (terminal-host-model-DESIGN.md
//! section 4).
//!
//! `magic "CMHX" | kind u16 | flags u16 | chan u32 | len u32 | payload`,
//! little endian. `chan` names one terminal; 0 is the link itself. A frame
//! that carries descriptors sends them with its first byte; the receiver
//! queues them in arrival order and the frame kind says how many it takes.

use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

/// Frame magic.
pub const MAGIC: [u8; 4] = *b"CMHX";
/// Header bytes.
pub const HEADER: usize = 16;
/// Largest payload a frame may carry.
pub const MAX_PAYLOAD: usize = 1 << 20;
/// Wire version this build speaks. Version 2 adds [`Kind::Ack`] flow
/// control; a version 1 peer gets none. Version 3 adds
/// [`Kind::Snapshot`] and [`Kind::Detach`]; a daemon sends them only to a
/// holder that speaks it.
pub const VERSION: u16 = 3;
/// Oldest wire version this build still serves.
pub const MIN_VERSION: u16 = 1;
/// Output a holder sends one terminal past the offset its daemon last
/// acknowledged ([`Kind::Ack`], version 2): the daemon queues at most this
/// much per terminal, and a terminal that prints faster than the daemon
/// parses blocks in its PTY, as on a direct PTY.
pub const CREDIT_WINDOW: u64 = 512 * 1024;
/// A daemon acknowledges after it parsed this much since its last
/// [`Kind::Ack`]. Less than [`CREDIT_WINDOW`], so a stalled terminal always
/// gets the acknowledgement that frees it.
pub const ACK_EVERY: u64 = CREDIT_WINDOW / 4;

/// Frame kinds. Values are frozen; a new kind gets a new value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u16)]
pub enum Kind {
    /// d->h: `version u16, token [u8; 32]`.
    Hello = 1,
    /// h->d: `version u16` (the lower of the two peers' versions), `count
    /// u32`, then one [`Kind::Listed`] per terminal.
    Welcome = 2,
    /// d->h: spawn on a new PTY; payload [`crate::SpawnRequest`].
    Spawn = 3,
    /// h->d: `pid i32`, plus one descriptor: the daemon's custody dup of the master.
    Spawned = 4,
    /// d->h: take over a running terminal: `pid i32, base u64, id [u8; 16]`,
    /// then its prologue (a VT replay of its screen at `base`, may be
    /// empty), plus its master.
    Adopt = 5,
    /// d->h: stream output from `offset u64` (a [`Kind::Gap`] first when it
    /// rolled out); with [`FLAG_WITH_PROLOGUE`], the prologue first.
    Attach = 6,
    /// h->d: `offset u64`, then output bytes.
    Data = 7,
    /// h->d: `requested u64, oldest u64`.
    Gap = 8,
    /// d->h: bytes for the PTY.
    Write = 9,
    /// d->h: `cols u16, rows u16, px_w u16, px_h u16`.
    Resize = 10,
    /// d->h: `signal i32` to the terminal's process group.
    Signal = 11,
    /// d->h: hang up and end the terminal; `grace_ms u32` before SIGKILL.
    Close = 12,
    /// h->d: `status_kind u8` (0 exited, 1 signaled, 2 unobserved), `code i32, end u64`.
    Exit = 13,
    /// h->d: one terminal in a [`Kind::Welcome`]: `pid i32, oldest u64, end u64,
    /// exited u8, id [u8; 16]`, plus one descriptor: a dup of its master.
    Listed = 14,
    /// h->d: `request_kind u16, code u16`, then a UTF-8 message. Code
    /// `SUPERSEDED` on channel 0 (request kind [`Kind::Hello`]): another
    /// daemon authenticated and took this link's place.
    Error = 15,
    /// both: `nonce u64`.
    Ping = 16,
    /// both: `nonce u64`.
    Pong = 17,
    /// d->h (version 2): `offset u64`: the daemon parsed every byte before
    /// it, so the holder may send up to `offset + CREDIT_WINDOW`.
    Ack = 18,
    /// d->h (version 3): `base u64`, then a VT replay of the daemon's
    /// parsed screen at output offset `base`. The holder keeps the newest
    /// as the terminal's prologue, so a restarted daemon restores modes,
    /// alternate screen, title and directory even after the ring dropped
    /// the bytes that set them.
    Snapshot = 19,
    /// d->h (version 3): the daemon leaves this terminal on purpose (its
    /// shutdown): the link's end then is no strike against the terminal's
    /// stream (the poison-pill count).
    Detach = 20,
}

impl Kind {
    /// The kind of a wire value, `None` when this build does not know it.
    pub fn from_u16(value: u16) -> Option<Self> {
        use Kind::*;
        Some(match value {
            1 => Hello,
            2 => Welcome,
            3 => Spawn,
            4 => Spawned,
            5 => Adopt,
            6 => Attach,
            7 => Data,
            8 => Gap,
            9 => Write,
            10 => Resize,
            11 => Signal,
            12 => Close,
            13 => Exit,
            14 => Listed,
            15 => Error,
            16 => Ping,
            17 => Pong,
            18 => Ack,
            19 => Snapshot,
            20 => Detach,
            _ => return None,
        })
    }

    /// Descriptors a frame of this kind carries.
    pub fn descriptors(self) -> usize {
        matches!(self, Kind::Spawned | Kind::Adopt | Kind::Listed) as usize
    }
}

/// One decoded frame and the descriptors it carried.
#[derive(Debug)]
pub struct Frame {
    pub kind: u16,
    pub flags: u16,
    pub chan: u32,
    pub payload: Vec<u8>,
    pub fds: Vec<OwnedFd>,
}

/// [`Kind::Attach`] flag: send the terminal's prologue first.
pub const FLAG_WITH_PROLOGUE: u16 = 1;
/// [`Kind::Data`] flag: these bytes are the prologue (a VT replay of the
/// screen when this holder adopted the terminal), not ring output.
pub const FLAG_PROLOGUE: u16 = 1;

/// Encode a frame header and payload.
pub fn encode(kind: Kind, chan: u32, payload: &[u8]) -> Vec<u8> {
    encode_flagged(kind, 0, chan, payload)
}

/// [`encode`] with header flags.
pub fn encode_flagged(kind: Kind, flags: u16, chan: u32, payload: &[u8]) -> Vec<u8> {
    encode_parts(kind, flags, chan, &[payload])
}

/// A frame whose payload is `parts` in order: one allocation and one copy
/// of each part (a DATA frame straight from the two halves of a ring).
pub fn encode_parts(kind: Kind, flags: u16, chan: u32, parts: &[&[u8]]) -> Vec<u8> {
    let len: usize = parts.iter().map(|part| part.len()).sum();
    let mut out = Vec::with_capacity(HEADER + len);
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&(kind as u16).to_le_bytes());
    out.extend_from_slice(&flags.to_le_bytes());
    out.extend_from_slice(&chan.to_le_bytes());
    out.extend_from_slice(&(len as u32).to_le_bytes());
    for part in parts {
        out.extend_from_slice(part);
    }
    out
}

/// Kernel buffer each end of a link asks for, each way. macOS gives a Unix
/// stream socket 8 KiB (`net.local.stream.sendspace` and `recvspace`), so
/// a 256 KiB DATA frame took 32 `sendmsg`/`recvmsg` pairs and 32 holder
/// turns. More would only queue more bulk output in the kernel ahead of a
/// small frame (an echo): 512 KiB each way drains in well under 1 ms.
pub const LINK_SOCKET_BUFFER: libc::c_int = 512 * 1024;

/// Size a link socket's kernel buffers ([`LINK_SOCKET_BUFFER`]) and, on
/// macOS, turn SIGPIPE into an EPIPE error for writes to a peer that is
/// gone. Best effort: a socket that refuses keeps its defaults.
pub fn tune_socket(fd: RawFd) {
    let size = LINK_SOCKET_BUFFER;
    for option in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
        // SAFETY: setsockopt reads one c_int from a live local.
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                option,
                (&raw const size).cast(),
                size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
    }
    #[cfg(target_vendor = "apple")]
    {
        let on: libc::c_int = 1;
        // SAFETY: setsockopt reads one c_int from a live local.
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_NOSIGPIPE,
                (&raw const on).cast(),
                size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
    }
}

/// Bytes one `recvmsg` may read into a [`Reader`].
const READ_CHUNK: usize = 256 * 1024;
/// Descriptors one `recvmsg` may carry (Linux `SCM_MAX_FD`): a WELCOME
/// passes one per terminal.
const MAX_RECV_FDS: usize = 253;

/// Bytes read from a socket, with the descriptors that arrived alongside,
/// split into frames. Frames are taken from a read cursor; the buffer is
/// compacted once per [`Self::fill`], not once per frame, and the receive
/// buffers are allocated once.
#[derive(Default)]
pub struct Reader {
    buf: Vec<u8>,
    /// Offset in `buf` of the first byte no frame took yet.
    start: usize,
    fds: VecDeque<OwnedFd>,
    /// The `recvmsg` control buffer, allocated on the first fill.
    control: Vec<u8>,
}

impl Reader {
    /// Read what the socket has (one `recvmsg`). `Ok(false)` at end of stream.
    pub fn fill(&mut self, fd: RawFd) -> io::Result<bool> {
        if self.start > 0 {
            self.buf.drain(..self.start);
            self.start = 0;
        }
        if self.control.is_empty() {
            self.control = vec![0u8; control_space()];
        }
        self.buf.reserve(READ_CHUNK);
        let len = self.buf.len();
        let room = (self.buf.capacity() - len).min(READ_CHUNK);
        // SAFETY: `reserve` made `room` bytes of capacity past `len`, so
        // the pointer stays inside the allocation; recvmsg writes at most
        // that many, and `set_len` below covers only what it wrote.
        let tail = unsafe { self.buf.as_mut_ptr().add(len) };
        // SAFETY: `tail` is valid for writes of `room` bytes (above).
        let (n, fds) = unsafe { recv_with_fds(fd, tail, room, &mut self.control)? };
        // SAFETY: recvmsg initialized `n` bytes past `len`.
        unsafe { self.buf.set_len(len + n) };
        self.fds.extend(fds);
        Ok(n != 0)
    }

    /// The next complete frame, if one is buffered. A bad magic or an
    /// oversized length is an error: the stream is lost.
    pub fn next_frame(&mut self) -> io::Result<Option<Frame>> {
        let pending = &self.buf[self.start..];
        if pending.len() < HEADER {
            return Ok(None);
        }
        if pending[..4] != MAGIC {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "bad holder frame magic"));
        }
        let kind = u16::from_le_bytes([pending[4], pending[5]]);
        let flags = u16::from_le_bytes([pending[6], pending[7]]);
        let chan = u32::from_le_bytes(pending[8..12].try_into().unwrap_or_default());
        let len = u32::from_le_bytes(pending[12..16].try_into().unwrap_or_default()) as usize;
        if len > MAX_PAYLOAD {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "holder frame too large"));
        }
        if pending.len() < HEADER + len {
            return Ok(None);
        }
        let payload = pending[HEADER..HEADER + len].to_vec();
        self.start += HEADER + len;
        if self.start == self.buf.len() {
            // Everything was taken: the next fill needs no compaction.
            self.buf.clear();
            self.start = 0;
        }
        let wanted = Kind::from_u16(kind).map_or(0, Kind::descriptors);
        let fds = (0..wanted).filter_map(|_| self.fds.pop_front()).collect();
        Ok(Some(Frame { kind, flags, chan, payload, fds }))
    }
}

/// Bytes of a control buffer for [`MAX_RECV_FDS`] descriptors.
fn control_space() -> usize {
    // SAFETY: CMSG_SPACE computes a size from a length.
    unsafe { libc::CMSG_SPACE((MAX_RECV_FDS * size_of::<RawFd>()) as u32) as usize }
}

/// Write all of `bytes`, passing `fds` with the first byte. Blocking.
pub fn send_all(fd: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<()> {
    let mut sent = send_with_fds(fd, bytes, fds)?;
    while sent < bytes.len() {
        sent += send_with_fds(fd, &bytes[sent..], &[])?;
    }
    Ok(())
}

/// One `sendmsg` of `bytes` with `fds` as `SCM_RIGHTS`. Returns bytes sent.
pub fn send_with_fds(fd: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<usize> {
    let mut iov =
        libc::iovec { iov_base: bytes.as_ptr() as *mut libc::c_void, iov_len: bytes.len() };
    let space = if fds.is_empty() {
        0
    } else {
        // SAFETY: CMSG_SPACE computes a size from a length.
        unsafe { libc::CMSG_SPACE(size_of_val(fds) as u32) as usize }
    };
    let mut control = vec![0u8; space];
    // SAFETY: zeroed msghdr is a valid empty header.
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    if !fds.is_empty() {
        msg.msg_control = control.as_mut_ptr().cast();
        msg.msg_controllen = space as _;
        // SAFETY: the control buffer holds one cmsg of CMSG_SPACE(fds) bytes.
        unsafe {
            let cmsg = libc::CMSG_FIRSTHDR(&msg);
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = libc::SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN(size_of_val(fds) as u32) as _;
            std::ptr::copy_nonoverlapping(
                fds.as_ptr(),
                libc::CMSG_DATA(cmsg).cast::<RawFd>(),
                fds.len(),
            );
        }
    }
    loop {
        // SAFETY: msg points at live buffers for the call.
        let n = unsafe { libc::sendmsg(fd, &msg, send_flags()) };
        if n >= 0 {
            return Ok(n as usize);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(target_os = "linux")]
fn send_flags() -> libc::c_int {
    libc::MSG_NOSIGNAL
}

#[cfg(not(target_os = "linux"))]
fn send_flags() -> libc::c_int {
    0
}

/// One `recvmsg` of at most `len` bytes into `buf`, with `control` as the
/// control buffer; descriptors that arrive are returned owned
/// (close-on-exec).
///
/// # Safety
///
/// `buf` must be valid for writes of `len` bytes.
unsafe fn recv_with_fds(
    fd: RawFd,
    buf: *mut u8,
    len: usize,
    control: &mut [u8],
) -> io::Result<(usize, Vec<OwnedFd>)> {
    let mut iov = libc::iovec { iov_base: buf.cast(), iov_len: len };
    // SAFETY: zeroed msghdr is a valid empty header.
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = control.len() as _;
    let n = loop {
        // SAFETY: msg points at live buffers for the call (the caller
        // vouches for `buf`).
        let n = unsafe { libc::recvmsg(fd, &mut msg, 0) };
        if n >= 0 {
            break n as usize;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    };
    let mut fds = Vec::new();
    // SAFETY: walking the control buffer recvmsg filled, within msg_controllen.
    unsafe {
        let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
        while !cmsg.is_null() {
            if (*cmsg).cmsg_level == libc::SOL_SOCKET && (*cmsg).cmsg_type == libc::SCM_RIGHTS {
                let data = libc::CMSG_DATA(cmsg).cast::<RawFd>();
                let header = libc::CMSG_LEN(0) as usize;
                let count = ((*cmsg).cmsg_len as usize - header) / size_of::<RawFd>();
                for index in 0..count {
                    let raw = std::ptr::read_unaligned(data.add(index));
                    libc::fcntl(raw, libc::F_SETFD, libc::FD_CLOEXEC);
                    fds.push(OwnedFd::from_raw_fd(raw));
                }
            }
            cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
        }
    }
    Ok((n, fds))
}

/// Little-endian payload builder.
#[derive(Default)]
pub struct Out(pub Vec<u8>);

impl Out {
    pub fn u8(mut self, v: u8) -> Self {
        self.0.push(v);
        self
    }
    pub fn u16(mut self, v: u16) -> Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn u32(mut self, v: u32) -> Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn i32(mut self, v: i32) -> Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn u64(mut self, v: u64) -> Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn bytes(mut self, v: &[u8]) -> Self {
        self.0.extend_from_slice(v);
        self
    }
    /// `u32 len` + bytes.
    pub fn string(self, v: &[u8]) -> Self {
        self.u32(v.len() as u32).bytes(v)
    }
}

/// Little-endian payload reader; every read fails on a short payload.
pub struct In<'a>(pub &'a [u8]);

impl<'a> In<'a> {
    fn take(&mut self, n: usize) -> io::Result<&'a [u8]> {
        if self.0.len() < n {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "short holder payload"));
        }
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Ok(head)
    }
    pub fn u8(&mut self) -> io::Result<u8> {
        Ok(self.take(1)?[0])
    }
    pub fn u16(&mut self) -> io::Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap_or_default()))
    }
    pub fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap_or_default()))
    }
    pub fn i32(&mut self) -> io::Result<i32> {
        Ok(i32::from_le_bytes(self.take(4)?.try_into().unwrap_or_default()))
    }
    pub fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap_or_default()))
    }
    pub fn array<const N: usize>(&mut self) -> io::Result<[u8; N]> {
        Ok(self.take(N)?.try_into().unwrap_or([0; N]))
    }
    pub fn string(&mut self) -> io::Result<&'a [u8]> {
        let len = self.u32()? as usize;
        self.take(len)
    }
    pub fn rest(self) -> &'a [u8] {
        self.0
    }
}

/// The raw descriptor of an owned one, for a `send_all` that passes it.
pub fn raw(fd: &OwnedFd) -> RawFd {
    fd.as_raw_fd()
}
