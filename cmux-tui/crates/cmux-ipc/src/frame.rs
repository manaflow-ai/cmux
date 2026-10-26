//! The 16-byte frame header, the frame kinds and the typed `BadMessage`
//! (plans/cmux-next/chrome-parity/p05-ipc.md, section 3.2).
//!
//! Layout, little endian:
//!
//! ```text
//! byte  0      magic 0xFF (never the first byte of a UTF-8 JSON line)
//! byte  1      kind
//! bytes 2..4   stream (u16)
//! bytes 4..8   payload length (u32, <= MAX_FRAME_PAYLOAD)
//! bytes 8..16  aux (u64): its meaning depends on the kind
//! ```
//!
//! Call kinds (REQUEST, REPLY, ERROR, TYPED_EVENT, CANCEL) split aux into
//! `request id u32 | method id u16 | priority hint u8 | flags u8`, in that
//! order from byte 8. Every other kind carries one u64 value.
//!
//! Like Mojo's `Channel::Message::Deserialize` (chromium
//! mojo/core/channel.cc), the header is validated before any payload byte is
//! read or allocated, and a header that fails validation is a bad message,
//! never a best-effort parse.

use std::fmt;

use bytes::{BufMut, Bytes, BytesMut};

/// First byte of every frame. 0xFF never starts (or appears in) UTF-8 text,
/// so a reader at a message boundary tells a frame from a JSON line by it.
pub const MAGIC: u8 = 0xFF;

/// Length of the fixed header that precedes every frame payload.
pub const HEADER_LEN: usize = 16;

/// Largest payload a frame may declare: 32 MiB, the daemon's existing
/// server-to-client remote session message budget (spec/transports.md).
pub const MAX_FRAME_PAYLOAD: u32 = 32 * 1024 * 1024;

/// What a frame carries. Values are wire values and are append-only.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum FrameKind {
    /// Terminal output bytes; aux is the absolute PTY offset of byte 0.
    Output = 1,
    /// Rendered grid update; aux is the PTY offset it reflects.
    Grid = 2,
    /// Stream event (title, bell, exit); aux is the PTY offset it follows.
    Event = 3,
    /// First chunk of a terminal snapshot; aux is the PTY offset it covers.
    Snapshot = 4,
    /// A continuation chunk of the snapshot opened by `Snapshot`.
    SnapshotMore = 5,
    /// Replayed output since a resume offset; aux is the PTY offset.
    Replay = 6,
    /// Shared output ring announcement; aux is the PTY offset at its start.
    Ring = 7,
    /// The ring's writer advanced; aux is the new end PTY offset.
    RingAdvance = 8,
    /// Terminal input bytes; aux is the flow id that joins traces.
    Input = 9,
    /// A pooled shared buffer; aux is the size of the attached fd.
    SharedBuffer = 10,
    /// The reader's consumer cursor; aux is the parsed PTY offset.
    RingAck = 11,
    /// A method call.
    Request = 16,
    /// The successful reply to a `Request`.
    Reply = 17,
    /// The failed reply to a `Request`.
    Error = 18,
    /// A typed event on the stream's sequence.
    TypedEvent = 19,
    /// Cancels the in-flight request named by the request id.
    Cancel = 20,
}

impl FrameKind {
    /// Every kind, in wire order.
    pub const ALL: [FrameKind; 16] = [
        FrameKind::Output,
        FrameKind::Grid,
        FrameKind::Event,
        FrameKind::Snapshot,
        FrameKind::SnapshotMore,
        FrameKind::Replay,
        FrameKind::Ring,
        FrameKind::RingAdvance,
        FrameKind::Input,
        FrameKind::SharedBuffer,
        FrameKind::RingAck,
        FrameKind::Request,
        FrameKind::Reply,
        FrameKind::Error,
        FrameKind::TypedEvent,
        FrameKind::Cancel,
    ];

    /// The kind with wire value `value`, if any.
    pub fn from_wire(value: u8) -> Option<FrameKind> {
        FrameKind::ALL.into_iter().find(|kind| kind.wire() == value)
    }

