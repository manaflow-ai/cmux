//! Binary framing for the local terminal-host data plane.
//!
//! The public cmux-tui control protocol remains JSON. This framing is for
//! bounded, local Unix-socket streams between a terminal host, its daemon,
//! and disposable renderers. The header is deliberately fixed-width and
//! little-endian so non-Rust clients can implement it without sharing a
//! serializer or ABI.

use std::fmt;
use std::io::{self, Read, Write};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub const MAGIC: [u8; 4] = *b"CMTH";
pub const HEADER_LEN: usize = 32;
pub const PROTOCOL_VERSION: u16 = 4;
pub const LAUNCH_ACTIVATION_PROTOCOL_VERSION: u16 = 4;
pub const MAX_FRAME_PAYLOAD: usize = 16 * 1024 * 1024;
pub const MAX_KITTY_IMAGE_ALIASES: usize = 4_096;
pub const KITTY_IMAGE_ALIAS_COUNT_LEN: usize = size_of::<u16>();
pub const KITTY_IMAGE_ALIAS_ENCODED_LEN: usize = 2 * size_of::<u32>();
const EXIT_PAYLOAD_VERSION: u16 = 1;
const EXIT_PAYLOAD_HEADER_LEN: usize = 12;
const EXIT_PAYLOAD_STATUS_LEN: usize = EXIT_PAYLOAD_HEADER_LEN + 4;
pub const MAX_EXIT_REASON_BYTES: usize = 4096;
const LAUNCH_FAILURE_PAYLOAD_VERSION: u16 = 1;
const LAUNCH_FAILURE_PAYLOAD_HEADER_LEN: usize = 2 * size_of::<u16>();
pub const MAX_LAUNCH_FAILURE_MESSAGE_BYTES: usize = 4096;
/// The live Output or Resized payload is not independently renderable. Its
/// immediately following sequenced frame must be Colors, and consumers must
/// apply both before publishing terminal state.
pub const FLAG_COLORS_FOLLOW: u32 = 1 << 0;
/// ClientHello opt-in and HostHello acknowledgement for targeted ViewerSize
/// control responses. This handshake-only flag lets compatible peers negotiate the
/// optimization without exposing an unknown ResizeAck to legacy renderers.
pub const FLAG_VIEWER_SIZE_ACKS: u32 = 1 << 1;
/// ClientHello opt-in and HostHello acknowledgement for the smart terminal
/// stream. Smart clients receive an explicit Snapshot/Colors/Ready barrier,
/// followed by retained and live raw PTY Output frames from a source cursor
/// that is independent of the authoritative host parser's cursor. Their
/// Resized payload is cols:u16 + rows:u16, optionally followed by cell pixel
/// width:u16 + height:u16, and carries no Colors pair.
///
/// Legacy renderers do not set this bit and retain the existing normalized,
/// parser-ordered stream and coupled color semantics.
pub const FLAG_SMART_RENDERER: u32 = 1 << 2;
/// Protocol-v4 HostHello flag. The authenticated launch-owner connection must
/// send `Activate` after its daemon has durably committed public topology.
pub const FLAG_LAUNCH_ACTIVATION_REQUIRED: u32 = 1 << 3;
/// ResizeAck payload flag: this request changed the canonical grid and its
/// sequenced Resized+Colors transition was enqueued immediately before the
/// targeted acknowledgement.
pub const RESIZE_ACK_CANONICAL_CHANGED: u32 = 1 << 0;
/// `ClearHistoryAck` status: the host applied the emulator clear or wrote the
/// alternate-screen fallback key before acknowledging the request.
pub const CLEAR_HISTORY_ACK_OK: u8 = 0;
/// `ClearHistoryAck` status: active input reached retained history, so the host
/// made no emulator or PTY change.
pub const CLEAR_HISTORY_ACK_PRESERVATION_FAILED: u8 = 1;
/// Backward source alias for the original undifferentiated failure status.
pub const CLEAR_HISTORY_ACK_FAILED: u8 = CLEAR_HISTORY_ACK_PRESERVATION_FAILED;
/// `ClearHistoryAck` status: output did not reach a safe parser boundary before
/// the bounded wait expired, so the host made no emulator or PTY change.
pub const CLEAR_HISTORY_ACK_STREAM_TIMEOUT: u8 = 2;
/// `ClearHistoryAck` status: the alternate-screen fallback key could not be
/// encoded, so the host made no emulator or PTY change.
pub const CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE: u8 = 3;
/// `ClearHistoryAck` status: another validated pre-execution failure occurred.
pub const CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED: u8 = 4;
/// `ClearHistoryAck` status: a PTY write or flush failed after delivery may
/// have begun.
pub const CLEAR_HISTORY_ACK_AMBIGUOUS: u8 = 5;
/// `ClearHistoryAck` status: the PTY accepted no fallback bytes before the
/// bounded write deadline expired.
pub const CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT: u8 = 6;

/// Authoritative process completion as retained by the terminal host.
///
/// This is also the durable public outcome union. Keep the tagged JSON shape
/// strict so sidecar recovery, terminal snapshots, session events, and
/// `terminal.wait_exit` cannot disagree about success or signal semantics.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum TerminalExitOutcome {
    Exit { code: i32 },
    Signal { signal: i32, core_dumped: bool },
    Unknown { reason: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalExit {
    pub outcome: TerminalExitOutcome,
    pub exited_at_ms: u64,
}

impl TerminalExit {
    pub fn from_exit_status(status: &std::process::ExitStatus) -> Self {
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt;

            if let Some(signal) = status.signal() {
                return Self::now(TerminalExitOutcome::Signal {
                    signal,
                    core_dumped: status.core_dumped(),
                });
            }
        }

        match status.code() {
            Some(code) => Self::now(TerminalExitOutcome::Exit { code }),
            None => Self::unknown("process ended without an exit code or signal"),
        }
    }

    pub fn unknown(reason: impl Into<String>) -> Self {
        let mut reason = reason.into();
        if reason.is_empty() {
            reason = "terminal exit outcome is unavailable".to_string();
        }
        truncate_utf8(&mut reason, MAX_EXIT_REASON_BYTES);
        Self::now(TerminalExitOutcome::Unknown { reason })
    }

    pub fn now(outcome: TerminalExitOutcome) -> Self {
        let exited_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64;
        Self { outcome, exited_at_ms }
    }

    pub(crate) fn is_valid(&self) -> bool {
        match &self.outcome {
            TerminalExitOutcome::Exit { code } => *code >= 0,
            TerminalExitOutcome::Signal { signal, .. } => *signal > 0,
            TerminalExitOutcome::Unknown { reason } => {
                !reason.is_empty() && reason.len() <= MAX_EXIT_REASON_BYTES
            }
        }
    }
}

