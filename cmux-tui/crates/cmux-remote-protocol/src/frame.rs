use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

pub const REMOTE_PROTOCOL_VERSION: u8 = 1;
pub const MAX_FRAME_PAYLOAD: usize = 48 * 1024;
const MAGIC: [u8; 4] = *b"CMXR";
const HEADER_BYTES: usize = 60;
pub const MAX_WIRE_FRAME_BYTES: usize = HEADER_BYTES + MAX_FRAME_PAYLOAD;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[repr(u8)]
pub enum Lane {
    Interactive = 0,
    Control = 1,
    Bulk = 2,
    Tunnel = 3,
}

impl Lane {
    pub const ALL: [Self; 4] = [Self::Interactive, Self::Control, Self::Bulk, Self::Tunnel];

    pub const fn priority(self) -> u8 {
        match self {
            Self::Interactive => 0,
            Self::Control => 1,
            Self::Tunnel => 2,
            Self::Bulk => 3,
        }
    }

    /// Whether frames on this lane may cross a physical-connection generation.
    /// Tunnel traffic can have external side effects and is therefore reliable
    /// only within one generation. Reconnect starts a fresh tunnel sequence
    /// epoch and closes every tunnel stream instead of replaying ambiguous bytes.
    pub const fn replays_across_generations(self) -> bool {
        !matches!(self, Self::Tunnel)
    }

    fn from_wire(value: u8) -> Result<Self, FrameDecodeError> {
        match value {
            0 => Ok(Self::Interactive),
            1 => Ok(Self::Control),
            2 => Ok(Self::Bulk),
            3 => Ok(Self::Tunnel),
            other => Err(FrameDecodeError::UnknownLane(other)),
        }
    }
}

impl fmt::Display for Lane {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Interactive => "interactive",
            Self::Control => "control",
            Self::Bulk => "bulk",
            Self::Tunnel => "tunnel",
        })
    }
}

impl FromStr for Lane {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "interactive" => Ok(Self::Interactive),
            "control" => Ok(Self::Control),
            "bulk" => Ok(Self::Bulk),
            "tunnel" => Ok(Self::Tunnel),
            _ => Err(format!("unknown lane {value:?}")),
        }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LanePolicy {
    Single,
    Isolated,
    #[default]
    Auto,
}

impl fmt::Display for LanePolicy {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Single => "single",
            Self::Isolated => "isolated",
            Self::Auto => "auto",
        })
    }
}

impl FromStr for LanePolicy {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "single" => Ok(Self::Single),
            "isolated" => Ok(Self::Isolated),
            "auto" => Ok(Self::Auto),
            _ => Err(format!("lane policy must be single, isolated, or auto, got {value:?}")),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SessionId(pub [u8; 16]);

impl SessionId {
    pub const ZERO: Self = Self([0; 16]);

    pub fn from_hex(value: &str) -> Result<Self, String> {
        if value.len() != 32 {
            return Err("session ID must contain exactly 32 hexadecimal characters".into());
        }
        if !value.is_ascii() {
            return Err("session ID contains a non-hexadecimal character".into());
        }
        let mut bytes = [0_u8; 16];
        for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
            let encoded = std::str::from_utf8(chunk).expect("ASCII was checked above");
            bytes[index] = u8::from_str_radix(encoded, 16)
                .map_err(|_| "session ID contains a non-hexadecimal character".to_string())?;
        }
        Ok(Self(bytes))
    }

    pub fn to_hex(self) -> String {
        format!("{self:?}")
    }
}

impl fmt::Debug for SessionId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FrameFlags(u16);

impl FrameFlags {
    pub const RELIABLE: Self = Self(1 << 0);
    pub const OPEN: Self = Self(1 << 1);
    pub const FIN: Self = Self(1 << 2);
    pub const RESET: Self = Self(1 << 3);
    pub const ACK_ONLY: Self = Self(1 << 4);
    pub const REPLAY: Self = Self(1 << 5);
    /// Authenticated terminal close for the entire logical client session.
    ///
    /// This is distinct from `FIN`, which closes one service stream. A session
    /// close always travels on the control lane with stream zero and no payload.
    pub const SESSION_CLOSE: Self = Self(1 << 6);
    /// Client liveness probe on the control lane, stream zero.
    pub const HEARTBEAT_REQUEST: Self = Self(1 << 7);
    /// Daemon response to a liveness probe on the control lane, stream zero.
    pub const HEARTBEAT_RESPONSE: Self = Self(1 << 8);

