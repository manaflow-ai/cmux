//! The daemon-worker wire: length-prefixed frames on one Unix stream
//! socket, descriptors as `SCM_RIGHTS` with a frame's first byte
//! (cmux-ipc's FIFO, Chromium's `mojo/core/channel_posix.cc` model).
//!
//! A frame is `payload length u32 | kind u8 | descriptor count u8 |
//! reserved u16 | payload`, little endian. Commands go daemon to worker,
//! events worker to daemon; a kind from the other direction, a short
//! payload, a wrong descriptor count or a payload over [`MAX_PAYLOAD`] is a
//! [`WireError`] and ends the connection (the daemon then treats the worker
//! as a bad message).

use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};

use cmux_ipc::fds::{self, FdReceiver};
use cmux_kitty_media::{DEFAULT_MAX_FILE_BYTES, FileMedium, MediaRefusal, MediaRequest};
use ghostty_vt::{
    CursorShape, KittyGraphicsLimits, ProgramStatusEvent, ProgramStatusKind, ProgramStatusReport,
    ProgramStatusState, Rgb,
};

use crate::sandbox::{SandboxMechanism, SandboxPolicy};
use crate::shm::{self, Mapping};

/// The wire version a worker's HELLO names.
pub const WIRE_VERSION: u16 = 1;
/// Frame header bytes.
pub const FRAME_HEADER: usize = 8;
/// The largest payload either side sends.
pub const MAX_PAYLOAD: usize = 1 << 20;
/// The most bytes one PTY_WRITE, TITLE or PWD event carries.
pub const MAX_EVENT_TEXT: usize = 64 << 10;
/// The most bytes of one OSC 7501 text field: libghostty refuses a longer
/// sequence (ghostty-next `program_status.zig` `max_sequence_bytes`).
pub const MAX_STATUS_TEXT: usize = 4096;
/// The longest Kitty file name a request carries: the rewriter holds at
/// most this much of a command (`cmux_kitty_media::Limits::max_held_bytes`).
pub const MAX_MEDIA_NAME: usize = 8 << 10;
/// The most bytes one Kitty file read answers with: the rewriter's cap.
pub const MAX_MEDIA_BYTES: u64 = DEFAULT_MAX_FILE_BYTES;

/// A frame that broke the wire's rules.
#[derive(Debug, PartialEq, Eq)]
pub enum WireError {
    UnknownKind(u8),
    PayloadTooLarge(usize),
    Truncated { kind: u8 },
    Trailing { kind: u8 },
    Descriptors { kind: u8, expected: usize, got: usize },
    BadValue(&'static str),
    Fds(fds::FdBadMessage),
}

impl std::fmt::Display for WireError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownKind(kind) => write!(f, "unknown frame kind {kind}"),
            Self::PayloadTooLarge(len) => write!(f, "payload of {len} bytes"),
            Self::Truncated { kind } => write!(f, "frame {kind} truncated"),
            Self::Trailing { kind } => write!(f, "frame {kind} has trailing bytes"),
            Self::Descriptors { kind, expected, got } => {
                write!(f, "frame {kind} takes {expected} descriptors, got {got}")
            }
            Self::BadValue(what) => write!(f, "bad value: {what}"),
            Self::Fds(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for WireError {}

/// A terminal's grid and cell size in pixels (size reports).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Geometry {
    pub cols: u16,
    pub rows: u16,
    pub cell_width: u16,
    pub cell_height: u16,
}

/// The parser settings the daemon gives a terminal, as its own parser has
/// them (surface/spawn.rs): default colors, palette and cursor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Colors {
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub cursor: Option<Rgb>,
    pub cursor_style: Option<CursorShape>,
    pub cursor_blink: Option<bool>,
    pub palette: Box<[Option<Rgb>; 256]>,
}

impl Default for Colors {
    fn default() -> Self {
        Self {
            fg: None,
            bg: None,
            cursor: None,
            cursor_style: None,
            cursor_blink: None,
            palette: Box::new([None; 256]),
        }
    }
}