    /// The wire value.
    pub fn wire(self) -> u8 {
        self as u8
    }

    /// Stable lowercase name, used by fixtures and close reasons.
    pub fn name(self) -> &'static str {
        match self {
            FrameKind::Output => "output",
            FrameKind::Grid => "grid",
            FrameKind::Event => "event",
            FrameKind::Snapshot => "snapshot",
            FrameKind::SnapshotMore => "snapshot_more",
            FrameKind::Replay => "replay",
            FrameKind::Ring => "ring",
            FrameKind::RingAdvance => "ring_advance",
            FrameKind::Input => "input",
            FrameKind::SharedBuffer => "shared_buffer",
            FrameKind::RingAck => "ring_ack",
            FrameKind::Request => "request",
            FrameKind::Reply => "reply",
            FrameKind::Error => "error",
            FrameKind::TypedEvent => "typed_event",
            FrameKind::Cancel => "cancel",
        }
    }

    /// Which `Aux` variant this kind carries.
    pub fn aux_class(self) -> AuxClass {
        match self {
            FrameKind::Output
            | FrameKind::Grid
            | FrameKind::Event
            | FrameKind::Snapshot
            | FrameKind::SnapshotMore
            | FrameKind::Replay
            | FrameKind::Ring
            | FrameKind::RingAdvance
            | FrameKind::RingAck => AuxClass::Offset,
            FrameKind::Input => AuxClass::FlowId,
            FrameKind::SharedBuffer => AuxClass::SharedBufferSize,
            FrameKind::Request
            | FrameKind::Reply
            | FrameKind::Error
            | FrameKind::TypedEvent
            | FrameKind::Cancel => AuxClass::Call,
        }
    }

    /// Terminal stream data belongs to a client-minted stream; stream 0 is
    /// the connection's control sequence and never carries it.
    pub fn needs_data_stream(self) -> bool {
        !matches!(self.aux_class(), AuxClass::Call) && self != FrameKind::SharedBuffer
    }
}

/// The meaning of a kind's aux word.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuxClass {
    /// An absolute PTY byte offset.
    Offset,
    /// A trace flow id.
    FlowId,
    /// The byte size of the attached shared-buffer fd.
    SharedBufferSize,
    /// The call fields of `CallAux`.
    Call,
}

/// The priority the sender suggests. The daemon takes the priority from its
/// own method table and treats a differing hint as a bad message.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum PriorityHint {
    Input = 0,
    Control = 1,
    Bulk = 2,
    Background = 3,
}

impl PriorityHint {
    /// Every hint, in wire order.
    pub const ALL: [PriorityHint; 4] =
        [PriorityHint::Input, PriorityHint::Control, PriorityHint::Bulk, PriorityHint::Background];

    /// The hint with wire value `value`, if any.
    pub fn from_wire(value: u8) -> Option<PriorityHint> {
        PriorityHint::ALL.into_iter().find(|hint| hint.wire() == value)
    }

    /// The wire value.
    pub fn wire(self) -> u8 {
        self as u8
    }
}

/// The flags byte of a call frame.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct CallFlags(u8);

impl CallFlags {
    /// The payload is the method's binary layout, not JSON.
    pub const BINARY: CallFlags = CallFlags(1 << 0);
    /// File descriptors ride with this frame.
    pub const FDS: CallFlags = CallFlags(1 << 1);
    /// The frame carries a trace flow.
    pub const FLOW: CallFlags = CallFlags(1 << 2);
    /// The sender asks for the urgent path the method table allows.
    pub const URGENT: CallFlags = CallFlags(1 << 3);
    /// More chunks of this message follow: the bulk preemption boundary.
    pub const MORE: CallFlags = CallFlags(1 << 4);
    /// Every defined bit; any other bit is a bad message.
    pub const KNOWN: CallFlags = CallFlags(0b1_1111);

    /// No flags.
    pub const fn empty() -> CallFlags {
        CallFlags(0)
    }