    const KNOWN: u16 = Self::RELIABLE.0
        | Self::OPEN.0
        | Self::FIN.0
        | Self::RESET.0
        | Self::ACK_ONLY.0
        | Self::REPLAY.0
        | Self::SESSION_CLOSE.0
        | Self::HEARTBEAT_REQUEST.0
        | Self::HEARTBEAT_RESPONSE.0;

    pub const fn empty() -> Self {
        Self(0)
    }

    pub const fn bits(self) -> u16 {
        self.0
    }

    pub const fn contains(self, flag: Self) -> bool {
        self.0 & flag.0 == flag.0
    }

    pub const fn union(self, flag: Self) -> Self {
        Self(self.0 | flag.0)
    }

    fn from_wire(bits: u16) -> Result<Self, FrameDecodeError> {
        if bits & !Self::KNOWN != 0 {
            return Err(FrameDecodeError::UnknownFlags(bits & !Self::KNOWN));
        }
        Ok(Self(bits))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireFrame {
    pub session: SessionId,
    pub generation: u64,
    pub lane: Lane,
    pub flags: FrameFlags,
    pub sequence: u64,
    pub acknowledgement: u64,
    pub stream: u64,
    pub payload: Vec<u8>,
}

impl WireFrame {
    pub fn encode(&self) -> Result<Vec<u8>, FrameDecodeError> {
        if self.payload.len() > MAX_FRAME_PAYLOAD {
            return Err(FrameDecodeError::PayloadTooLarge(self.payload.len()));
        }
        if self.flags.contains(FrameFlags::ACK_ONLY) && !self.payload.is_empty() {
            return Err(FrameDecodeError::AckHasPayload);
        }
        validate_session_close(self.lane, self.flags, self.stream, self.payload.len())?;
        validate_heartbeat(self.lane, self.flags, self.stream, self.payload.len())?;

        let mut encoded = Vec::with_capacity(HEADER_BYTES + self.payload.len());
        encoded.extend_from_slice(&MAGIC);
        encoded.push(REMOTE_PROTOCOL_VERSION);
        encoded.push(self.lane as u8);
        encoded.extend_from_slice(&self.flags.bits().to_be_bytes());
        encoded.extend_from_slice(&self.session.0);
        encoded.extend_from_slice(&self.generation.to_be_bytes());
        encoded.extend_from_slice(&self.sequence.to_be_bytes());
        encoded.extend_from_slice(&self.acknowledgement.to_be_bytes());
        encoded.extend_from_slice(&self.stream.to_be_bytes());
        encoded.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
        encoded.extend_from_slice(&self.payload);
        Ok(encoded)
    }

    pub fn decode(encoded: &[u8]) -> Result<Self, FrameDecodeError> {
        if encoded.len() < HEADER_BYTES {
            return Err(FrameDecodeError::Truncated {
                expected: HEADER_BYTES,
                actual: encoded.len(),
            });
        }
        if encoded[..4] != MAGIC {
            return Err(FrameDecodeError::BadMagic);
        }
        if encoded[4] != REMOTE_PROTOCOL_VERSION {
            return Err(FrameDecodeError::UnsupportedVersion(encoded[4]));
        }

        let lane = Lane::from_wire(encoded[5])?;
        let flags = FrameFlags::from_wire(u16::from_be_bytes([encoded[6], encoded[7]]))?;
        let mut session = [0_u8; 16];
        session.copy_from_slice(&encoded[8..24]);
        let generation = read_u64(&encoded[24..32]);
        let sequence = read_u64(&encoded[32..40]);
        let acknowledgement = read_u64(&encoded[40..48]);
        let stream = read_u64(&encoded[48..56]);
        let payload_len = u32::from_be_bytes(encoded[56..60].try_into().unwrap()) as usize;
        if payload_len > MAX_FRAME_PAYLOAD {
            return Err(FrameDecodeError::PayloadTooLarge(payload_len));
        }
        let expected = HEADER_BYTES + payload_len;
        if encoded.len() != expected {
            return Err(FrameDecodeError::LengthMismatch { expected, actual: encoded.len() });
        }
        if flags.contains(FrameFlags::ACK_ONLY) && payload_len != 0 {
            return Err(FrameDecodeError::AckHasPayload);
        }
        validate_session_close(lane, flags, stream, payload_len)?;
        validate_heartbeat(lane, flags, stream, payload_len)?;

        Ok(Self {
            session: SessionId(session),
            generation,
            lane,
            flags,
            sequence,
            acknowledgement,
            stream,
            payload: encoded[HEADER_BYTES..].to_vec(),
        })
    }
}

fn validate_session_close(
    lane: Lane,
    flags: FrameFlags,
    stream: u64,
    payload_len: usize,
) -> Result<(), FrameDecodeError> {
    if !flags.contains(FrameFlags::SESSION_CLOSE) {
        return Ok(());
    }
    let incompatible = flags.contains(FrameFlags::OPEN)
        || flags.contains(FrameFlags::FIN)
        || flags.contains(FrameFlags::RESET)
        || flags.contains(FrameFlags::ACK_ONLY)
        || !flags.contains(FrameFlags::RELIABLE);
    if lane != Lane::Control || stream != 0 || payload_len != 0 || incompatible {
        return Err(FrameDecodeError::InvalidSessionClose);
    }
    Ok(())
}

fn validate_heartbeat(
    lane: Lane,
    flags: FrameFlags,
    stream: u64,
    payload_len: usize,
) -> Result<(), FrameDecodeError> {
    let request = flags.contains(FrameFlags::HEARTBEAT_REQUEST);
    let response = flags.contains(FrameFlags::HEARTBEAT_RESPONSE);
    if !request && !response {
        return Ok(());
    }
    let incompatible = request == response
        || flags.contains(FrameFlags::OPEN)
        || flags.contains(FrameFlags::FIN)
        || flags.contains(FrameFlags::RESET)
        || flags.contains(FrameFlags::ACK_ONLY)
        || flags.contains(FrameFlags::SESSION_CLOSE);
    if lane != Lane::Control || stream != 0 || payload_len != 0 || incompatible {
        return Err(FrameDecodeError::InvalidHeartbeat);
    }
    Ok(())
}

fn read_u64(bytes: &[u8]) -> u64 {
    u64::from_be_bytes(bytes.try_into().unwrap())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameDecodeError {
    Truncated { expected: usize, actual: usize },
    BadMagic,
    UnsupportedVersion(u8),
    UnknownLane(u8),
    UnknownFlags(u16),
    PayloadTooLarge(usize),
    LengthMismatch { expected: usize, actual: usize },
    AckHasPayload,
    InvalidSessionClose,
    InvalidHeartbeat,
}

impl fmt::Display for FrameDecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated { expected, actual } => {
                write!(formatter, "frame needs at least {expected} bytes, got {actual}")
            }
            Self::BadMagic => formatter.write_str("frame has invalid magic"),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported remote protocol version {version}")
            }
            Self::UnknownLane(lane) => write!(formatter, "frame has unknown lane {lane}"),
            Self::UnknownFlags(flags) => write!(formatter, "frame has unknown flags 0x{flags:04x}"),
            Self::PayloadTooLarge(size) => {
                write!(formatter, "frame payload is {size} bytes, maximum is {MAX_FRAME_PAYLOAD}")
            }
            Self::LengthMismatch { expected, actual } => {
                write!(formatter, "frame length is {actual} bytes, header declares {expected}")
            }
            Self::AckHasPayload => formatter.write_str("ack-only frame cannot contain a payload"),
            Self::InvalidSessionClose => formatter.write_str(
                "session-close frame must be empty control-lane stream zero without stream flags",
            ),
            Self::InvalidHeartbeat => formatter.write_str(
                "heartbeat frame must have one heartbeat flag on empty control-lane stream zero",
            ),
        }
    }
}

