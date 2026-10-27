//! The holder's wire: 16-byte frames on one Unix stream socket, file
//! descriptors passed with `SCM_RIGHTS` (terminal-host-model-DESIGN.md
//! section 4).
//!
//! `magic "CMHX" | kind u16 | flags u16 | chan u32 | len u32 | payload`,
//! little endian. `chan` names one terminal; 0 is the link itself. A frame
//! that carries descriptors sends them with its first byte; the receiver
//! queues them in arrival order and the frame kind says how many it takes.

use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};

use cmux_ipc::fds::{self, FdReceiver};

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

/// Optional features a link negotiates beside its version (pty-holder.md
/// section 2.1: "New features are optional capability bits"). A daemon of
/// this build asks for them in its [`Kind::Hello`] (`wanted u32` after the
/// token), the holder grants the ones it serves in its [`Kind::Welcome`]
/// (`granted u32` after the count). A peer older than these bits reads
/// neither field: an older holder grants nothing, so the daemon sends it
/// none of their frames, and an older daemon asks for nothing. The version
/// stays 5. Bits are never reused.
pub mod capability {
    /// [`super::Kind::TraceStart`] and [`super::Kind::TraceStop`]: the
    /// daemon starts and stops this holder's trace recording. Granted only
    /// by a holder whose tracer runs.
    pub const TRACE_CONTROL: u32 = 1 << 0;
    /// [`super::FLAG_FLOW`] on [`super::Kind::Write`]: the frame ends with
    /// the `flow u64` of the key press that wrote it.
    pub const WRITE_FLOW: u32 = 1 << 1;
    /// [`super::Kind::Hang`]: the holder reports a pass of its loop that
    /// ran past its hang deadline to the daemon's hang log.
    pub const HANG_REPORT: u32 = 1 << 2;
    /// Every bit this build knows (a holder serves TRACE_CONTROL only with
    /// its tracer running).
    pub const SUPPORTED: u32 = TRACE_CONTROL | WRITE_FLOW | HANG_REPORT;
}
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
    /// d->h: `version u16, token [u8; 32]`, then the optional `wanted
    /// u32` ([`capability`] bits; absent from an older daemon: none).
    Hello = 1,
    /// h->d: `version u16` (the lower of the two peers' versions), `count
    /// u32`, then the optional `granted u32` ([`capability`] bits, a subset
    /// of `wanted`; absent from an older holder: none), then one
    /// [`Kind::Listed`] per terminal.
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
    /// d->h: bytes for the PTY. With [`FLAG_FLOW`] (granted
    /// [`capability::WRITE_FLOW`] only) the last 8 bytes are not input but
    /// the `flow u64` of the key press the bytes carry; the bytes before it
    /// may be empty (a flow mark for input the daemon wrote on its custody
    /// master).
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
    /// h->d (version 5): the answer to every [`Kind::Adopt`] on the
    /// channel: `oldest u64, end u64` of the ring the holder writes the
    /// terminal's output to from now on. With [`FLAG_RING`] that ring's
    /// segment is the one descriptor: the segment the ADOPT carried when the
    /// holder continues it, a fresh one when it could not (a bad or stale
    /// segment). Without the flag the ring is private. The daemon keeps
    /// exactly this segment as its custody copy, so it never hands a later
    /// holder a segment nobody writes.
    Adopted = 21,
    /// d->h on channel 0 (granted [`capability::TRACE_CONTROL`] only):
    /// start this holder's trace recording: `categories u64` (the
    /// `cmux_trace::category` bits to record), `budget_bytes u64` (the
    /// most ring bytes the daemon's total cap leaves this holder, the unit
    /// of `cmux_trace::Status::recording_bytes`; 0: no limit). No path: the
    /// holder writes where its own trace directory is. No answer when it
    /// started; an [`Kind::Error`] with `TRACE_FAILED` when it did not. The
    /// recording ends with the link that started it.
    TraceStart = 22,
    /// d->h on channel 0 (granted [`capability::TRACE_CONTROL`] only):
    /// stop the recording. Empty payload; an [`Kind::Error`] with
    /// `TRACE_FAILED` when none ran.
    TraceStop = 23,
    /// h->d on channel 0 (granted [`capability::HANG_REPORT`] only): a pass
    /// of the holder's loop was still busy past its hang deadline
    /// ([`HangReport`]). No answer.
    Hang = 24,
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
            22 => TraceStart,
            23 => TraceStop,
            24 => Hang,
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
/// [`Kind::Write`] flag ([`capability::WRITE_FLOW`]): the payload ends
/// with the `flow u64` trailer ([`write_flow_payload`]). Sent only to a
/// holder that granted the capability: an older holder would write the
/// trailer into the shell.
pub const FLAG_FLOW: u16 = 4;

/// The payload of a [`Kind::Write`] with [`FLAG_FLOW`]: `bytes`, then
/// `flow`. `bytes` may be at most [`MAX_PAYLOAD`] - 8 long.
pub fn write_flow_payload(bytes: &[u8], flow: u64) -> Vec<u8> {
    Out(Vec::with_capacity(bytes.len() + 8)).bytes(bytes).u64(flow).0
}

/// A [`Kind::Write`] payload split into its input and its flow: the flow
/// is `Some` only with [`FLAG_FLOW`]. A flagged payload shorter than the
/// trailer is an error.
pub fn split_write(flags: u16, payload: &[u8]) -> io::Result<(&[u8], Option<u64>)> {
    if flags & FLAG_FLOW == 0 {
        return Ok((payload, None));
    }
    let Some(at) = payload.len().checked_sub(8) else {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "short write flow trailer"));
    };
    let (bytes, trailer) = payload.split_at(at);
    Ok((bytes, Some(In(trailer).u64()?)))
}