    /// Flags from a wire byte, refusing undefined bits.
    pub fn from_wire(bits: u8) -> Option<CallFlags> {
        (bits & !CallFlags::KNOWN.0 == 0).then_some(CallFlags(bits))
    }

    /// The wire byte.
    pub const fn bits(self) -> u8 {
        self.0
    }

    /// Whether every flag in `other` is set.
    pub const fn contains(self, other: CallFlags) -> bool {
        self.0 & other.0 == other.0
    }

    /// `self` with `other` added.
    pub const fn with(self, other: CallFlags) -> CallFlags {
        CallFlags(self.0 | other.0)
    }

    /// `self` with `other` removed.
    pub const fn without(self, other: CallFlags) -> CallFlags {
        CallFlags(self.0 & !other.0)
    }
}

/// The aux fields of a call frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CallAux {
    /// Per-connection id, unique among in-flight requests; wraps at u32::MAX.
    pub request_id: u32,
    /// `family << 8 | ordinal` from the schema's method table.
    pub method_id: u16,
    pub priority: PriorityHint,
    pub flags: CallFlags,
}

/// The aux word, typed by the frame's kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Aux {
    Offset(u64),
    FlowId(u64),
    SharedBufferSize(u64),
    Call(CallAux),
}

impl Aux {
    fn class(self) -> AuxClass {
        match self {
            Aux::Offset(_) => AuxClass::Offset,
            Aux::FlowId(_) => AuxClass::FlowId,
            Aux::SharedBufferSize(_) => AuxClass::SharedBufferSize,
            Aux::Call(_) => AuxClass::Call,
        }
    }

    fn to_wire(self) -> [u8; 8] {
        match self {
            Aux::Offset(value) | Aux::FlowId(value) | Aux::SharedBufferSize(value) => {
                value.to_le_bytes()
            }
            Aux::Call(call) => {
                let [i0, i1, i2, i3] = call.request_id.to_le_bytes();
                let [m0, m1] = call.method_id.to_le_bytes();
                [i0, i1, i2, i3, m0, m1, call.priority.wire(), call.flags.bits()]
            }
        }
    }

    fn from_wire(class: AuxClass, bytes: [u8; 8]) -> Result<Aux, BadMessage> {
        let value = u64::from_le_bytes(bytes);
        Ok(match class {
            AuxClass::Offset => Aux::Offset(value),
            AuxClass::FlowId => Aux::FlowId(value),
            AuxClass::SharedBufferSize => Aux::SharedBufferSize(value),
            AuxClass::Call => {
                let [i0, i1, i2, i3, m0, m1, priority, flags] = bytes;
                Aux::Call(CallAux {
                    request_id: u32::from_le_bytes([i0, i1, i2, i3]),
                    method_id: u16::from_le_bytes([m0, m1]),
                    priority: PriorityHint::from_wire(priority)
                        .ok_or(BadMessage::UnknownPriority { hint: priority })?,
                    flags: CallFlags::from_wire(flags).ok_or(BadMessage::UnknownFlags { flags })?,
                })
            }
        })
    }
}

/// A validated frame header. Construction and decoding enforce the same
/// rules, so an encoder never emits what a reader refuses.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FrameHeader {
    kind: FrameKind,
    stream: u16,
    len: u32,
    aux: Aux,
}

impl FrameHeader {
    /// A header for a `len`-byte payload.
    pub fn new(
        kind: FrameKind,
        stream: u16,
        len: u32,
        aux: Aux,
    ) -> Result<FrameHeader, BadMessage> {
        Self::validated(kind, stream, len, aux, MAX_FRAME_PAYLOAD)
    }

    fn validated(
        kind: FrameKind,
        stream: u16,
        len: u32,
        aux: Aux,
        max_payload: u32,
    ) -> Result<FrameHeader, BadMessage> {
        if len > max_payload {
            return Err(BadMessage::Oversize { len, max: max_payload });
        }
        if aux.class() != kind.aux_class() {
            return Err(BadMessage::AuxMismatch { kind });
        }
        if stream == 0 && kind.needs_data_stream() {
            return Err(BadMessage::DataOnControlStream { kind });
        }
        Ok(FrameHeader { kind, stream, len, aux })
    }