/// A terminal joining the shard, with its ring and its page.
#[derive(Debug)]
pub struct Attach {
    pub id: u64,
    /// The ring offset the parser starts at.
    pub start: u64,
    pub ring: OwnedFd,
    pub ring_capacity: u64,
    pub page: OwnedFd,
    pub page_len: u64,
    /// The parser's retained scrollback, in bytes.
    pub scrollback: u64,
    pub geometry: Geometry,
    /// The terminal's share of the session's Kitty image budget, as the
    /// daemon sets it on its own parser (surface/spawn.rs).
    pub kitty_limits: KittyGraphicsLimits,
}

/// The daemon's answer to a [`Event::KittyMediaRequest`].
#[derive(Debug)]
pub enum MediaAnswer {
    /// The bytes read, in a shared segment of `len` bytes (none for 0).
    Bytes { segment: Option<OwnedFd>, len: u64 },
    /// The read was refused: the command passes through unchanged.
    Refused(MediaRefusal),
}

impl MediaAnswer {
    /// The daemon's side: the answer to `request`, read with the checks
    /// the in-daemon rewriter applies (`MediaRequest::read`). The worker
    /// asks only for commands in its terminal's own output, which the
    /// in-daemon parser would read the same way.
    pub fn read(request: &MediaRequest) -> io::Result<Self> {
        Self::from_read(request.read(MAX_MEDIA_BYTES))
    }

    /// The answer for a read already done.
    pub fn from_read(read: Result<Vec<u8>, MediaRefusal>) -> io::Result<Self> {
        match read {
            Ok(bytes) if bytes.is_empty() => Ok(Self::Bytes { segment: None, len: 0 }),
            Ok(bytes) => Ok(Self::Bytes {
                segment: Some(shm::segment_with(&bytes)?),
                len: bytes.len() as u64,
            }),
            Err(refusal) => Ok(Self::Refused(refusal)),
        }
    }

    /// The worker's side: the bytes, copied out of the segment, or the
    /// refusal. A segment it cannot map reads as an I/O refusal.
    pub fn into_read(self) -> Result<Vec<u8>, MediaRefusal> {
        match self {
            Self::Refused(refusal) => Err(refusal),
            Self::Bytes { segment: None, .. } => Ok(Vec::new()),
            Self::Bytes { segment: Some(segment), len } => {
                let len = usize::try_from(len)
                    .map_err(|_| MediaRefusal::Io(io::ErrorKind::InvalidData))?;
                let map = Mapping::map(std::os::fd::AsFd::as_fd(&segment), len, false)
                    .map_err(MediaRefusal::from)?;
                let mut bytes = vec![0; len];
                if !map.copy_out(0, &mut bytes) {
                    return Err(MediaRefusal::Io(io::ErrorKind::InvalidData));
                }
                Ok(bytes)
            }
        }
    }
}

/// Daemon to worker.
#[derive(Debug)]
pub enum Command {
    /// The first frame: the sandbox to apply before anything else.
    Bootstrap(SandboxPolicy),
    Attach(Attach),
    /// The holder published the ring up to `end`.
    Advance {
        id: u64,
        end: u64,
    },
    /// A new grid; a new page when the old one is too small for it.
    Resize {
        id: u64,
        geometry: Geometry,
        page: Option<(OwnedFd, u64)>,
    },
    Colors {
        id: u64,
        colors: Colors,
    },
    Detach {
        id: u64,
    },
    /// The terminal's Kitty image budget changed (host_kitty_limits.rs).
    KittyLimits {
        id: u64,
        limits: KittyGraphicsLimits,
    },
    /// The answer to the terminal's [`Event::KittyMediaRequest`].
    KittyMedia {
        id: u64,
        answer: MediaAnswer,
    },
}

