//! The holder's wire: 16-byte frames on one Unix stream socket, file
//! descriptors passed with `SCM_RIGHTS` (terminal-host-model-DESIGN.md
//! section 4).
//!
//! `magic "CMHX" | kind u16 | flags u16 | chan u32 | len u32 | payload`,
//! little endian. `chan` names one terminal; 0 is the link itself. A frame
//! that carries descriptors sends them with its first byte, and its header
//! states how many ([`FLAG_FDS_STATED`]): the receiver gives each frame
//! exactly the descriptors that arrived with its first byte, and a frame
//! whose descriptors are missing, or that passed more than it states, ends
//! the link. A frame from an older build states nothing; its kind and flags
//! say how many it passes.

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
/// holder that speaks it. Version 4 adds the shared output ring
/// ([`FLAG_RING`], `crate::ring`): [`Kind::Spawned`], [`Kind::Listed`] and
/// [`Kind::Adopt`] may carry the ring's segment as a second descriptor, so a
/// holder crash loses no byte the holder read. Version 5 adds ring layout 2
/// (`crate::ring`), [`Kind::Adopted`] and the acknowledged offset in
/// [`Kind::Attach`]: a holder passes ring segments only on a link of version
/// 5 or later, and a daemon hands them only to such a holder, so a layout 2
/// segment never reaches a holder that knows only layout 1, and the daemon
/// always knows which segment a holder writes.
pub const VERSION: u16 = 5;
/// The first wire version on which ring segments pass between the peers
/// ([`FLAG_RING`], ring layout 2, [`Kind::Adopted`]). A version 4 holder
/// passes layout 1 segments; a daemon of this build keeps them and hands
/// them on, but never hands one to a version 4 holder.
pub const RING_VERSION: u16 = 5;
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
    /// empty), plus its master. With [`FLAG_RING`] (version 4) `resume
    /// u64` comes before the prologue and the ring's segment is a second
    /// descriptor: the holder continues that ring (its offsets and the bytes
    /// a dead holder read), `base` is the offset the daemon parsed and
    /// confirmed (where the prologue's screen is), and `resume` is where its
    /// stream continues (a fresh ring starts there if the segment is bad or
    /// ends before `resume`). A holder of version 5 answers every ADOPT
    /// with [`Kind::Adopted`], naming the ring it writes.
    Adopt = 5,
    /// d->h: stream output from `offset u64` (a [`Kind::Gap`] first when it
    /// rolled out); with [`FLAG_WITH_PROLOGUE`], the prologue first. Version
    /// 5: an optional `acked u64` follows, the offset the daemon parsed
    /// (at or before `offset`): the credit counts from there, so output the
    /// daemon received but has not parsed yet is part of the window. An
    /// older holder reads only `offset` and ignores it.
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
    /// daemon authenticated and took this link's place. Request kind 0
    /// ([`STREAM_FAULT`]) on channel 0: the holder could not read the
    /// daemon's stream on ([`Fault`]; code `NO_DESCRIPTORS` or
    /// `BAD_PAYLOAD`), and the link ends after it.
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
    /// h->d (version 5): the answer to every [`Kind::Adopt`] on the
    /// channel: `oldest u64, end u64` of the ring the holder writes the
    /// terminal's output to from now on. With [`FLAG_RING`] that ring's
    /// segment is the one descriptor: the segment the ADOPT carried when the
    /// holder continues it, a fresh one when it could not (a bad or stale
    /// segment). Without the flag the ring is private. The daemon keeps
    /// exactly this segment as its custody copy, so it never hands a later
    /// holder a segment nobody writes.
    Adopted = 21,
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
            21 => Adopted,
            _ => return None,
        })
    }

    /// Descriptors a frame of this kind carries without [`FLAG_RING`].
    pub fn descriptors(self) -> usize {
        matches!(self, Kind::Spawned | Kind::Adopt | Kind::Listed) as usize
    }

    /// Descriptors a frame of this kind with these header flags carries:
    /// one more with [`FLAG_RING`] (the ring's segment, after the master;
    /// an [`Kind::Adopted`] carries only the segment).
    /// What a frame without [`FLAG_FDS_STATED`] (an older build's) passes;
    /// a sender of this build passes exactly this many too.
    pub fn descriptors_with(self, flags: u16) -> usize {
        let ring = flags & FLAG_RING != 0;
        if self == Kind::Adopted {
            return ring as usize;
        }
        let base = self.descriptors();
        base + (base > 0 && ring) as usize
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

/// The request kind of an ERROR about the daemon's stream itself rather
/// than one of its frames ([`Kind::Error`]): no kind has this value.
pub const STREAM_FAULT: u16 = 0;

/// [`Kind::Attach`] flag: send the terminal's prologue first.
pub const FLAG_WITH_PROLOGUE: u16 = 1;
/// [`Kind::Data`] flag: these bytes are the prologue (a VT replay of the
/// screen when this holder adopted the terminal), not ring output.
pub const FLAG_PROLOGUE: u16 = 1;
/// [`Kind::Spawned`], [`Kind::Listed`] and [`Kind::Adopt`] flag (version
/// 4): the frame carries the terminal's ring segment as a second descriptor,
/// after the master ([`Kind::Adopted`]: as its only one). This build sends
/// it only on a link of at least [`RING_VERSION`], so an older peer never
/// gets a descriptor it does not expect or a ring layout it cannot read.
pub const FLAG_RING: u16 = 2;
/// Header flag of every frame this build sends, of any kind: the three bits
/// above it are the number of descriptors the frame passes.
/// A receiver of an older build ignores it (it counts by kind, and this
/// build passes what the kind says); a receiver of this build takes exactly
/// that many, so a frame that passes no descriptor where its kind would
/// (never from this build's holder, which passes its own descriptors and
/// makes none) never takes the next frame's.
pub const FLAG_FDS_STATED: u16 = 1 << 12;
/// The shift of the descriptor count in a header's flags.
const FDS_SHIFT: u32 = 13;
/// The header bits a descriptor count takes (with [`FLAG_FDS_STATED`]).
const FDS_FIELD: u16 = 0b111 << FDS_SHIFT;
/// The most descriptors one frame may pass: what its header can state.
pub const MAX_FRAME_FDS: usize = (FDS_FIELD >> FDS_SHIFT) as usize;

/// Encode a frame header and payload.
pub fn encode(kind: Kind, chan: u32, payload: &[u8]) -> Vec<u8> {
    encode_flagged(kind, 0, chan, payload)
}

/// [`encode`] with header flags.
pub fn encode_flagged(kind: Kind, flags: u16, chan: u32, payload: &[u8]) -> Vec<u8> {
    encode_parts(kind, flags, chan, &[payload])
}

/// A frame whose payload is `parts` in order: one allocation and one copy
/// of each part (a DATA frame straight from the two halves of a ring). It
/// passes no descriptor.
pub fn encode_parts(kind: Kind, flags: u16, chan: u32, parts: &[&[u8]]) -> Vec<u8> {
    encode_frame(kind, flags, chan, parts, 0)
}

/// A frame that passes `fds` descriptors with its first byte: its header
/// states the count ([`FLAG_FDS_STATED`]). The caller sends exactly that
/// many with it ([`send_frame`], or the holder's link queue).
///
/// # Panics
///
/// When `fds` is more than [`MAX_FRAME_FDS`]: no frame of the wire passes
/// more than two.
pub fn encode_with_fds(kind: Kind, flags: u16, chan: u32, payload: &[u8], fds: usize) -> Vec<u8> {
    encode_frame(kind, flags, chan, &[payload], fds)
}

fn encode_frame(kind: Kind, flags: u16, chan: u32, parts: &[&[u8]], fds: usize) -> Vec<u8> {
    assert!(fds <= MAX_FRAME_FDS, "a frame passes at most {MAX_FRAME_FDS} descriptors");
    debug_assert_eq!(flags & (FLAG_FDS_STATED | FDS_FIELD), 0, "a kind flag in the count bits");
    let flags = flags | FLAG_FDS_STATED | ((fds as u16) << FDS_SHIFT);
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
    /// Stream offset of `buf[start]`: frames took every byte before it.
    taken: u64,
    /// Descriptors no frame took yet, in arrival order.
    fds: VecDeque<Arrival>,
    /// The `recvmsg` control buffer, allocated on the first fill.
    control: Vec<u8>,
}

/// A descriptor and the stream offsets of the bytes the read that passed it
/// returned. A sender passes a frame's descriptors with the frame's first
/// byte, so the frame they belong to starts in `from..to`.
struct Arrival {
    fd: OwnedFd,
    from: u64,
    to: u64,
}

impl Reader {
    /// Read what the socket has (one `recvmsg`). `Ok(false)` at end of
    /// stream. Descriptors the kernel had to drop (this process is out of
    /// descriptors) are a [`Fault::Descriptors`] error: the frames they
    /// belong to cannot be served, and the stream cannot be read on.
    pub fn fill(&mut self, fd: RawFd) -> io::Result<bool> {
        self.fill_with(fd, |_| {})
    }

    /// [`Self::fill`] that calls `between` with the descriptors the
    /// `recvmsg` brought, before they are made close-on-exec (macOS: the
    /// `fcntl` after the `recvmsg`; Linux: the kernel did it already). The
    /// seam for the test that spawns a child inside that window.
    pub fn fill_with(&mut self, fd: RawFd, between: impl FnOnce(&[OwnedFd])) -> io::Result<bool> {
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
        let (n, fds) = unsafe { recv_with_fds(fd, tail, room, &mut self.control, between)? };
        // SAFETY: recvmsg initialized `n` bytes past `len`.
        unsafe { self.buf.set_len(len + n) };
        let from = self.taken + len as u64;
        let to = from + n as u64;
        self.fds.extend(fds.into_iter().map(|fd| Arrival { fd, from, to }));
        Ok(n != 0)
    }

    /// The next complete frame, if one is buffered, with exactly the
    /// descriptors it passed. A bad magic, an oversized length, a frame
    /// whose descriptors did not arrive with its first byte, or descriptors
    /// no frame states are a [`Fault::Malformed`] error: the stream cannot be
    /// read on (never a frame that takes another frame's descriptor).
    pub fn next_frame(&mut self) -> io::Result<Option<Frame>> {
        let pending = self.buf.get(self.start..).unwrap_or_default();
        let Some(&[m0, m1, m2, m3, k0, k1, f0, f1, c0, c1, c2, c3, l0, l1, l2, l3]) =
            pending.first_chunk::<HEADER>()
        else {
            return Ok(None);
        };
        if [m0, m1, m2, m3] != MAGIC {
            return Err(fault(Fault::Malformed, "bad holder frame magic"));
        }
        let kind = u16::from_le_bytes([k0, k1]);
        let flags = u16::from_le_bytes([f0, f1]);
        let chan = u32::from_le_bytes([c0, c1, c2, c3]);
        let len = u32::from_le_bytes([l0, l1, l2, l3]) as usize;
        if len > MAX_PAYLOAD {
            return Err(fault(Fault::Malformed, "holder frame too large"));
        }
        let Some(payload) = pending.get(HEADER..HEADER + len) else {
            return Ok(None);
        };
        let payload = payload.to_vec();
        let frame_at = self.taken;
        self.start += HEADER + len;
        self.taken += (HEADER + len) as u64;
        if self.start == self.buf.len() {
            // Everything was taken: the next fill needs no compaction.
            self.buf.clear();
            self.start = 0;
        }
        let wanted = if flags & FLAG_FDS_STATED != 0 {
            usize::from((flags & FDS_FIELD) >> FDS_SHIFT)
        } else {
            Kind::from_u16(kind).map_or(0, |kind| kind.descriptors_with(flags))
        };
        let mut fds = Vec::with_capacity(wanted);
        for _ in 0..wanted {
            match self.fds.pop_front() {
                Some(arrival) if arrival.from <= frame_at && frame_at < arrival.to => {
                    fds.push(arrival.fd);
                }
                _ => {
                    let message = "a link frame did not pass the descriptors it states";
                    return Err(fault(Fault::Malformed, message));
                }
            }
        }
        // Every frame that starts where a descriptor arrived was taken, and
        // none took it: its sender passed more than it stated.
        if self.fds.front().is_some_and(|arrival| arrival.to <= self.taken) {
            let message = "a link frame passed descriptors it does not state";
            return Err(fault(Fault::Malformed, message));
        }
        Ok(Some(Frame { kind, flags, chan, payload, fds }))
    }
}

/// Why a link's stream cannot be read on although the socket still works:
/// the reader returns it inside the error ([`Fault::of`]). A peer that sees
/// one did not lose its peer (no crash to count), and tells it why.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fault {
    /// This process could not take the descriptors the peer passed (it is
    /// out of descriptors), so the kernel dropped them: macOS fails the read
    /// with `EMFILE`, `ENFILE` or `EMSGSIZE` and leaves the bytes, Linux
    /// delivers the descriptors that fit and sets `MSG_CTRUNC`.
    Descriptors,
    /// The bytes are not frames of this wire: a bad magic, a frame too
    /// large, or descriptors that do not match what the frames state.
    Malformed,
}