    /// Decodes and validates a header against a payload limit at most
    /// `MAX_FRAME_PAYLOAD` (a smaller limit is a peer-specific budget).
    pub fn decode(bytes: [u8; HEADER_LEN], max_payload: u32) -> Result<FrameHeader, BadMessage> {
        let [magic, kind, s0, s1, l0, l1, l2, l3, a0, a1, a2, a3, a4, a5, a6, a7] = bytes;
        if magic != MAGIC {
            return Err(BadMessage::BadMagic { found: magic });
        }
        let kind = FrameKind::from_wire(kind).ok_or(BadMessage::UnknownKind { kind })?;
        let len = u32::from_le_bytes([l0, l1, l2, l3]);
        let max_payload = max_payload.min(MAX_FRAME_PAYLOAD);
        if len > max_payload {
            // Refuse the size before the aux, so an oversize claim never
            // costs more than these 16 bytes.
            return Err(BadMessage::Oversize { len, max: max_payload });
        }
        let aux = Aux::from_wire(kind.aux_class(), [a0, a1, a2, a3, a4, a5, a6, a7])?;
        Self::validated(kind, u16::from_le_bytes([s0, s1]), len, aux, max_payload)
    }

    /// The 16 wire bytes.
    pub fn encode(&self) -> [u8; HEADER_LEN] {
        let [s0, s1] = self.stream.to_le_bytes();
        let [l0, l1, l2, l3] = self.len.to_le_bytes();
        let [a0, a1, a2, a3, a4, a5, a6, a7] = self.aux.to_wire();
        [MAGIC, self.kind.wire(), s0, s1, l0, l1, l2, l3, a0, a1, a2, a3, a4, a5, a6, a7]
    }

    pub fn kind(&self) -> FrameKind {
        self.kind
    }

    pub fn stream(&self) -> u16 {
        self.stream
    }

    /// Declared payload length in bytes.
    pub fn len(&self) -> u32 {
        self.len
    }

    /// Whether the payload is empty (a CANCEL, a RING_ACK).
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn aux(&self) -> Aux {
        self.aux
    }

    /// The call fields, for call kinds.
    pub fn call(&self) -> Option<CallAux> {
        match self.aux {
            Aux::Call(call) => Some(call),
            Aux::Offset(_) | Aux::FlowId(_) | Aux::SharedBufferSize(_) => None,
        }
    }

    /// Payload length plus the header, as a buffer size.
    pub fn frame_len(&self) -> usize {
        HEADER_LEN.saturating_add(usize::try_from(self.len).unwrap_or(usize::MAX))
    }
}

/// One frame: its header and its payload, which shares the reader's buffer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    header: FrameHeader,
    payload: Bytes,
}

impl Frame {
    /// A frame whose header length comes from `payload`.
    pub fn new(
        kind: FrameKind,
        stream: u16,
        aux: Aux,
        payload: Bytes,
    ) -> Result<Frame, BadMessage> {
        let len = u32::try_from(payload.len())
            .map_err(|_| BadMessage::Oversize { len: u32::MAX, max: MAX_FRAME_PAYLOAD })?;
        Ok(Frame { header: FrameHeader::new(kind, stream, len, aux)?, payload })
    }

    /// Pairs a decoded header with its payload; the lengths must agree.
    pub(crate) fn from_parts(header: FrameHeader, payload: Bytes) -> Result<Frame, BadMessage> {
        let need = usize::try_from(header.len).unwrap_or(usize::MAX);
        if payload.len() != need {
            return Err(BadMessage::Truncated { have: payload.len(), need });
        }
        Ok(Frame { header, payload })
    }

    pub fn header(&self) -> &FrameHeader {
        &self.header
    }