/// The payload of a [`Kind::TraceStart`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TraceStart {
    /// `cmux_trace::category` bits to record.
    pub categories: u64,
    /// The most recording ring bytes the daemon's total cap leaves this
    /// holder (`cmux_trace::Status::recording_bytes`; 0: no limit).
    pub budget_bytes: u64,
}

impl TraceStart {
    pub fn encode(self) -> Vec<u8> {
        Out::default().u64(self.categories).u64(self.budget_bytes).0
    }

    pub fn decode(payload: &[u8]) -> io::Result<Self> {
        let mut input = In(payload);
        Ok(Self { categories: input.u64()?, budget_bytes: input.u64()? })
    }
}

/// The payload of a [`Kind::Hang`]: `deadline_ms u64, busy_ms u64`, then
/// the watched site's name in UTF-8.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HangReport {
    /// The site's hang deadline.
    pub deadline_ms: u64,
    /// How long the pass had been busy when the holder's watcher saw it.
    pub busy_ms: u64,
    /// The watched site (`holder-loop`).
    pub site: String,
}

impl HangReport {
    pub fn encode(&self) -> Vec<u8> {
        Out::default().u64(self.deadline_ms).u64(self.busy_ms).bytes(self.site.as_bytes()).0
    }

    pub fn decode(payload: &[u8]) -> io::Result<Self> {
        let mut input = In(payload);
        let deadline_ms = input.u64()?;
        let busy_ms = input.u64()?;
        let site = String::from_utf8_lossy(input.rest()).into_owned();
        Ok(Self { deadline_ms, busy_ms, site })
    }
}

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

/// Bytes read from a socket, with the descriptors that arrived alongside,
/// split into frames. Frames are taken from a read cursor; the buffer is
/// compacted once per [`Self::fill`], not once per frame, and the receive
/// buffers are allocated once. The `recvmsg` and the descriptor FIFO are
/// `cmux_ipc::fds` (a WELCOME passes one descriptor per terminal, so one
/// read may bring up to [`fds::MAX_RECV_FDS`]).
#[derive(Default)]
pub struct Reader {
    buf: Vec<u8>,
    /// Offset in `buf` of the first byte no frame took yet.
    start: usize,
    fds: FdReceiver,
}

impl Reader {
    /// Read what the socket has (one `recvmsg`). `Ok(false)` at end of stream.
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
        let n = self.fds.recv(fd, &mut self.buf, READ_CHUNK, between)?;
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
        let wanted = Kind::from_u16(kind).map_or(0, |kind| kind.descriptors_with(flags));
        let fds = self.fds.take(wanted).map_err(|bad| bad.into_io(io::ErrorKind::InvalidData))?;
        Ok(Some(Frame { kind, flags, chan, payload, fds }))
    }
}

pub use fds::{send_all, send_with_fds};

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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::fd::FromRawFd;
    use std::os::unix::net::UnixStream;

    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut ends = [0; 2];
        // SAFETY: pipe fills two descriptors this test then owns.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both are fresh descriptors nothing else owns.
        unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) }
    }

    /// The (inode, access mode) of the file a descriptor names.
    fn identity(fd: &OwnedFd) -> (u64, libc::c_int) {
        // SAFETY: zeroed stat is a valid out-parameter.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: fstat and F_GETFL of a descriptor this test owns.
        let (stat, flags) = unsafe {
            (libc::fstat(fd.as_raw_fd(), &mut st), libc::fcntl(fd.as_raw_fd(), libc::F_GETFL))
        };
        assert!(stat == 0 && flags >= 0, "{}", io::Error::last_os_error());
        (st.st_ino as u64, flags & libc::O_ACCMODE)
    }

    /// The wire is the holder's frozen format with its descriptors: a ring
    /// SPAWNED frame is these exact bytes on the socket (what every older
    /// holder and daemon reads), and its two descriptors arrive with it,
    /// master first, then the ring segment.
    #[test]
    fn a_frame_with_descriptors_is_the_frozen_bytes_in_order() {
        const SPAWNED_RING: &[u8] = b"CMHX\x04\x00\x02\x00\x07\x00\x00\x00\x07\x00\x00\x00spawned";
        let frame = encode_flagged(Kind::Spawned, FLAG_RING, 7, b"spawned");
        assert_eq!(frame, SPAWNED_RING);
        let (master, _master_write) = pipe();
        let (_ring_read, ring) = pipe();

        let (sender, mut receiver) = UnixStream::pair().unwrap();
        send_all(sender.as_raw_fd(), &frame, &[raw(&master), raw(&ring)]).unwrap();
        let mut bytes = vec![0; SPAWNED_RING.len()];
        receiver.read_exact(&mut bytes).unwrap();
        assert_eq!(bytes, SPAWNED_RING, "the bytes on the socket are the encoded frame");

        send_all(sender.as_raw_fd(), &frame, &[raw(&master), raw(&ring)]).unwrap();
        let mut reader = Reader::default();
        let frame = loop {
            if let Some(frame) = reader.next_frame().unwrap() {
                break frame;
            }
            assert!(reader.fill(receiver.as_raw_fd()).unwrap(), "the stream ended early");
        };
        assert_eq!((frame.kind, frame.flags, frame.chan), (Kind::Spawned as u16, FLAG_RING, 7));
        assert_eq!(frame.payload, b"spawned");
        assert_eq!(
            frame.fds.iter().map(identity).collect::<Vec<_>>(),
            [identity(&master), identity(&ring)],
            "master first, then the ring segment"
        );
    }

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
        let frame = encode_flagged(Kind::Spawned, FLAG_RING, 7, b"spawned");
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