/// Wait for the native child hidden behind cmux-pty without collapsing Unix
/// signal/core information into its display-only fallback status.
///
/// cmux-pty's Unix backend returns `std::process::Child`, so failure to downcast
/// is an alternate backend and becomes an explicit unknown outcome.
pub(crate) fn wait_for_native_child_status(
    child: &mut (dyn cmux_pty::Child + Send + Sync),
) -> TerminalExit {
    let child: &mut dyn cmux_pty::Child = child;
    if let Some(child) = child.downcast_mut::<std::process::Child>() {
        return match child.wait() {
            Ok(status) => TerminalExit::from_exit_status(&status),
            Err(error) => TerminalExit::unknown(format!("wait failed: {error}")),
        };
    }
    match child.wait() {
        Ok(status) if status.signal().is_some() => {
            TerminalExit::unknown(format!("numeric signal status unavailable: {status}"))
        }
        Ok(status) => match i32::try_from(status.exit_code()) {
            Ok(code) => TerminalExit::now(TerminalExitOutcome::Exit { code }),
            Err(_) => TerminalExit::unknown(format!(
                "portable exit code exceeds signed 32-bit range: {}",
                status.exit_code()
            )),
        },
        Err(error) => TerminalExit::unknown(format!("wait failed: {error}")),
    }
}

fn truncate_utf8(value: &mut String, max_bytes: usize) {
    if value.len() <= max_bytes {
        return;
    }
    let mut boundary = max_bytes;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value.truncate(boundary);
}

/// Exit payload layout is version:u16, outcome_kind:u8, flags:u8,
/// exited_at_ms:u64, then code/signal:i32 or UTF-8 reason bytes. Signal flag
/// bit zero is `core_dumped`; all other flags are reserved and must be zero.
pub fn encode_terminal_exit(exit: &TerminalExit) -> Vec<u8> {
    let reason_len = match &exit.outcome {
        TerminalExitOutcome::Unknown { reason } => reason.len().min(MAX_EXIT_REASON_BYTES),
        TerminalExitOutcome::Exit { .. } | TerminalExitOutcome::Signal { .. } => 4,
    };
    let mut payload = Vec::with_capacity(EXIT_PAYLOAD_HEADER_LEN + reason_len);
    payload.extend_from_slice(&EXIT_PAYLOAD_VERSION.to_le_bytes());
    match &exit.outcome {
        TerminalExitOutcome::Exit { code } => {
            payload.extend_from_slice(&[1, 0]);
            payload.extend_from_slice(&exit.exited_at_ms.to_le_bytes());
            payload.extend_from_slice(&code.to_le_bytes());
        }
        TerminalExitOutcome::Signal { signal, core_dumped } => {
            payload.extend_from_slice(&[2, u8::from(*core_dumped)]);
            payload.extend_from_slice(&exit.exited_at_ms.to_le_bytes());
            payload.extend_from_slice(&signal.to_le_bytes());
        }
        TerminalExitOutcome::Unknown { reason } => {
            payload.extend_from_slice(&[3, 0]);
            payload.extend_from_slice(&exit.exited_at_ms.to_le_bytes());
            let mut reason = reason.clone();
            truncate_utf8(&mut reason, MAX_EXIT_REASON_BYTES);
            payload.extend_from_slice(reason.as_bytes());
        }
    }
    payload
}

pub fn decode_terminal_exit(payload: &[u8]) -> Result<TerminalExit, ProtocolError> {
    if payload.len() < EXIT_PAYLOAD_HEADER_LEN {
        return Err(ProtocolError::MalformedExitPayload);
    }
    let version = u16::from_le_bytes(payload[0..2].try_into().expect("fixed exit-version slice"));
    if version != EXIT_PAYLOAD_VERSION {
        return Err(ProtocolError::MalformedExitPayload);
    }
    let kind = payload[2];
    let flags = payload[3];
    let exited_at_ms =
        u64::from_le_bytes(payload[4..12].try_into().expect("fixed exit-timestamp slice"));
    let outcome = match kind {
        1 if flags == 0 && payload.len() == EXIT_PAYLOAD_STATUS_LEN => {
            let code =
                i32::from_le_bytes(payload[12..16].try_into().expect("fixed exit-code slice"));
            if code < 0 {
                return Err(ProtocolError::MalformedExitPayload);
            }
            TerminalExitOutcome::Exit { code }
        }
        2 if flags & !1 == 0 && payload.len() == EXIT_PAYLOAD_STATUS_LEN => {
            let signal =
                i32::from_le_bytes(payload[12..16].try_into().expect("fixed exit-signal slice"));
            if signal <= 0 {
                return Err(ProtocolError::MalformedExitPayload);
            }
            TerminalExitOutcome::Signal { signal, core_dumped: flags & 1 != 0 }
        }
        3 if flags == 0
            && payload.len() > EXIT_PAYLOAD_HEADER_LEN
            && payload.len() <= EXIT_PAYLOAD_HEADER_LEN + MAX_EXIT_REASON_BYTES =>
        {
            let reason = std::str::from_utf8(&payload[12..])
                .map_err(|_| ProtocolError::MalformedExitPayload)?
                .to_string();
            TerminalExitOutcome::Unknown { reason }
        }
        _ => return Err(ProtocolError::MalformedExitPayload),
    };
    Ok(TerminalExit { outcome, exited_at_ms })
}

/// Machine-readable category for a terminal host that could not publish a
/// launched PTY.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum HostLaunchFailureKind {
    PtyCapacityExhausted = 1,
    LaunchFailed = 2,
}