/// Worker to daemon.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// After the sandbox applied: the worker's wire version and sandbox.
    Hello {
        version: u16,
        sandbox: SandboxMechanism,
        pid: u32,
    },
    /// The parser consumed the ring to `offset` and published `frame`.
    Parsed {
        id: u64,
        offset: u64,
        frame: u64,
    },
    /// Bytes the parser answers to the PTY (DA, DSR...); the daemon
    /// validates them before it writes.
    PtyWrite {
        id: u64,
        bytes: Vec<u8>,
    },
    Title {
        id: u64,
        title: String,
    },
    Pwd {
        id: u64,
        pwd: String,
    },
    Bell {
        id: u64,
        count: u32,
    },
    /// The ring dropped `from .. oldest` before the parser read it: the
    /// parser got CAN there and continues at `oldest`.
    Lapped {
        id: u64,
        from: u64,
        oldest: u64,
    },
    /// The screen needs a page of `needed` bytes (send a RESIZE with one).
    PageTooSmall {
        id: u64,
        needed: u64,
    },
    /// The terminal could not join the shard.
    AttachFailed {
        id: u64,
        reason: AttachFailure,
    },
    /// An OSC 7501 program status report or a primary prompt start, in
    /// stream order, as the daemon's parser hands them to its records
    /// (program_status.rs).
    ProgramStatus {
        id: u64,
        event: ProgramStatusEvent,
    },
    /// A file-medium Kitty command needs its file read; the terminal's
    /// parse waits for the [`Command::KittyMedia`] answer. The worker may
    /// open no file, so the daemon reads it, as Chrome's broker does.
    KittyMediaRequest {
        id: u64,
        request: MediaRequest,
    },
}

/// Why an ATTACH or a RESIZE page was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum AttachFailure {
    Ring = 1,
    Page = 2,
    Parser = 3,
    Duplicate = 4,
    Unknown = 5,
}

impl AttachFailure {
    fn from_wire(value: u8) -> Option<Self> {
        Some(match value {
            1 => Self::Ring,
            2 => Self::Page,
            3 => Self::Parser,
            4 => Self::Duplicate,
            5 => Self::Unknown,
            _ => return None,
        })
    }
}

mod kind {
    pub const BOOTSTRAP: u8 = 1;
    pub const ATTACH: u8 = 2;
    pub const ADVANCE: u8 = 3;
    pub const RESIZE: u8 = 4;
    pub const COLORS: u8 = 5;
    pub const DETACH: u8 = 6;
    pub const KITTY_LIMITS: u8 = 7;
    pub const KITTY_MEDIA: u8 = 8;
    pub const HELLO: u8 = 64;
    pub const PARSED: u8 = 65;
    pub const PTY_WRITE: u8 = 66;
    pub const TITLE: u8 = 67;
    pub const PWD: u8 = 68;
    pub const BELL: u8 = 69;
    pub const LAPPED: u8 = 70;
    pub const PAGE_TOO_SMALL: u8 = 71;
    pub const ATTACH_FAILED: u8 = 72;
    pub const PROGRAM_STATUS: u8 = 73;
    pub const KITTY_MEDIA_REQUEST: u8 = 74;
}

/// Write one frame (blocking).
fn send(socket: RawFd, kind: u8, payload: &[u8], fds: &[RawFd]) -> io::Result<()> {
    if payload.len() > MAX_PAYLOAD {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "payload too large"));
    }
    let mut frame = Vec::with_capacity(FRAME_HEADER + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    frame.push(kind);
    frame.push(fds.len() as u8);
    frame.extend_from_slice(&[0, 0]);
    frame.extend_from_slice(payload);
    fds::send_all(socket, &frame, fds)
}

