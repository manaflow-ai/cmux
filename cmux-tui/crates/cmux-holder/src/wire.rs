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
/// Wire version this build speaks.
pub const VERSION: u16 = 1;

/// Frame kinds. Values are frozen; a new kind gets a new value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u16)]
pub enum Kind {
    /// d->h: `version u16, token [u8; 32]`.
    Hello = 1,
    /// h->d: `version u16, count u32`, then one [`Kind::Listed`] per terminal.
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
    /// h->d: `request_kind u16, code u16`, then a UTF-8 message.
    Error = 15,
    /// both: `nonce u64`.
    Ping = 16,
    /// both: `nonce u64`.
    Pong = 17,
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
    let mut out = Vec::with_capacity(HEADER + payload.len());
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&(kind as u16).to_le_bytes());
    out.extend_from_slice(&flags.to_le_bytes());
    out.extend_from_slice(&chan.to_le_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    out
}

/// Bytes read from a socket, with the descriptors that arrived alongside,
/// split into frames.
#[derive(Default)]
pub struct Reader {
    buf: Vec<u8>,
    fds: VecDeque<OwnedFd>,
}

impl Reader {
    /// Read what the socket has (one `recvmsg`). `Ok(false)` at end of stream.
    pub fn fill(&mut self, fd: RawFd) -> io::Result<bool> {
        let mut chunk = [0u8; 64 * 1024];
        let (n, fds) = recv_with_fds(fd, &mut chunk)?;
        self.fds.extend(fds);
        if n == 0 {
            return Ok(false);
        }
        self.buf.extend_from_slice(&chunk[..n]);
        Ok(true)
    }

    /// The next complete frame, if one is buffered. A bad magic or an
    /// oversized length is an error: the stream is lost.
    pub fn next_frame(&mut self) -> io::Result<Option<Frame>> {
        if self.buf.len() < HEADER {
            return Ok(None);
        }
        if self.buf[..4] != MAGIC {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "bad holder frame magic"));
        }
        let kind = u16::from_le_bytes([self.buf[4], self.buf[5]]);
        let flags = u16::from_le_bytes([self.buf[6], self.buf[7]]);
        let chan = u32::from_le_bytes(self.buf[8..12].try_into().unwrap_or_default());
        let len = u32::from_le_bytes(self.buf[12..16].try_into().unwrap_or_default()) as usize;
        if len > MAX_PAYLOAD {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "holder frame too large"));
        }
        if self.buf.len() < HEADER + len {
            return Ok(None);
        }
        let payload = self.buf[HEADER..HEADER + len].to_vec();
        self.buf.drain(..HEADER + len);
        let wanted = Kind::from_u16(kind).map_or(0, Kind::descriptors);
        let fds = (0..wanted).filter_map(|_| self.fds.pop_front()).collect();
        Ok(Some(Frame { kind, flags, chan, payload, fds }))
    }
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

/// One `recvmsg`; descriptors that arrive are returned owned (close-on-exec).
fn recv_with_fds(fd: RawFd, buf: &mut [u8]) -> io::Result<(usize, Vec<OwnedFd>)> {
    let mut iov = libc::iovec { iov_base: buf.as_mut_ptr().cast(), iov_len: buf.len() };
    // Room for 253 descriptors per read (Linux SCM_MAX_FD): a WELCOME passes one per terminal.
    // SAFETY: CMSG_SPACE computes a size from a length.
    let space = unsafe { libc::CMSG_SPACE((253 * size_of::<RawFd>()) as u32) as usize };
    let mut control = vec![0u8; space];
    // SAFETY: zeroed msghdr is a valid empty header.
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = space as _;
    let n = loop {
        // SAFETY: msg points at live buffers for the call.
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