impl HostLaunchFailureKind {
    pub const fn reason_code(self) -> &'static str {
        match self {
            Self::PtyCapacityExhausted => "pty_capacity_exhausted",
            Self::LaunchFailed => "terminal_launch_failed",
        }
    }
}

impl TryFrom<u16> for HostLaunchFailureKind {
    type Error = ProtocolError;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            value if value == Self::PtyCapacityExhausted as u16 => Ok(Self::PtyCapacityExhausted),
            value if value == Self::LaunchFailed as u16 => Ok(Self::LaunchFailed),
            _ => Err(ProtocolError::MalformedLaunchFailurePayload),
        }
    }
}

/// Bounded launch failure returned on the bootstrap pipe before the hidden
/// host exits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostLaunchFailure {
    pub kind: HostLaunchFailureKind,
    pub message: String,
}

impl HostLaunchFailure {
    pub fn bounded(kind: HostLaunchFailureKind, mut message: String) -> Self {
        if message.len() > MAX_LAUNCH_FAILURE_MESSAGE_BYTES {
            let mut end = MAX_LAUNCH_FAILURE_MESSAGE_BYTES;
            while !message.is_char_boundary(end) {
                end -= 1;
            }
            message.truncate(end);
        }
        Self { kind, message }
    }
}

impl fmt::Display for HostLaunchFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for HostLaunchFailure {}

pub fn encode_host_launch_failure(failure: &HostLaunchFailure) -> Result<Vec<u8>, ProtocolError> {
    if failure.message.is_empty() || failure.message.len() > MAX_LAUNCH_FAILURE_MESSAGE_BYTES {
        return Err(ProtocolError::MalformedLaunchFailurePayload);
    }
    let mut payload = Vec::with_capacity(LAUNCH_FAILURE_PAYLOAD_HEADER_LEN + failure.message.len());
    payload.extend_from_slice(&LAUNCH_FAILURE_PAYLOAD_VERSION.to_le_bytes());
    payload.extend_from_slice(&(failure.kind as u16).to_le_bytes());
    payload.extend_from_slice(failure.message.as_bytes());
    Ok(payload)
}

pub fn decode_host_launch_failure(payload: &[u8]) -> Result<HostLaunchFailure, ProtocolError> {
    if !(LAUNCH_FAILURE_PAYLOAD_HEADER_LEN + 1
        ..=LAUNCH_FAILURE_PAYLOAD_HEADER_LEN + MAX_LAUNCH_FAILURE_MESSAGE_BYTES)
        .contains(&payload.len())
    {
        return Err(ProtocolError::MalformedLaunchFailurePayload);
    }
    let version = u16::from_le_bytes(payload[0..2].try_into().expect("fixed version slice"));
    if version != LAUNCH_FAILURE_PAYLOAD_VERSION {
        return Err(ProtocolError::MalformedLaunchFailurePayload);
    }
    let kind = HostLaunchFailureKind::try_from(u16::from_le_bytes(
        payload[2..4].try_into().expect("fixed kind slice"),
    ))?;
    let message = std::str::from_utf8(&payload[LAUNCH_FAILURE_PAYLOAD_HEADER_LEN..])
        .map_err(|_| ProtocolError::MalformedLaunchFailurePayload)?
        .to_string();
    Ok(HostLaunchFailure { kind, message })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum MessageKind {
    Bootstrap = 1,
    Ready = 2,
    ClientHello = 3,
    HostHello = 4,
    Snapshot = 5,
    Output = 6,
    Resized = 7,
    Colors = 8,
    Title = 9,
    Pwd = 10,
    Bell = 11,
    Exit = 12,
    ResyncRequired = 13,
    Launch = 14,
    /// Response to `MintCapability`; payload is one 32-byte capability.
    Capability = 15,
    /// Targeted response to an acknowledged `ViewerSize`; payload is
    /// canonical cols:u16 + rows:u16 + result_flags:u32.
    ResizeAck = 16,
    /// Targeted response to `ClearHistory`; payload is one status byte.
    ClearHistoryAck = 17,
    /// Targeted response to `SetCellPixelSize`; payload is the committed
    /// cell width:u16 + height:u16.
    CellPixelSizeAck = 18,
    /// Targeted response to `SetKittyGraphicsLimits`; payload is the applied
    /// four-field resource limit tuple.
    KittyGraphicsLimitsAck = 19,
    /// Bootstrap-pipe response when the host could not create its PTY or
    /// child. The bounded UTF-8 payload preserves the owning process's error
    /// instead of making the launcher infer failure from EOF.
    LaunchFailed = 20,
    /// Targeted confirmation that `Terminate` reached the authoritative host.
    /// The PTY group shutdown continues asynchronously after this receipt.
    TerminateAck = 21,
    /// Targeted source fence for a daemon that will detach from a persistent
    /// host. Every live frame admitted before this receipt is queued before it,
    /// and this client is removed from live publication before the receipt.
    DetachAck = 22,
    Input = 100,
    Paste = 101,
    ViewerSize = 102,
    ReleaseViewer = 103,
    Terminate = 104,
    /// Admin request: little-endian rights:u32 + ttl_ms:u32.
    MintCapability = 105,
    /// Admin request: complete encoded Ghostty frontend defaults. New hosts
    /// advertise support in their durable discovery record.
    SetDefaults = 106,
    /// Input-authorized request: clear retained primary-screen history in the
    /// authoritative parser, or encode the optional key on the alternate
    /// screen. New hosts advertise support in their durable discovery record.
    ClearHistory = 107,
    /// Protocol-v2 admin request: cell width:u16 + height:u16. The host
    /// commits both its PTY and authoritative Ghostty parser before replying.
    SetCellPixelSize = 108,
    /// Protocol-v3 admin request: image bytes, in-flight bytes, image count,
    /// and placement count as four little-endian u64 values.
    SetKittyGraphicsLimits = 109,
    /// Protocol-v4 launch-owner request. A newly launched host keeps its PTY
    /// reader behind a bounded kernel-buffer barrier until the daemon has
    /// durably committed the terminal's public topology.
    Activate = 110,
    /// Admin request for a final source-ordered receipt before a daemon closes
    /// its persistent-host connection.
    Detach = 111,
}

impl TryFrom<u16> for MessageKind {
    type Error = ProtocolError;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Bootstrap),
            2 => Ok(Self::Ready),
            3 => Ok(Self::ClientHello),
            4 => Ok(Self::HostHello),
            5 => Ok(Self::Snapshot),
            6 => Ok(Self::Output),
            7 => Ok(Self::Resized),
            8 => Ok(Self::Colors),
            9 => Ok(Self::Title),
            10 => Ok(Self::Pwd),
            11 => Ok(Self::Bell),
            12 => Ok(Self::Exit),
            13 => Ok(Self::ResyncRequired),
            14 => Ok(Self::Launch),
            15 => Ok(Self::Capability),
            16 => Ok(Self::ResizeAck),
            17 => Ok(Self::ClearHistoryAck),
            18 => Ok(Self::CellPixelSizeAck),
            19 => Ok(Self::KittyGraphicsLimitsAck),
            20 => Ok(Self::LaunchFailed),
            21 => Ok(Self::TerminateAck),
            22 => Ok(Self::DetachAck),
            100 => Ok(Self::Input),
            101 => Ok(Self::Paste),
            102 => Ok(Self::ViewerSize),
            103 => Ok(Self::ReleaseViewer),
            104 => Ok(Self::Terminate),
            105 => Ok(Self::MintCapability),
            106 => Ok(Self::SetDefaults),
            107 => Ok(Self::ClearHistory),
            108 => Ok(Self::SetCellPixelSize),
            109 => Ok(Self::SetKittyGraphicsLimits),
            110 => Ok(Self::Activate),
            111 => Ok(Self::Detach),
            other => Err(ProtocolError::UnknownMessageKind(other)),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub version: u16,
    pub kind: MessageKind,
    pub flags: u32,
    pub request_id: u64,
    /// Host-to-client live-stream position.
    ///
    /// Snapshot and its immediately following full-state Colors frame carry
    /// the same boundary and consume no sequence numbers. Every subsequent
    /// live Output, Colors, Resized, Title, Pwd, Bell, Exit, or
    /// ResyncRequired frame consumes exactly one contiguous number. Control
    /// request/response frames have a nonzero `request_id`, carry sequence
    /// zero, and are outside that ordered stream. A client that sees a gap or
    /// duplicate must disconnect and take a new Snapshot; continuing would
    /// silently corrupt its terminal mirror.
    ///
    /// When Output changes application-authored colors, observes cursor-
    /// semantic activity that must be replayed even when the resolved pair is
    /// unchanged, or orders a SetDefaults transition, it carries
    /// [`FLAG_COLORS_FOLLOW`]; its full-state Colors frame is exactly the next
    /// sequence. Resized always carries that flag and likewise has its complete
    /// Colors state exactly next. Producers publish each pair atomically;
    /// consumers stage the first frame and expose only the paired state.
    /// Snapshot keeps flags zero: its same-boundary Colors frame is a mandatory
    /// bootstrap rule rather than a live-stream transition.
    /// ClientHello/HostHello may negotiate [`FLAG_VIEWER_SIZE_ACKS`]. Unknown
    /// flags, flags on Colors or other message kinds, an unflagged Resized, and
    /// a flagged live frame not followed by Colors are protocol errors.
    pub sequence: u64,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: MessageKind, payload: Vec<u8>) -> Self {
        Self { version: PROTOCOL_VERSION, kind, flags: 0, request_id: 0, sequence: 0, payload }
    }
}

