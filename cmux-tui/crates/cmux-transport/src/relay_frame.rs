//! The binary frame the host's Durable Object relay forwards.
//!
//! `[u8 version = 1][u8 kind][16-byte peer install id][payload]`, one frame
//! per WebSocket binary message. On the host's socket `peer` names the
//! client the datagram came from or goes to; on a client's socket it names
//! the host. The relay reads only `version`, `kind` and `peer`; a datagram
//! payload is a WireGuard message it cannot decrypt. The TypeScript relay
//! checks itself against `tests/vectors/relay-frames.json`.

pub const RELAY_FRAME_VERSION: u8 = 1;
pub const RELAY_FRAME_HEADER_LEN: usize = 18;
/// Largest payload: a WireGuard datagram fits easily; candidate lists are
/// small. Anything larger is a protocol error, not a split.
pub const RELAY_FRAME_MAX_PAYLOAD: usize = 2048;

/// A 128-bit install or host id, as `TeamDO` assigns it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PeerId(pub [u8; 16]);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameKind {
    /// One WireGuard datagram.
    Datagram = 1,
    /// The sender's current path candidates (CBOR list), for rendezvous.
    Candidates = 2,
    /// Ask a paused or sleeping host to come back; the relay forwards it to
    /// the host's socket or to the wake path.
    Wake = 3,
}

impl FrameKind {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Datagram),
            2 => Some(Self::Candidates),
            3 => Some(Self::Wake),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayFrame {
    pub kind: FrameKind,
    pub peer: PeerId,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayFrameError {
    Short,
    Version(u8),
    Kind(u8),
    TooLarge(usize),
}

impl RelayFrame {
    pub fn encode(&self) -> Result<Vec<u8>, RelayFrameError> {
        if self.payload.len() > RELAY_FRAME_MAX_PAYLOAD {
            return Err(RelayFrameError::TooLarge(self.payload.len()));
        }
        let mut bytes = Vec::with_capacity(RELAY_FRAME_HEADER_LEN + self.payload.len());
        bytes.push(RELAY_FRAME_VERSION);
        bytes.push(self.kind as u8);
        bytes.extend_from_slice(&self.peer.0);
        bytes.extend_from_slice(&self.payload);
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, RelayFrameError> {
        if bytes.len() < RELAY_FRAME_HEADER_LEN {
            return Err(RelayFrameError::Short);
        }
        if bytes[0] != RELAY_FRAME_VERSION {
            return Err(RelayFrameError::Version(bytes[0]));
        }
        let kind = FrameKind::from_byte(bytes[1]).ok_or(RelayFrameError::Kind(bytes[1]))?;
        let payload = &bytes[RELAY_FRAME_HEADER_LEN..];
        if payload.len() > RELAY_FRAME_MAX_PAYLOAD {
            return Err(RelayFrameError::TooLarge(payload.len()));
        }
        let mut peer = [0u8; 16];
        peer.copy_from_slice(&bytes[2..RELAY_FRAME_HEADER_LEN]);
        Ok(Self { kind, peer: PeerId(peer), payload: payload.to_vec() })
    }
}
