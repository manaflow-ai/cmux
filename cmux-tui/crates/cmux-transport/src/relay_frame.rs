//! The binary frame the host's Durable Object relay forwards.
//!
//! `[u8 version = 1][u8 kind][16-byte peer install id][payload]`, one frame
//! per WebSocket binary message. On the host's socket `peer` names the
//! client the datagrams came from or go to; on a client's socket it names
//! the host. The relay reads only `version`, `kind` and `peer`; datagrams
//! are WireGuard messages it cannot decrypt. The TypeScript relay checks
//! itself against `tests/vectors/relay-frames.json`.
//!
//! A `Datagrams` payload is one or more `[u16 big-endian length][datagram]`
//! records. Batching matters: one Durable Object passes about 4,000
//! incoming messages per second (measured 2026-10-02), so a sender packs
//! every datagram that is ready into one message (up to 16 KiB), which also
//! cuts per-message billing.

pub const RELAY_FRAME_VERSION: u8 = 1;
pub const RELAY_FRAME_HEADER_LEN: usize = 18;
/// Largest payload. Anything larger is a protocol error, not a split.
pub const RELAY_FRAME_MAX_PAYLOAD: usize = 16 * 1024;

/// A 128-bit install or host id, as `TeamDO` assigns it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PeerId(pub [u8; 16]);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameKind {
    /// One or more length-prefixed WireGuard datagrams.
    Datagrams = 1,
    /// The sender's current path candidates (CBOR list), for rendezvous.
    Candidates = 2,
    /// Ask a paused or sleeping host to come back; the relay forwards it to
    /// the host's socket or to the wake path.
    Wake = 3,
}

impl FrameKind {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Datagrams),
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
    /// A `Datagrams` payload whose records do not tile it exactly, or an
    /// empty record.
    BadBatch,
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
        if kind == FrameKind::Datagrams {
            split_batch(payload)?;
        }
        let mut peer = [0u8; 16];
        peer.copy_from_slice(&bytes[2..RELAY_FRAME_HEADER_LEN]);
        Ok(Self { kind, peer: PeerId(peer), payload: payload.to_vec() })
    }

    /// Packs datagrams into one `Datagrams` frame. Returns `TooLarge` when
    /// they do not fit; the caller sends the rest in the next frame.
    pub fn datagrams(peer: PeerId, datagrams: &[&[u8]]) -> Result<Self, RelayFrameError> {
        let mut payload = Vec::new();
        for datagram in datagrams {
            let len = u16::try_from(datagram.len()).map_err(|_| RelayFrameError::TooLarge(datagram.len()))?;
            if len == 0 {
                return Err(RelayFrameError::BadBatch);
            }
            payload.extend_from_slice(&len.to_be_bytes());
            payload.extend_from_slice(datagram);
        }
        if payload.is_empty() {
            return Err(RelayFrameError::BadBatch);
        }
        if payload.len() > RELAY_FRAME_MAX_PAYLOAD {
            return Err(RelayFrameError::TooLarge(payload.len()));
        }
        Ok(Self { kind: FrameKind::Datagrams, peer, payload })
    }

    /// The datagrams of a `Datagrams` frame, in order.
    pub fn split_datagrams(&self) -> Result<Vec<&[u8]>, RelayFrameError> {
        split_batch(&self.payload)
    }
}

fn split_batch(payload: &[u8]) -> Result<Vec<&[u8]>, RelayFrameError> {
    let mut records = Vec::new();
    let mut rest = payload;
    while !rest.is_empty() {
        if rest.len() < 2 {
            return Err(RelayFrameError::BadBatch);
        }
        let len = usize::from(u16::from_be_bytes([rest[0], rest[1]]));
        if len == 0 || rest.len() < 2 + len {
            return Err(RelayFrameError::BadBatch);
        }
        records.push(&rest[2..2 + len]);
        rest = &rest[2 + len..];
    }
    if records.is_empty() {
        return Err(RelayFrameError::BadBatch);
    }
    Ok(records)
}