impl Fault {
    /// The fault a [`Reader`] error stands for; `None` for an error of the
    /// socket itself (the link ended or broke).
    pub fn of(error: &io::Error) -> Option<Self> {
        error.get_ref()?.downcast_ref::<FaultError>().map(|fault| fault.fault)
    }
}

/// The payload of a [`Fault`]'s `io::Error`.
#[derive(Debug)]
struct FaultError {
    fault: Fault,
    message: String,
}

impl std::fmt::Display for FaultError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for FaultError {}

/// An `io::Error` that [`Fault::of`] reads back as `fault`.
fn fault(fault: Fault, message: impl Into<String>) -> io::Error {
    let kind = match fault {
        Fault::Descriptors => io::ErrorKind::Other,
        Fault::Malformed => io::ErrorKind::InvalidData,
    };
    io::Error::new(kind, FaultError { fault, message: message.into() })
}

/// Bytes of a control buffer for [`MAX_RECV_FDS`] descriptors.
fn control_space() -> usize {
    // SAFETY: CMSG_SPACE computes a size from a length.
    unsafe { libc::CMSG_SPACE((MAX_RECV_FDS * size_of::<RawFd>()) as u32) as usize }
}

/// Write one frame that passes `fds` with its first byte, its header
/// stating how many ([`encode_with_fds`]). Blocking.
pub fn send_frame(
    fd: RawFd,
    kind: Kind,
    flags: u16,
    chan: u32,
    payload: &[u8],
    fds: &[RawFd],
) -> io::Result<()> {
    send_all(fd, &encode_with_fds(kind, flags, chan, payload, fds.len()), fds)
}