    pub fn payload(&self) -> &Bytes {
        &self.payload
    }

    pub fn into_payload(self) -> Bytes {
        self.payload
    }

    /// Appends header and payload to `out`.
    pub fn encode_into(&self, out: &mut BytesMut) {
        out.reserve(self.header.frame_len());
        out.put_slice(&self.header.encode());
        out.put_slice(&self.payload);
    }
}

/// Why a peer's bytes were refused. The connection that receives one closes
/// with `bad_message` and `reason()`, as Chrome's ReportBadMessage
/// (chromium mojo/public/cpp/bindings/message.h) ends the sender; nothing
/// after the bad byte is interpreted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BadMessage {
    /// A header whose first byte is not `MAGIC`.
    BadMagic { found: u8 },
    /// A kind byte with no `FrameKind`.
    UnknownKind { kind: u8 },
    /// A payload length above the limit.
    Oversize { len: u32, max: u32 },
    /// The aux variant does not belong to the kind (encoder side).
    AuxMismatch { kind: FrameKind },
    /// Terminal stream data addressed to stream 0.
    DataOnControlStream { kind: FrameKind },
    /// A call frame's priority hint has no `PriorityHint`.
    UnknownPriority { hint: u8 },
    /// A call frame sets a flag bit outside `CallFlags::KNOWN`.
    UnknownFlags { flags: u8 },
    /// A frame arrived on a connection that has not negotiated frames.
    FramesNotNegotiated,
    /// A JSON line longer than the limit, delimiter excluded.
    LineTooLong { max: usize },
    /// A JSON line that is not UTF-8.
    InvalidUtf8 { valid_up_to: usize },
    /// The peer closed inside a frame.
    Truncated { have: usize, need: usize },
}

impl BadMessage {
    /// Stable machine-readable reason for the close and for logs.
    pub fn reason(&self) -> &'static str {
        match self {
            BadMessage::BadMagic { .. } => "bad_magic",
            BadMessage::UnknownKind { .. } => "unknown_kind",
            BadMessage::Oversize { .. } => "oversize",
            BadMessage::AuxMismatch { .. } => "aux_mismatch",
            BadMessage::DataOnControlStream { .. } => "data_on_control_stream",
            BadMessage::UnknownPriority { .. } => "unknown_priority",
            BadMessage::UnknownFlags { .. } => "unknown_flags",
            BadMessage::FramesNotNegotiated => "frames_not_negotiated",
            BadMessage::LineTooLong { .. } => "line_too_long",
            BadMessage::InvalidUtf8 { .. } => "invalid_utf8",
            BadMessage::Truncated { .. } => "truncated",
        }
    }
}

impl fmt::Display for BadMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BadMessage::BadMagic { found } => write!(f, "frame magic {found:#04x}, expected 0xff"),
            BadMessage::UnknownKind { kind } => write!(f, "unknown frame kind {kind}"),
            BadMessage::Oversize { len, max } => {
                write!(f, "frame payload of {len} bytes exceeds {max}")
            }
            BadMessage::AuxMismatch { kind } => {
                write!(f, "aux does not match frame kind {}", kind.name())
            }
            BadMessage::DataOnControlStream { kind } => {
                write!(f, "{} frame on control stream 0", kind.name())
            }
            BadMessage::UnknownPriority { hint } => write!(f, "unknown priority hint {hint}"),
            BadMessage::UnknownFlags { flags } => write!(f, "undefined call flags {flags:#010b}"),
            BadMessage::FramesNotNegotiated => write!(f, "frame before frames were negotiated"),
            BadMessage::LineTooLong { max } => write!(f, "JSON line exceeds {max} bytes"),
            BadMessage::InvalidUtf8 { valid_up_to } => {
                write!(f, "JSON line is not UTF-8 after byte {valid_up_to}")
            }
            BadMessage::Truncated { have, need } => {
                write!(f, "connection closed inside a frame ({have} of {need} bytes)")
            }
        }
    }
}

impl std::error::Error for BadMessage {}