/// Send `command` (the daemon's side).
pub fn send_command(socket: RawFd, command: &Command) -> io::Result<()> {
    let mut out = Vec::new();
    match command {
        Command::Bootstrap(policy) => {
            match policy {
                SandboxPolicy::Unsandboxed => out.push(0),
                SandboxPolicy::Seatbelt(compiled) => {
                    out.push(1);
                    out.extend_from_slice(compiled);
                }
            }
            send(socket, kind::BOOTSTRAP, &out, &[])
        }
        Command::Attach(attach) => {
            for value in
                [attach.id, attach.start, attach.ring_capacity, attach.page_len, attach.scrollback]
            {
                out.extend_from_slice(&value.to_le_bytes());
            }
            put_geometry(&mut out, attach.geometry);
            put_kitty_limits(&mut out, attach.kitty_limits);
            send(socket, kind::ATTACH, &out, &[attach.ring.as_raw_fd(), attach.page.as_raw_fd()])
        }
        Command::KittyLimits { id, limits } => {
            out.extend_from_slice(&id.to_le_bytes());
            put_kitty_limits(&mut out, *limits);
            send(socket, kind::KITTY_LIMITS, &out, &[])
        }
        Command::KittyMedia { id, answer } => {
            out.extend_from_slice(&id.to_le_bytes());
            let (outcome, len, fds) = match answer {
                MediaAnswer::Bytes { segment, len } => {
                    (0, *len, segment.iter().map(|fd| fd.as_raw_fd()).collect::<Vec<_>>())
                }
                MediaAnswer::Refused(refusal) => (refusal_code(refusal), 0, Vec::new()),
            };
            out.push(outcome);
            out.extend_from_slice(&len.to_le_bytes());
            send(socket, kind::KITTY_MEDIA, &out, &fds)
        }
        Command::Advance { id, end } => {
            out.extend_from_slice(&id.to_le_bytes());
            out.extend_from_slice(&end.to_le_bytes());
            send(socket, kind::ADVANCE, &out, &[])
        }
        Command::Resize { id, geometry, page } => {
            out.extend_from_slice(&id.to_le_bytes());
            put_geometry(&mut out, *geometry);
            out.extend_from_slice(&page.as_ref().map_or(0, |(_, len)| *len).to_le_bytes());
            let fds: Vec<RawFd> = page.iter().map(|(fd, _)| fd.as_raw_fd()).collect();
            send(socket, kind::RESIZE, &out, &fds)
        }
        Command::Colors { id, colors } => {
            out.extend_from_slice(&id.to_le_bytes());
            for color in [colors.fg, colors.bg, colors.cursor] {
                put_rgb(&mut out, color);
            }
            out.push(match colors.cursor_style {
                None => 0,
                Some(CursorShape::Bar) => 1,
                Some(CursorShape::Block) => 2,
                Some(CursorShape::Underline) => 3,
                Some(CursorShape::BlockHollow) => 4,
            });
            out.push(match colors.cursor_blink {
                None => 0,
                Some(false) => 1,
                Some(true) => 2,
            });
            for color in colors.palette.iter() {
                put_rgb(&mut out, *color);
            }
            send(socket, kind::COLORS, &out, &[])
        }
        Command::Detach { id } => send(socket, kind::DETACH, &id.to_le_bytes(), &[]),
    }
}

/// Send `event` (the worker's side). Text longer than [`MAX_EVENT_TEXT`]
/// is cut at a character boundary; PTY bytes over it go in several frames.
pub fn send_event(socket: RawFd, event: &Event) -> io::Result<()> {
    let mut out = Vec::new();
    let (kind, fields): (u8, &[u64]) = match event {
        Event::Hello { version, sandbox, pid } => {
            out.extend_from_slice(&version.to_le_bytes());
            out.push(*sandbox as u8);
            out.extend_from_slice(&pid.to_le_bytes());
            return send(socket, kind::HELLO, &out, &[]);
        }
        Event::Parsed { id, offset, frame } => (kind::PARSED, &[*id, *offset, *frame]),
        Event::Lapped { id, from, oldest } => (kind::LAPPED, &[*id, *from, *oldest]),
        Event::PageTooSmall { id, needed } => (kind::PAGE_TOO_SMALL, &[*id, *needed]),
        Event::PtyWrite { id, bytes } => {
            for chunk in bytes.chunks(MAX_EVENT_TEXT) {
                out.clear();
                out.extend_from_slice(&id.to_le_bytes());
                out.extend_from_slice(chunk);
                send(socket, kind::PTY_WRITE, &out, &[])?;
            }
            return Ok(());
        }
        Event::Title { id, title: text } | Event::Pwd { id, pwd: text } => {
            let kind = if matches!(event, Event::Title { .. }) { kind::TITLE } else { kind::PWD };
            out.extend_from_slice(&id.to_le_bytes());
            out.extend_from_slice(truncate_utf8(text, MAX_EVENT_TEXT).as_bytes());
            return send(socket, kind, &out, &[]);
        }
        Event::Bell { id, count } => {
            out.extend_from_slice(&id.to_le_bytes());
            out.extend_from_slice(&count.to_le_bytes());
            return send(socket, kind::BELL, &out, &[]);
        }
        Event::AttachFailed { id, reason } => {
            out.extend_from_slice(&id.to_le_bytes());
            out.push(*reason as u8);
            return send(socket, kind::ATTACH_FAILED, &out, &[]);
        }
        Event::ProgramStatus { id, event } => {
            out.extend_from_slice(&id.to_le_bytes());
            put_program_status(&mut out, event);
            return send(socket, kind::PROGRAM_STATUS, &out, &[]);
        }
        Event::KittyMediaRequest { id, request } => {
            out.extend_from_slice(&id.to_le_bytes());
            out.push(match request.medium {
                FileMedium::File => 1,
                FileMedium::TempFile => 2,
                FileMedium::SharedMemory => 3,
            });
            out.extend_from_slice(&request.offset.to_le_bytes());
            out.extend_from_slice(&request.size.to_le_bytes());
            let name = request.name.get(..MAX_MEDIA_NAME).unwrap_or(&request.name);
            out.extend_from_slice(name);
            return send(socket, kind::KITTY_MEDIA_REQUEST, &out, &[]);
        }
    };
    for value in fields {
        out.extend_from_slice(&value.to_le_bytes());
    }
    send(socket, kind, &out, &[])
}