/// Write all of `bytes`, passing `fds` with the first byte. Blocking.
pub fn send_all(fd: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<()> {
    let mut sent = send_with_fds(fd, bytes, fds)?;
    while sent < bytes.len() {
        sent += send_with_fds(fd, bytes.get(sent..).unwrap_or_default(), &[])?;
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

/// `recvmsg` flags: received descriptors arrive close-on-exec where the
/// kernel can do that atomically.
#[cfg(target_os = "linux")]
const RECV_FLAGS: libc::c_int = libc::MSG_CMSG_CLOEXEC;
#[cfg(not(target_os = "linux"))]
const RECV_FLAGS: libc::c_int = 0;

/// One `recvmsg` of at most `len` bytes into `buf`, with `control` as the
/// control buffer; descriptors that arrive are returned owned
/// (close-on-exec), after `between` saw them. A descriptor that cannot be made close-on-exec fails
/// the read: every descriptor of the frame is closed then, and the link is
/// lost, rather than keeping a descriptor every later child inherits.
/// Descriptors the kernel could not hand over (this process is out of
/// descriptors) are a [`Fault::Descriptors`] error.
///
/// On Linux the kernel installs them close-on-exec (`MSG_CMSG_CLOEXEC`).
/// macOS has no such flag: there each descriptor gets `FD_CLOEXEC` right
/// after `recvmsg` returns. The holder is single-threaded, so nothing forks
/// in between there. In the multithreaded daemon this is NOT atomic: a
/// process another daemon thread spawns between the two calls inherits the
/// descriptor (a PTY master, or a ring segment: a writable copy of a
/// terminal's output) for its whole life, because the daemon's spawns (std
/// `Command`, `posix_spawn` without `POSIX_SPAWN_CLOEXEC_DEFAULT`) pass
/// every descriptor that is not close-on-exec. Nothing on the receiving
/// side can close that window on macOS; only the spawning side can (every
/// daemon child started with `POSIX_SPAWN_CLOEXEC_DEFAULT` and explicit
/// `dup2` actions, as `cmux-mux2`'s `spawn_pty` does): `cmux-process`'s
/// `Command` (review 1 of pl-holder-11, major), which every daemon spawn
/// moves to. `tests/spawn_race.rs` spawns inside this window.
///
/// # Safety
///
/// `buf` must be valid for writes of `len` bytes.
unsafe fn recv_with_fds(
    fd: RawFd,
    buf: *mut u8,
    len: usize,
    control: &mut [u8],
    between: impl FnOnce(&[OwnedFd]),
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
        let n = unsafe { libc::recvmsg(fd, &mut msg, RECV_FLAGS) };
        if n >= 0 {
            break n as usize;
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => {}
            Some(errno) if dropped_descriptors(errno) => {
                let message = format!("the kernel dropped descriptors the link passed: {error}");
                return Err(fault(Fault::Descriptors, message));
            }
            _ => return Err(error),
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
                    // Owned at once, so every one of them closes on any
                    // early return below.
                    fds.push(OwnedFd::from_raw_fd(std::ptr::read_unaligned(data.add(index))));
                }
            }
            cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
        }
    }
    if msg.msg_flags & libc::MSG_CTRUNC != 0 {
        // Linux: no room for all of them (or more than one read takes).
        // The descriptors that did arrive close with `fds`.
        return Err(fault(Fault::Descriptors, "the kernel dropped descriptors the link passed"));
    }
    between(&fds);
    if RECV_FLAGS == 0 {
        for fd in &fds {
            // SAFETY: F_SETFD on a descriptor this call owns.
            if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
                return Err(io::Error::last_os_error());
            }
        }
    }
    Ok((n, fds))
}