#[derive(Debug)]
pub enum ProtocolError {
    Io(io::Error),
    InvalidMagic([u8; 4]),
    InvalidVersion(u16),
    UnknownMessageKind(u16),
    PayloadTooLarge { len: usize, max: usize },
    Truncated { expected: usize, actual: usize },
    MalformedExitPayload,
    MalformedLaunchFailurePayload,
    DecoderFailed,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "terminal-host protocol I/O failed: {error}"),
            Self::InvalidMagic(actual) => {
                write!(f, "bad terminal-host protocol magic {actual:?}")
            }
            Self::InvalidVersion(version) => {
                write!(f, "bad terminal-host protocol version {version}")
            }
            Self::UnknownMessageKind(kind) => {
                write!(f, "unknown terminal-host message kind {kind}")
            }
            Self::PayloadTooLarge { len, max } => {
                write!(f, "terminal-host payload is {len} bytes; maximum is {max}")
            }
            Self::Truncated { expected, actual } => {
                write!(f, "truncated terminal-host frame: expected {expected} bytes, got {actual}")
            }
            Self::MalformedExitPayload => write!(f, "malformed terminal-host exit payload"),
            Self::MalformedLaunchFailurePayload => {
                write!(f, "malformed terminal-host launch-failure payload")
            }
            Self::DecoderFailed => write!(f, "terminal-host decoder is unusable after an error"),
        }
    }
}

impl std::error::Error for ProtocolError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for ProtocolError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Debug, Clone, Copy)]
struct Header {
    version: u16,
    kind: MessageKind,
    flags: u32,
    payload_len: usize,
    request_id: u64,
    sequence: u64,
}

fn parse_header(bytes: &[u8], max_payload: usize) -> Result<Header, ProtocolError> {
    debug_assert_eq!(bytes.len(), HEADER_LEN);
    let magic = <[u8; 4]>::try_from(&bytes[0..4]).expect("fixed header magic slice");
    if magic != MAGIC {
        return Err(ProtocolError::InvalidMagic(magic));
    }
    let version = u16::from_le_bytes([bytes[4], bytes[5]]);
    if version == 0 {
        return Err(ProtocolError::InvalidVersion(version));
    }
    let kind = MessageKind::try_from(u16::from_le_bytes([bytes[6], bytes[7]]))?;
    let flags = u32::from_le_bytes(bytes[8..12].try_into().expect("fixed flags slice"));
    let payload_len =
        u32::from_le_bytes(bytes[12..16].try_into().expect("fixed payload-length slice")) as usize;
    if payload_len > max_payload {
        return Err(ProtocolError::PayloadTooLarge { len: payload_len, max: max_payload });
    }
    let request_id = u64::from_le_bytes(bytes[16..24].try_into().expect("fixed request-id slice"));
    let sequence = u64::from_le_bytes(bytes[24..32].try_into().expect("fixed sequence slice"));
    Ok(Header { version, kind, flags, payload_len, request_id, sequence })
}