fn truncate_utf8(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

fn put_geometry(out: &mut Vec<u8>, geometry: Geometry) {
    for value in [geometry.cols, geometry.rows, geometry.cell_width, geometry.cell_height] {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

fn put_rgb(out: &mut Vec<u8>, color: Option<Rgb>) {
    match color {
        None => out.extend_from_slice(&[0, 0, 0, 0]),
        Some(rgb) => out.extend_from_slice(&[1, rgb.r, rgb.g, rgb.b]),
    }
}

fn put_kitty_limits(out: &mut Vec<u8>, limits: KittyGraphicsLimits) {
    for value in [limits.image_bytes, limits.inflight_bytes, limits.images, limits.placements] {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

/// `tag u8` (0 prompt start, 1 report), then for a report `state u8,
/// kind u8, progress u8 (0xFF none)` and the id, app, title and message as
/// `len u16 | UTF-8`.
fn put_program_status(out: &mut Vec<u8>, event: &ProgramStatusEvent) {
    let report = match event {
        ProgramStatusEvent::PromptStart => {
            out.push(0);
            return;
        }
        ProgramStatusEvent::Report(report) => report,
    };
    out.push(1);
    out.push(match report.state {
        ProgramStatusState::Idle => 0,
        ProgramStatusState::Working => 1,
        ProgramStatusState::Done => 2,
        ProgramStatusState::Blocked => 3,
        ProgramStatusState::Error => 4,
        ProgramStatusState::Clear => 5,
    });
    out.push(match report.kind {
        None => 0,
        Some(ProgramStatusKind::Permission) => 1,
        Some(ProgramStatusKind::Question) => 2,
        Some(ProgramStatusKind::Auth) => 3,
    });
    out.push(report.progress.filter(|progress| *progress <= 100).unwrap_or(u8::MAX));
    for text in [&report.id, &report.app, &report.title, &report.message] {
        let text = truncate_utf8(text, MAX_STATUS_TEXT);
        out.extend_from_slice(&(text.len() as u16).to_le_bytes());
        out.extend_from_slice(text.as_bytes());
    }
}

fn refusal_code(refusal: &MediaRefusal) -> u8 {
    match refusal {
        MediaRefusal::BadEncoding => 1,
        MediaRefusal::BadPath => 2,
        MediaRefusal::Forbidden => 3,
        MediaRefusal::NotTemporary => 4,
        MediaRefusal::NotRegular => 5,
        MediaRefusal::TooLarge => 6,
        MediaRefusal::Short => 7,
        MediaRefusal::BadRange => 8,
        MediaRefusal::Unsupported => 9,
        MediaRefusal::Io(_) => 10,
    }
}

fn refusal_from(code: u8) -> Option<MediaRefusal> {
    Some(match code {
        1 => MediaRefusal::BadEncoding,
        2 => MediaRefusal::BadPath,
        3 => MediaRefusal::Forbidden,
        4 => MediaRefusal::NotTemporary,
        5 => MediaRefusal::NotRegular,
        6 => MediaRefusal::TooLarge,
        7 => MediaRefusal::Short,
        8 => MediaRefusal::BadRange,
        9 => MediaRefusal::Unsupported,
        10 => MediaRefusal::Io(io::ErrorKind::Other),
        _ => return None,
    })
}

/// Reads frames off a socket and pairs each with its descriptors.
#[derive(Debug, Default)]
pub struct FrameReader {
    buf: Vec<u8>,
    fds: FdReceiver,
}

/// One frame: its kind, payload and descriptors.
#[derive(Debug)]
pub struct Frame {
    pub kind: u8,
    pub payload: Vec<u8>,
    pub fds: Vec<OwnedFd>,
}

impl FrameReader {
    /// One read from `socket` (blocking unless the socket is ready).
    /// Returns the bytes read; 0 is end of stream.
    pub fn fill(&mut self, socket: RawFd) -> io::Result<usize> {
        self.fds.recv(socket, &mut self.buf, 64 << 10, |_| {})
    }

    /// The next whole frame read so far.
    pub fn next_frame(&mut self) -> Result<Option<Frame>, WireError> {
        if self.buf.len() < FRAME_HEADER {
            return Ok(None);
        }
        let len = u32::from_le_bytes([self.buf[0], self.buf[1], self.buf[2], self.buf[3]]) as usize;
        if len > MAX_PAYLOAD {
            return Err(WireError::PayloadTooLarge(len));
        }
        if self.buf.len() < FRAME_HEADER + len {
            return Ok(None);
        }
        let kind = self.buf[4];
        let count = usize::from(self.buf[5]);
        let fds = self.fds.take(count).map_err(WireError::Fds)?;
        if fds.len() != count {
            return Err(WireError::Descriptors { kind, expected: count, got: fds.len() });
        }
        let payload = self.buf[FRAME_HEADER..FRAME_HEADER + len].to_vec();
        self.buf.drain(..FRAME_HEADER + len);
        Ok(Some(Frame { kind, payload, fds }))
    }
}

/// A little-endian cursor over a payload.
struct Payload<'a> {
    kind: u8,
    bytes: &'a [u8],
}

impl<'a> Payload<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], WireError> {
        if self.bytes.len() < n {
            return Err(WireError::Truncated { kind: self.kind });
        }
        let (head, rest) = self.bytes.split_at(n);
        self.bytes = rest;
        Ok(head)
    }

    fn u8(&mut self) -> Result<u8, WireError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, WireError> {
        let bytes = self.take(2)?;
        Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
    }

    fn u32(&mut self) -> Result<u32, WireError> {
        let mut word = [0u8; 4];
        word.copy_from_slice(self.take(4)?);
        Ok(u32::from_le_bytes(word))
    }

    fn u64(&mut self) -> Result<u64, WireError> {
        let mut word = [0u8; 8];
        word.copy_from_slice(self.take(8)?);
        Ok(u64::from_le_bytes(word))
    }

    fn geometry(&mut self) -> Result<Geometry, WireError> {
        Ok(Geometry {
            cols: self.u16()?,
            rows: self.u16()?,
            cell_width: self.u16()?,
            cell_height: self.u16()?,
        })
    }

    fn rgb(&mut self) -> Result<Option<Rgb>, WireError> {
        let bytes = self.take(4)?;
        match bytes[0] {
            0 => Ok(None),
            1 => Ok(Some(Rgb { r: bytes[1], g: bytes[2], b: bytes[3] })),
            _ => Err(WireError::BadValue("color tag")),
        }
    }

    fn kitty_limits(&mut self) -> Result<KittyGraphicsLimits, WireError> {
        KittyGraphicsLimits {
            image_bytes: self.u64()?,
            inflight_bytes: self.u64()?,
            images: self.u64()?,
            placements: self.u64()?,
        }
        .validate()
        .map_err(|_| WireError::BadValue("kitty limits"))
    }

    /// `len u16 | UTF-8`, at most [`MAX_STATUS_TEXT`] bytes.
    fn status_text(&mut self) -> Result<String, WireError> {
        let len = usize::from(self.u16()?);
        if len > MAX_STATUS_TEXT {
            return Err(WireError::BadValue("status text length"));
        }
        let bytes = self.take(len)?;
        std::str::from_utf8(bytes)
            .map(str::to_owned)
            .map_err(|_| WireError::BadValue("status text UTF-8"))
    }

    fn program_status(&mut self) -> Result<ProgramStatusEvent, WireError> {
        if self.u8()? == 0 {
            return Ok(ProgramStatusEvent::PromptStart);
        }
        let state = match self.u8()? {
            0 => ProgramStatusState::Idle,
            1 => ProgramStatusState::Working,
            2 => ProgramStatusState::Done,
            3 => ProgramStatusState::Blocked,
            4 => ProgramStatusState::Error,
            5 => ProgramStatusState::Clear,
            _ => return Err(WireError::BadValue("status state")),
        };
        let kind = match self.u8()? {
            0 => None,
            1 => Some(ProgramStatusKind::Permission),
            2 => Some(ProgramStatusKind::Question),
            3 => Some(ProgramStatusKind::Auth),
            _ => return Err(WireError::BadValue("status kind")),
        };
        let progress = match self.u8()? {
            u8::MAX => None,
            progress @ 0..=100 => Some(progress),
            _ => return Err(WireError::BadValue("status progress")),
        };
        Ok(ProgramStatusEvent::Report(ProgramStatusReport {
            state,
            kind,
            progress,
            id: self.status_text()?,
            app: self.status_text()?,
            title: self.status_text()?,
            message: self.status_text()?,
        }))
    }

    fn rest(&mut self) -> &'a [u8] {
        std::mem::take(&mut self.bytes)
    }

    fn end(self) -> Result<(), WireError> {
        if self.bytes.is_empty() { Ok(()) } else { Err(WireError::Trailing { kind: self.kind }) }
    }
}

fn expect_fds(frame: &Frame, expected: usize) -> Result<(), WireError> {
    if frame.fds.len() == expected {
        Ok(())
    } else {
        Err(WireError::Descriptors { kind: frame.kind, expected, got: frame.fds.len() })
    }
}

/// Decode a daemon-to-worker frame.
pub fn decode_command(frame: Frame) -> Result<Command, WireError> {
    let kind = frame.kind;
    let mut p = Payload { kind, bytes: &frame.payload };
    let command = match kind {
        kind::BOOTSTRAP => {
            expect_fds(&frame, 0)?;
            match p.u8()? {
                0 => Command::Bootstrap(SandboxPolicy::Unsandboxed),
                1 => Command::Bootstrap(SandboxPolicy::Seatbelt(p.rest().to_vec())),
                _ => return Err(WireError::BadValue("sandbox policy")),
            }
        }
        kind::ATTACH => {
            expect_fds(&frame, 2)?;
            let (id, start, ring_capacity, page_len, scrollback) =
                (p.u64()?, p.u64()?, p.u64()?, p.u64()?, p.u64()?);
            let geometry = p.geometry()?;
            let kitty_limits = p.kitty_limits()?;
            p.end()?;
            let mut fds = frame.fds.into_iter();
            let (Some(ring), Some(page)) = (fds.next(), fds.next()) else {
                return Err(WireError::Descriptors { kind, expected: 2, got: 0 });
            };
            return Ok(Command::Attach(Attach {
                id,
                start,
                ring,
                ring_capacity,
                page,
                page_len,
                scrollback,
                geometry,
                kitty_limits,
            }));
        }
        kind::KITTY_LIMITS => {
            expect_fds(&frame, 0)?;
            Command::KittyLimits { id: p.u64()?, limits: p.kitty_limits()? }
        }
        kind::KITTY_MEDIA => {
            let id = p.u64()?;
            let outcome = p.u8()?;
            let len = p.u64()?;
            p.end()?;
            let answer = if outcome == 0 {
                if len > MAX_MEDIA_BYTES {
                    return Err(WireError::BadValue("kitty media length"));
                }
                expect_fds(&frame, usize::from(len != 0))?;
                MediaAnswer::Bytes { segment: frame.fds.into_iter().next(), len }
            } else {
                expect_fds(&frame, 0)?;
                if len != 0 {
                    return Err(WireError::BadValue("kitty media refusal length"));
                }
                MediaAnswer::Refused(
                    refusal_from(outcome).ok_or(WireError::BadValue("kitty media refusal"))?,
                )
            };
            return Ok(Command::KittyMedia { id, answer });
        }
        kind::ADVANCE => {
            expect_fds(&frame, 0)?;
            Command::Advance { id: p.u64()?, end: p.u64()? }
        }
        kind::RESIZE => {
            let id = p.u64()?;
            let geometry = p.geometry()?;
            let page_len = p.u64()?;
            p.end()?;
            expect_fds(&frame, usize::from(page_len != 0))?;
            let page = frame.fds.into_iter().next().map(|fd| (fd, page_len));
            return Ok(Command::Resize { id, geometry, page });
        }
        kind::COLORS => {
            expect_fds(&frame, 0)?;
            let id = p.u64()?;
            let (fg, bg, cursor) = (p.rgb()?, p.rgb()?, p.rgb()?);
            let cursor_style = match p.u8()? {
                0 => None,
                1 => Some(CursorShape::Bar),
                2 => Some(CursorShape::Block),
                3 => Some(CursorShape::Underline),
                4 => Some(CursorShape::BlockHollow),
                _ => return Err(WireError::BadValue("cursor style")),
            };
            let cursor_blink = match p.u8()? {
                0 => None,
                1 => Some(false),
                2 => Some(true),
                _ => return Err(WireError::BadValue("cursor blink")),
            };
            let mut palette = Box::new([None; 256]);
            for slot in palette.iter_mut() {
                *slot = p.rgb()?;
            }
            Command::Colors {
                id,
                colors: Colors { fg, bg, cursor, cursor_style, cursor_blink, palette },
            }
        }
        kind::DETACH => {
            expect_fds(&frame, 0)?;
            Command::Detach { id: p.u64()? }
        }
        other => return Err(WireError::UnknownKind(other)),
    };
    p.end()?;
    Ok(command)
}

/// Decode a worker-to-daemon frame. Events never carry descriptors.
pub fn decode_event(frame: Frame) -> Result<Event, WireError> {
    expect_fds(&frame, 0)?;
    let kind = frame.kind;
    let mut p = Payload { kind, bytes: &frame.payload };
    let event = match kind {
        kind::HELLO => Event::Hello {
            version: p.u16()?,
            sandbox: SandboxMechanism::from_wire(p.u8()?)
                .ok_or(WireError::BadValue("sandbox mechanism"))?,
            pid: p.u32()?,
        },
        kind::PARSED => Event::Parsed { id: p.u64()?, offset: p.u64()?, frame: p.u64()? },
        kind::PTY_WRITE => {
            let id = p.u64()?;
            let bytes = p.rest();
            if bytes.len() > MAX_EVENT_TEXT {
                return Err(WireError::BadValue("pty write length"));
            }
            Event::PtyWrite { id, bytes: bytes.to_vec() }
        }
        kind::TITLE | kind::PWD => {
            let id = p.u64()?;
            let bytes = p.rest();
            if bytes.len() > MAX_EVENT_TEXT {
                return Err(WireError::BadValue("text length"));
            }
            let text = std::str::from_utf8(bytes)
                .map_err(|_| WireError::BadValue("text UTF-8"))?
                .to_owned();
            if kind == kind::TITLE {
                Event::Title { id, title: text }
            } else {
                Event::Pwd { id, pwd: text }
            }
        }
        kind::BELL => Event::Bell { id: p.u64()?, count: p.u32()? },
        kind::LAPPED => Event::Lapped { id: p.u64()?, from: p.u64()?, oldest: p.u64()? },
        kind::PAGE_TOO_SMALL => Event::PageTooSmall { id: p.u64()?, needed: p.u64()? },
        kind::ATTACH_FAILED => Event::AttachFailed {
            id: p.u64()?,
            reason: AttachFailure::from_wire(p.u8()?)
                .ok_or(WireError::BadValue("attach failure"))?,
        },
        kind::PROGRAM_STATUS => Event::ProgramStatus { id: p.u64()?, event: p.program_status()? },
        kind::KITTY_MEDIA_REQUEST => {
            let id = p.u64()?;
            let medium = match p.u8()? {
                1 => FileMedium::File,
                2 => FileMedium::TempFile,
                3 => FileMedium::SharedMemory,
                _ => return Err(WireError::BadValue("kitty medium")),
            };
            let (offset, size) = (p.u64()?, p.u64()?);
            let name = p.rest();
            if name.len() > MAX_MEDIA_NAME {
                return Err(WireError::BadValue("kitty media name length"));
            }
            Event::KittyMediaRequest {
                id,
                request: MediaRequest { medium, name: name.to_vec(), offset, size },
            }
        }
        other => return Err(WireError::UnknownKind(other)),
    };
    p.end()?;
    Ok(event)
}

#[cfg(test)]
#[path = "wire_tests.rs"]
mod tests;