/// Whether a failed `recvmsg` on a Unix stream socket means the kernel
/// could not hand over the descriptors that came with the bytes: it
/// dropped them and left the bytes, which now lack them. `EMFILE` or
/// `ENFILE`: allocating one of them failed (macOS 27.0, measured).
/// `EMSGSIZE`, on macOS: XNU's `unp_externalize` fails with it when the
/// descriptor table has no room for them all (its `fdavail` check, in the
/// BSD code since 4.4BSD), which other macOS majors may return for the
/// same exhaustion; a stream socket's `recvmsg` has no other source of it,
/// since a message is never too long for a stream. Linux does not fail the
/// read for them: it delivers what fits and sets `MSG_CTRUNC`
/// ([`recv_with_fds`]).
fn dropped_descriptors(errno: i32) -> bool {
    matches!(errno, libc::EMFILE | libc::ENFILE)
        || (cfg!(target_vendor = "apple") && errno == libc::EMSGSIZE)
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
        Ok(self.take(1)?.first().copied().unwrap_or_default())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    fn close_on_exec(fd: &OwnedFd) -> bool {
        // SAFETY: F_GETFD of a descriptor this test owns.
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
        assert!(flags >= 0, "F_GETFD: {}", io::Error::last_os_error());
        flags & libc::FD_CLOEXEC != 0
    }

    /// Every descriptor a frame brings (the daemon's custody copy of a PTY
    /// master, and of a terminal's ring segment) is close-on-exec once the
    /// frame is read, though the sender's copies are not: no process the
    /// multithreaded daemon spawns later inherits a shell's terminal or a
    /// writable copy of its output.
    #[test]
    fn descriptors_a_frame_brings_are_close_on_exec() {
        let (sender, receiver) = UnixStream::pair().unwrap();
        let mut ends = [0; 2];
        // SAFETY: pipe fills two descriptors this test then owns.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both are fresh descriptors nothing else owns.
        let (read_end, write_end) =
            unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
        assert!(!close_on_exec(&read_end) && !close_on_exec(&write_end), "pipe() sets no flag");
        let frame = encode_with_fds(Kind::Spawned, FLAG_RING, 7, b"spawned", 2);
        send_all(sender.as_raw_fd(), &frame, &[raw(&read_end), raw(&write_end)]).unwrap();

        let mut reader = Reader::default();
        let frame = loop {
            if let Some(frame) = reader.next_frame().unwrap() {
                break frame;
            }
            assert!(reader.fill(receiver.as_raw_fd()).unwrap(), "the stream ended early");
        };
        assert_eq!((frame.kind, frame.chan), (Kind::Spawned as u16, 7));
        assert_eq!(frame.fds.len(), 2, "a ring spawn brings the master and the segment");
        for (index, fd) in frame.fds.iter().enumerate() {
            assert!(close_on_exec(fd), "descriptor {index} arrived without close-on-exec");
        }
    }
}