/// Validate an encoded CMTH header and return its declared payload length.
///
/// Async readers can use this after reading exactly [`HEADER_LEN`] bytes so
/// the wire layout remains owned by this module.
pub fn frame_payload_len(
    encoded_header: &[u8],
    max_payload: usize,
) -> Result<usize, ProtocolError> {
    if encoded_header.len() != HEADER_LEN {
        return Err(ProtocolError::Truncated {
            expected: HEADER_LEN,
            actual: encoded_header.len(),
        });
    }
    Ok(parse_header(encoded_header, max_payload.min(MAX_FRAME_PAYLOAD))?.payload_len)
}

fn encode_header(frame: &Frame, max_payload: usize) -> Result<[u8; HEADER_LEN], ProtocolError> {
    if frame.version == 0 {
        return Err(ProtocolError::InvalidVersion(frame.version));
    }
    if frame.payload.len() > max_payload {
        return Err(ProtocolError::PayloadTooLarge { len: frame.payload.len(), max: max_payload });
    }
    let payload_len = u32::try_from(frame.payload.len()).map_err(|_| {
        ProtocolError::PayloadTooLarge { len: frame.payload.len(), max: max_payload }
    })?;
    let mut header = [0u8; HEADER_LEN];
    header[0..4].copy_from_slice(&MAGIC);
    header[4..6].copy_from_slice(&frame.version.to_le_bytes());
    header[6..8].copy_from_slice(&(frame.kind as u16).to_le_bytes());
    header[8..12].copy_from_slice(&frame.flags.to_le_bytes());
    header[12..16].copy_from_slice(&payload_len.to_le_bytes());
    header[16..24].copy_from_slice(&frame.request_id.to_le_bytes());
    header[24..32].copy_from_slice(&frame.sequence.to_le_bytes());
    Ok(header)
}

pub fn write_frame(writer: &mut impl Write, frame: &Frame) -> Result<(), ProtocolError> {
    let header = encode_header(frame, MAX_FRAME_PAYLOAD)?;
    writer.write_all(&header)?;
    writer.write_all(&frame.payload)?;
    writer.flush()?;
    Ok(())
}

pub fn encode_frame(frame: &Frame) -> Result<Vec<u8>, ProtocolError> {
    let mut bytes = Vec::with_capacity(HEADER_LEN.saturating_add(frame.payload.len()));
    write_frame(&mut bytes, frame)?;
    Ok(bytes)
}