impl std::error::Error for FrameDecodeError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_id_hex_round_trip_is_strict() {
        let session = SessionId([0x5a; 16]);
        assert_eq!(SessionId::from_hex(&session.to_hex()).unwrap(), session);
        assert!(SessionId::from_hex("5a").is_err());
        assert!(SessionId::from_hex("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz").is_err());
        assert!(SessionId::from_hex("éééééééééééééééé").is_err());
    }

    #[test]
    fn frame_round_trip_preserves_reliability_fields() {
        let frame = WireFrame {
            session: SessionId([7; 16]),
            generation: 3,
            lane: Lane::Interactive,
            flags: FrameFlags::RELIABLE.union(FrameFlags::OPEN),
            sequence: 41,
            acknowledgement: 37,
            stream: 9,
            payload: b"input".to_vec(),
        };
        assert_eq!(WireFrame::decode(&frame.encode().unwrap()).unwrap(), frame);
    }

    #[test]
    fn session_close_has_a_canonical_wire_shape() {
        let frame = WireFrame {
            session: SessionId([8; 16]),
            generation: 2,
            lane: Lane::Control,
            flags: FrameFlags::RELIABLE.union(FrameFlags::SESSION_CLOSE),
            sequence: 4,
            acknowledgement: 3,
            stream: 0,
            payload: Vec::new(),
        };
        assert_eq!(WireFrame::decode(&frame.encode().unwrap()).unwrap(), frame);

        let mut invalid = frame.clone();
        invalid.stream = 1;
        assert_eq!(invalid.encode(), Err(FrameDecodeError::InvalidSessionClose));

        invalid = frame;
        invalid.flags = FrameFlags::SESSION_CLOSE;
        assert_eq!(invalid.encode(), Err(FrameDecodeError::InvalidSessionClose));
    }

    #[test]
    fn heartbeat_has_a_canonical_wire_shape() {
        let frame = WireFrame {
            session: SessionId([8; 16]),
            generation: 2,
            lane: Lane::Control,
            flags: FrameFlags::RELIABLE.union(FrameFlags::HEARTBEAT_REQUEST),
            sequence: 4,
            acknowledgement: 3,
            stream: 0,
            payload: Vec::new(),
        };
        assert_eq!(WireFrame::decode(&frame.encode().unwrap()).unwrap(), frame);

        let mut invalid = frame;
        invalid.flags = invalid.flags.union(FrameFlags::HEARTBEAT_RESPONSE);
        assert_eq!(invalid.encode(), Err(FrameDecodeError::InvalidHeartbeat));
    }

    #[test]
    fn decoder_rejects_trailing_bytes() {
        let frame = WireFrame {
            session: SessionId::ZERO,
            generation: 0,
            lane: Lane::Control,
            flags: FrameFlags::empty(),
            sequence: 0,
            acknowledgement: 0,
            stream: 0,
            payload: Vec::new(),
        };
        let mut encoded = frame.encode().unwrap();
        encoded.push(0);
        assert!(matches!(
            WireFrame::decode(&encoded),
            Err(FrameDecodeError::LengthMismatch { .. })
        ));
    }

    #[test]
    fn lane_priority_keeps_input_ahead_of_bulk() {
        assert!(Lane::Interactive.priority() < Lane::Control.priority());
        assert!(Lane::Control.priority() < Lane::Bulk.priority());
    }

    #[test]
    fn tunnel_lane_is_generation_scoped() {
        assert!(!Lane::Tunnel.replays_across_generations());
        for lane in [Lane::Interactive, Lane::Control, Lane::Bulk] {
            assert!(lane.replays_across_generations());
        }
    }

    #[test]
    fn lane_policy_is_configurable() {
        for policy in [LanePolicy::Single, LanePolicy::Isolated, LanePolicy::Auto] {
            assert_eq!(policy.to_string().parse::<LanePolicy>().unwrap(), policy);
        }
    }
}
