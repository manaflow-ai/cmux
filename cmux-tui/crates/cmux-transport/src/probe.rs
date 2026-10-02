//! Path probes.
//!
//! A probe is the UDP payload of a tiny overlay packet sent inside the
//! WireGuard session to the reserved overlay port, so WireGuard
//! authenticates it and no second key exists. The sender puts it on one
//! specific path; the receiver answers with a pong on the path the ping
//! arrived on, which gives that path's round trip. `path` is the sender's
//! own path id, echoed so the sender needs no lookup table for answers.

use crate::path::PathId;

/// Overlay UDP port that carries probes. Links use TCP 4100.
pub const PROBE_PORT: u16 = 4102;
const MAGIC: [u8; 4] = *b"cmxp";
pub const PROBE_LEN: usize = 4 + 1 + 8 + 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeKind {
    Ping = 1,
    Pong = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Probe {
    pub kind: ProbeKind,
    /// Sender-chosen; a pong carries the ping's id.
    pub id: u64,
    pub path: PathId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeError {
    Length(usize),
    Magic,
    Kind(u8),
}

impl Probe {
    pub fn encode(&self) -> [u8; PROBE_LEN] {
        let mut bytes = [0u8; PROBE_LEN];
        bytes[0..4].copy_from_slice(&MAGIC);
        bytes[4] = self.kind as u8;
        bytes[5..13].copy_from_slice(&self.id.to_be_bytes());
        bytes[13..15].copy_from_slice(&self.path.0.to_be_bytes());
        bytes
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, ProbeError> {
        if bytes.len() != PROBE_LEN {
            return Err(ProbeError::Length(bytes.len()));
        }
        if bytes[0..4] != MAGIC {
            return Err(ProbeError::Magic);
        }
        let kind = match bytes[4] {
            1 => ProbeKind::Ping,
            2 => ProbeKind::Pong,
            other => return Err(ProbeError::Kind(other)),
        };
        let mut id = [0u8; 8];
        id.copy_from_slice(&bytes[5..13]);
        Ok(Self {
            kind,
            id: u64::from_be_bytes(id),
            path: PathId(u16::from_be_bytes([bytes[13], bytes[14]])),
        })
    }

    /// The answer to a ping, sent back on the path the ping arrived on.
    pub fn pong(&self) -> Option<Self> {
        (self.kind == ProbeKind::Ping).then_some(Self { kind: ProbeKind::Pong, ..*self })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_round_trips_and_pong_echoes() {
        let ping = Probe { kind: ProbeKind::Ping, id: 0xDEAD_BEEF_0000_0001, path: PathId(7) };
        let decoded = Probe::decode(&ping.encode()).expect("decodes");
        assert_eq!(decoded, ping);
        let pong = decoded.pong().expect("ping has a pong");
        assert_eq!((pong.kind, pong.id, pong.path), (ProbeKind::Pong, ping.id, ping.path));
        assert_eq!(pong.pong(), None);
    }

    #[test]
    fn malformed_probes_are_refused() {
        let ping = Probe { kind: ProbeKind::Ping, id: 1, path: PathId(1) }.encode();
        assert_eq!(Probe::decode(&ping[..14]), Err(ProbeError::Length(14)));
        let mut magic = ping;
        magic[0] = b'x';
        assert_eq!(Probe::decode(&magic), Err(ProbeError::Magic));
        let mut kind = ping;
        kind[4] = 9;
        assert_eq!(Probe::decode(&kind), Err(ProbeError::Kind(9)));
    }
}