/// Read one complete frame. Clean EOF before a header returns `None`; EOF
/// after any part of a frame is a truncation error.
pub fn read_frame(
    reader: &mut impl Read,
    max_payload: usize,
) -> Result<Option<Frame>, ProtocolError> {
    let max_payload = max_payload.min(MAX_FRAME_PAYLOAD);
    let mut header_bytes = [0u8; HEADER_LEN];
    let mut header_read = 0;
    while header_read < HEADER_LEN {
        match reader.read(&mut header_bytes[header_read..]) {
            Ok(0) if header_read == 0 => return Ok(None),
            Ok(0) => {
                return Err(ProtocolError::Truncated { expected: HEADER_LEN, actual: header_read });
            }
            Ok(count) => header_read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
    let header = parse_header(&header_bytes, max_payload)?;
    let mut payload = vec![0u8; header.payload_len];
    let mut payload_read = 0;
    while payload_read < payload.len() {
        match reader.read(&mut payload[payload_read..]) {
            Ok(0) => {
                return Err(ProtocolError::Truncated {
                    expected: HEADER_LEN + payload.len(),
                    actual: HEADER_LEN + payload_read,
                });
            }
            Ok(count) => payload_read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(Some(Frame {
        version: header.version,
        kind: header.kind,
        flags: header.flags,
        request_id: header.request_id,
        sequence: header.sequence,
        payload,
    }))
}

/// Incremental decoder for nonblocking or callback-driven stream readers.
/// It parses and validates the header before retaining any payload bytes, so
/// an advertised oversized frame cannot force a correspondingly large
/// allocation.
pub struct FrameDecoder {
    buffer: Vec<u8>,
    expected_total: Option<usize>,
    max_payload: usize,
    failed: bool,
}

impl FrameDecoder {
    pub fn new(max_payload: usize) -> Self {
        Self {
            buffer: Vec::with_capacity(HEADER_LEN),
            expected_total: None,
            max_payload: max_payload.min(MAX_FRAME_PAYLOAD),
            failed: false,
        }
    }

    pub fn push(&mut self, mut input: &[u8]) -> Result<Vec<Frame>, ProtocolError> {
        if self.failed {
            return Err(ProtocolError::DecoderFailed);
        }
        let result = self.push_inner(&mut input);
        if result.is_err() {
            self.failed = true;
        }
        result
    }

    fn push_inner(&mut self, input: &mut &[u8]) -> Result<Vec<Frame>, ProtocolError> {
        let mut frames = Vec::new();
        loop {
            if self.expected_total.is_none() {
                if self.buffer.len() < HEADER_LEN {
                    if input.is_empty() {
                        break;
                    }
                    let count = (HEADER_LEN - self.buffer.len()).min(input.len());
                    self.buffer.extend_from_slice(&input[..count]);
                    *input = &input[count..];
                    if self.buffer.len() < HEADER_LEN {
                        break;
                    }
                }
                let header = parse_header(&self.buffer[..HEADER_LEN], self.max_payload)?;
                self.expected_total = Some(HEADER_LEN + header.payload_len);
                self.buffer.reserve(header.payload_len);
            }

            let expected_total = self.expected_total.expect("set after a valid header");
            if self.buffer.len() < expected_total {
                if input.is_empty() {
                    break;
                }
                let count = (expected_total - self.buffer.len()).min(input.len());
                self.buffer.extend_from_slice(&input[..count]);
                *input = &input[count..];
                if self.buffer.len() < expected_total {
                    break;
                }
            }

            let header = parse_header(&self.buffer[..HEADER_LEN], self.max_payload)?;
            self.buffer.drain(..HEADER_LEN);
            let payload = std::mem::take(&mut self.buffer);
            self.buffer = Vec::with_capacity(HEADER_LEN);
            self.expected_total = None;
            frames.push(Frame {
                version: header.version,
                kind: header.kind,
                flags: header.flags,
                request_id: header.request_id,
                sequence: header.sequence,
                payload,
            });
        }
        Ok(frames)
    }

    pub fn finish(&self) -> Result<(), ProtocolError> {
        if self.failed {
            return Err(ProtocolError::DecoderFailed);
        }
        if self.buffer.is_empty() && self.expected_total.is_none() {
            return Ok(());
        }
        Err(ProtocolError::Truncated {
            expected: self.expected_total.unwrap_or(HEADER_LEN),
            actual: self.buffer.len(),
        })
    }

    pub fn buffered_len(&self) -> usize {
        self.buffer.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex, mpsc};

    /// Test-only stand-in for a direct pipe reader. The bounded queue models
    /// the byte pump, while the mutex is the single parser owner.
    struct PipeBytePump {
        tx: mpsc::SyncSender<Vec<u8>>,
        rx: mpsc::Receiver<Vec<u8>>,
        decoder: Arc<Mutex<FrameDecoder>>,
    }

    impl PipeBytePump {
        fn new(capacity: usize) -> Self {
            let (tx, rx) = mpsc::sync_channel(capacity);
            Self { tx, rx, decoder: Arc::new(Mutex::new(FrameDecoder::new(MAX_FRAME_PAYLOAD))) }
        }

        fn parse_next(&self) -> Result<Option<Vec<Frame>>, ProtocolError> {
            match self.rx.recv() {
                Ok(bytes) => self.decoder.lock().unwrap().push(&bytes).map(Some),
                Err(_) => self.decoder.lock().unwrap().finish().map(|()| None),
            }
        }
    }

    fn sample_frame() -> Frame {
        Frame {
            version: PROTOCOL_VERSION,
            kind: MessageKind::Output,
            flags: 0x1122_3344,
            request_id: 0x0102_0304_0506_0708,
            sequence: 0x1112_1314_1516_1718,
            payload: vec![0xaa, 0xbb, 0xcc],
        }
    }

    #[test]
    fn golden_frame_is_explicit_little_endian() {
        let encoded = encode_frame(&sample_frame()).unwrap();
        assert_eq!(
            encoded,
            vec![
                b'C', b'M', b'T', b'H', // magic
                0x04, 0x00, // version
                0x06, 0x00, // output
                0x44, 0x33, 0x22, 0x11, // flags
                0x03, 0x00, 0x00, 0x00, // payload length
                0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // request id
                0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, // sequence
                0xaa, 0xbb, 0xcc,
            ]
        );
        let decoded = read_frame(&mut encoded.as_slice(), MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!(decoded, sample_frame());
    }

    #[test]
    fn fragmented_and_coalesced_frames_decode_without_boundary_assumptions() {
        let first = sample_frame();
        let mut second = Frame::new(MessageKind::ViewerSize, vec![80, 0, 24, 0]);
        second.request_id = 9;
        let mut stream = encode_frame(&first).unwrap();
        stream.extend_from_slice(&encode_frame(&second).unwrap());

        let mut decoder = FrameDecoder::new(1024);
        let mut decoded = Vec::new();
        for byte in &stream {
            decoded.extend(decoder.push(std::slice::from_ref(byte)).unwrap());
        }
        decoder.finish().unwrap();
        assert_eq!(decoded, vec![first.clone(), second.clone()]);

        let mut decoder = FrameDecoder::new(1024);
        assert_eq!(decoder.push(&stream).unwrap(), vec![first, second]);
        decoder.finish().unwrap();
    }

    #[test]
    fn direct_pipe_pump_handles_split_ansi_and_utf8_then_eof() {
        let mut frame = Frame::new(MessageKind::Output, b"\x1b[31mCafe ".to_vec());
        frame.payload.extend_from_slice("é\x1b[0m".as_bytes());
        let encoded = encode_frame(&frame).unwrap();
        let pump = PipeBytePump::new(3);
        pump.tx.send(encoded[..3].to_vec()).unwrap();
        pump.tx.send(encoded[3..HEADER_LEN + 1].to_vec()).unwrap();
        pump.tx.send(encoded[HEADER_LEN + 1..].to_vec()).unwrap();

        assert!(pump.parse_next().unwrap().unwrap().is_empty());
        assert!(pump.parse_next().unwrap().unwrap().is_empty());
        assert_eq!(pump.parse_next().unwrap().unwrap(), vec![frame]);
        drop(pump.tx);
        assert_eq!(pump.parse_next().unwrap(), None);
    }

    #[test]
    fn direct_pipe_pump_queue_is_bounded_and_parser_access_is_serialized() {
        let pump = PipeBytePump::new(1);
        pump.tx.try_send(vec![1]).unwrap();
        assert!(pump.tx.try_send(vec![2]).is_err());

        let decoder = Arc::clone(&pump.decoder);
        let first = std::thread::spawn(move || decoder.lock().unwrap().buffered_len());
        let decoder = Arc::clone(&pump.decoder);
        let second = std::thread::spawn(move || decoder.lock().unwrap().buffered_len());
        assert_eq!(first.join().unwrap(), 0);
        assert_eq!(second.join().unwrap(), 0);
    }

    #[test]
    fn clear_history_has_a_stable_additive_message_kind() {
        assert_eq!(MessageKind::ClearHistoryAck as u16, 17);
        assert_eq!(MessageKind::try_from(17).unwrap(), MessageKind::ClearHistoryAck);
        assert_eq!(MessageKind::ClearHistory as u16, 107);
        assert_eq!(MessageKind::try_from(107).unwrap(), MessageKind::ClearHistory);
    }

    #[test]
    fn kitty_graphics_limits_have_stable_additive_message_kinds() {
        assert_eq!(MessageKind::KittyGraphicsLimitsAck as u16, 19);
        assert_eq!(MessageKind::try_from(19).unwrap(), MessageKind::KittyGraphicsLimitsAck);
        assert_eq!(MessageKind::SetKittyGraphicsLimits as u16, 109);
        assert_eq!(MessageKind::try_from(109).unwrap(), MessageKind::SetKittyGraphicsLimits);
    }

    #[test]
    fn terminate_receipt_has_a_stable_additive_message_kind() {
        assert_eq!(MessageKind::TerminateAck as u16, 21);
        assert_eq!(MessageKind::try_from(21).unwrap(), MessageKind::TerminateAck);
        assert_eq!(MessageKind::DetachAck as u16, 22);
        assert_eq!(MessageKind::try_from(22).unwrap(), MessageKind::DetachAck);
        assert_eq!(MessageKind::Terminate as u16, 104);
        assert_eq!(MessageKind::try_from(104).unwrap(), MessageKind::Terminate);
    }

    #[test]
    fn launch_failure_has_a_stable_bounded_wire_format() {
        assert_eq!(MessageKind::LaunchFailed as u16, 20);
        assert_eq!(MessageKind::try_from(20).unwrap(), MessageKind::LaunchFailed);

        let failure = HostLaunchFailure::bounded(
            HostLaunchFailureKind::PtyCapacityExhausted,
            "terminal launch failed: PTY capacity exhausted".into(),
        );
        let payload = encode_host_launch_failure(&failure).unwrap();
        assert_eq!(decode_host_launch_failure(&payload).unwrap(), failure);
        assert_eq!(failure.kind.reason_code(), "pty_capacity_exhausted");
        let error = anyhow::Error::new(failure);
        assert_eq!(
            error.downcast_ref::<HostLaunchFailure>().map(|failure| failure.kind),
            Some(HostLaunchFailureKind::PtyCapacityExhausted)
        );

        let oversized = format!("{}é", "x".repeat(MAX_LAUNCH_FAILURE_MESSAGE_BYTES));
        let bounded = HostLaunchFailure::bounded(HostLaunchFailureKind::LaunchFailed, oversized);
        assert!(bounded.message.len() <= MAX_LAUNCH_FAILURE_MESSAGE_BYTES);
        assert!(bounded.message.is_char_boundary(bounded.message.len()));
        assert_eq!(
            decode_host_launch_failure(&encode_host_launch_failure(&bounded).unwrap()).unwrap(),
            bounded
        );

        let mut wrong_version = payload.clone();
        wrong_version[..2].copy_from_slice(&(LAUNCH_FAILURE_PAYLOAD_VERSION + 1).to_le_bytes());
        assert!(matches!(
            decode_host_launch_failure(&wrong_version),
            Err(ProtocolError::MalformedLaunchFailurePayload)
        ));

        let mut unknown_kind = payload.clone();
        unknown_kind[2..4].copy_from_slice(&u16::MAX.to_le_bytes());
        assert!(matches!(
            decode_host_launch_failure(&unknown_kind),
            Err(ProtocolError::MalformedLaunchFailurePayload)
        ));

        let mut invalid_utf8 = payload;
        *invalid_utf8.last_mut().unwrap() = 0xff;
        assert!(matches!(
            decode_host_launch_failure(&invalid_utf8),
            Err(ProtocolError::MalformedLaunchFailurePayload)
        ));
        assert!(matches!(
            decode_host_launch_failure(&[0; LAUNCH_FAILURE_PAYLOAD_HEADER_LEN]),
            Err(ProtocolError::MalformedLaunchFailurePayload)
        ));
        assert!(matches!(
            decode_host_launch_failure(&vec![
                0;
                LAUNCH_FAILURE_PAYLOAD_HEADER_LEN
                    + MAX_LAUNCH_FAILURE_MESSAGE_BYTES
                    + 1
            ]),
            Err(ProtocolError::MalformedLaunchFailurePayload)
        ));
    }

    #[test]
    fn launch_activation_has_a_stable_additive_message_kind() {
        assert_eq!(MessageKind::Activate as u16, 110);
        assert_eq!(MessageKind::try_from(110).unwrap(), MessageKind::Activate);
        assert_eq!(MessageKind::Detach as u16, 111);
        assert_eq!(MessageKind::try_from(111).unwrap(), MessageKind::Detach);
    }

    #[test]
    fn clear_history_ack_statuses_are_stable() {
        assert_eq!(CLEAR_HISTORY_ACK_OK, 0);
        assert_eq!(CLEAR_HISTORY_ACK_PRESERVATION_FAILED, 1);
        assert_eq!(CLEAR_HISTORY_ACK_FAILED, CLEAR_HISTORY_ACK_PRESERVATION_FAILED);
        assert_eq!(CLEAR_HISTORY_ACK_STREAM_TIMEOUT, 2);
        assert_eq!(CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE, 3);
        assert_eq!(CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED, 4);
        assert_eq!(CLEAR_HISTORY_ACK_AMBIGUOUS, 5);
        assert_eq!(CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT, 6);
    }

    #[test]
    fn exit_payload_round_trips_strict_outcomes() {
        for exit in [
            TerminalExit { outcome: TerminalExitOutcome::Exit { code: 23 }, exited_at_ms: 1234 },
            TerminalExit {
                outcome: TerminalExitOutcome::Signal { signal: 9, core_dumped: true },
                exited_at_ms: 5678,
            },
            TerminalExit {
                outcome: TerminalExitOutcome::Unknown { reason: "wait failed".to_string() },
                exited_at_ms: 9012,
            },
        ] {
            assert_eq!(decode_terminal_exit(&encode_terminal_exit(&exit)).unwrap(), exit);
        }

        let mut unknown_kind = encode_terminal_exit(&TerminalExit::unknown("unknown"));
        unknown_kind[2] = 99;
        assert!(matches!(
            decode_terminal_exit(&unknown_kind),
            Err(ProtocolError::MalformedExitPayload)
        ));
        let invalid_code = encode_terminal_exit(&TerminalExit {
            outcome: TerminalExitOutcome::Exit { code: -1 },
            exited_at_ms: 1,
        });
        assert!(matches!(
            decode_terminal_exit(&invalid_code),
            Err(ProtocolError::MalformedExitPayload)
        ));
        assert!(matches!(
            decode_terminal_exit(&[1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            Err(ProtocolError::MalformedExitPayload)
        ));
        assert!(
            serde_json::from_value::<TerminalExitOutcome>(serde_json::json!({
                "kind":"exit",
                "code":0,
                "signal":9,
            }))
            .is_err(),
            "outcome variants reject fields belonging to another variant"
        );
        assert!(
            serde_json::from_value::<TerminalExit>(serde_json::json!({
                "outcome":{"kind":"exit","code":0},
                "exited_at_ms":1,
                "incarnation":"private",
            }))
            .is_err(),
            "durable exit records reject unknown private/public fields"
        );
    }

    #[cfg(unix)]
    #[test]
    fn native_exit_status_retains_exit_code_signal_and_core_flag() {
        use std::os::unix::process::ExitStatusExt;

        let exited = TerminalExit::from_exit_status(&std::process::ExitStatus::from_raw(37 << 8));
        assert_eq!(exited.outcome, TerminalExitOutcome::Exit { code: 37 });

        let signaled = TerminalExit::from_exit_status(&std::process::ExitStatus::from_raw(
            libc::SIGABRT | 0x80,
        ));
        assert_eq!(
            signaled.outcome,
            TerminalExitOutcome::Signal { signal: libc::SIGABRT, core_dumped: true }
        );
    }

    #[cfg(unix)]
    #[test]
    fn cmux_pty_native_child_retains_real_exit_and_signal_status() {
        fn run(script: &str) -> TerminalExitOutcome {
            let pty = cmux_pty::open(cmux_pty::PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
            let mut command = cmux_pty::PtyCommand::new("/bin/sh");
            command.args(["-c", script]);
            let mut spawned = pty.spawn(command).unwrap();
            wait_for_native_child_status(spawned.child.as_mut()).outcome
        }

        assert_eq!(run("exit 17"), TerminalExitOutcome::Exit { code: 17 });
        assert_eq!(
            run("kill -TERM $$"),
            TerminalExitOutcome::Signal { signal: libc::SIGTERM, core_dumped: false }
        );
    }

    #[test]
    fn malformed_headers_poison_the_incremental_decoder() {
        let mut bad_magic = encode_frame(&sample_frame()).unwrap();
        bad_magic[0] = b'X';
        let mut decoder = FrameDecoder::new(1024);
        assert!(matches!(decoder.push(&bad_magic), Err(ProtocolError::InvalidMagic(_))));
        assert!(matches!(decoder.push(&[]), Err(ProtocolError::DecoderFailed)));

        let mut unknown_kind = encode_frame(&sample_frame()).unwrap();
        unknown_kind[6..8].copy_from_slice(&999u16.to_le_bytes());
        let mut decoder = FrameDecoder::new(1024);
        assert!(matches!(decoder.push(&unknown_kind), Err(ProtocolError::UnknownMessageKind(999))));

        let mut zero_version = encode_frame(&sample_frame()).unwrap();
        zero_version[4..6].copy_from_slice(&0u16.to_le_bytes());
        let mut decoder = FrameDecoder::new(1024);
        assert!(matches!(decoder.push(&zero_version), Err(ProtocolError::InvalidVersion(0))));
    }

    #[test]
    fn oversized_length_is_rejected_before_payload_is_buffered() {
        let mut encoded = encode_frame(&sample_frame()).unwrap();
        encoded[12..16].copy_from_slice(&65u32.to_le_bytes());
        encoded.truncate(HEADER_LEN);
        let mut decoder = FrameDecoder::new(64);
        assert!(matches!(
            decoder.push(&encoded),
            Err(ProtocolError::PayloadTooLarge { len: 65, max: 64 })
        ));
        assert_eq!(decoder.buffered_len(), HEADER_LEN);
    }

    #[test]
    fn async_header_helper_owns_payload_length_validation() {
        let encoded = encode_frame(&sample_frame()).unwrap();
        assert_eq!(frame_payload_len(&encoded[..HEADER_LEN], 64).unwrap(), 3);
        assert!(matches!(
            frame_payload_len(&encoded[..HEADER_LEN - 1], 64),
            Err(ProtocolError::Truncated { expected: HEADER_LEN, actual })
                if actual == HEADER_LEN - 1
        ));

        let mut oversized = encoded[..HEADER_LEN].to_vec();
        oversized[12..16].copy_from_slice(&65u32.to_le_bytes());
        assert!(matches!(
            frame_payload_len(&oversized, 64),
            Err(ProtocolError::PayloadTooLarge { len: 65, max: 64 })
        ));

        oversized[12..16]
            .copy_from_slice(&u32::try_from(MAX_FRAME_PAYLOAD + 1).unwrap().to_le_bytes());
        assert!(matches!(
            frame_payload_len(&oversized, usize::MAX),
            Err(ProtocolError::PayloadTooLarge {
                len,
                max: MAX_FRAME_PAYLOAD,
            }) if len == MAX_FRAME_PAYLOAD + 1
        ));
    }

    #[test]
    fn incomplete_header_and_payload_are_reported_as_truncated() {
        let encoded = encode_frame(&sample_frame()).unwrap();
        let mut decoder = FrameDecoder::new(1024);
        decoder.push(&encoded[..8]).unwrap();
        assert!(matches!(
            decoder.finish(),
            Err(ProtocolError::Truncated { expected: HEADER_LEN, actual: 8 })
        ));

        let mut decoder = FrameDecoder::new(1024);
        decoder.push(&encoded[..HEADER_LEN + 1]).unwrap();
        assert!(matches!(
            decoder.finish(),
            Err(ProtocolError::Truncated { expected, actual })
                if expected == HEADER_LEN + 3 && actual == HEADER_LEN + 1
        ));

        let error = read_frame(&mut &encoded[..HEADER_LEN + 2], 1024).unwrap_err();
        assert!(matches!(
            error,
            ProtocolError::Truncated { expected, actual }
                if expected == HEADER_LEN + 3 && actual == HEADER_LEN + 2
        ));
    }

    #[test]
    fn encoder_enforces_the_global_payload_budget() {
        let frame = Frame::new(MessageKind::Input, vec![0; MAX_FRAME_PAYLOAD + 1]);
        assert!(matches!(
            encode_frame(&frame),
            Err(ProtocolError::PayloadTooLarge { len, max })
                if len == MAX_FRAME_PAYLOAD + 1 && max == MAX_FRAME_PAYLOAD
        ));
    }
}
