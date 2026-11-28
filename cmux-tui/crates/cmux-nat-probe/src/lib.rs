//! NAT traversal between two real hosts, measured: the NAT-traversal ledger's probe.
//!
//! Leo, 2026-11-25: "why don't we do mac side connect + measure more numbers and do more stuff".
//! Our mesh had no hole-punching success numbers. This probe produces them on real pairs: each
//! side learns its reflexive addresses over STUN (RFC 5389) from the socket it then punches
//! from, the two sides swap candidates through a signalling channel the runner provides (stdin
//! and stdout, carried over ssh), both punch at once, and the probe records whether a direct
//! path opened, how long it took, its round-trip times, and how long a side that moved to a new
//! socket (a new NAT mapping, as after a network change) takes to be heard directly again.
//!
//! Pure pieces live here (STUN encoding, the probe's wire format, percentiles), so they are
//! tested without a network; `main.rs` is the event loop.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

/// RFC 5389's magic cookie.
pub const STUN_MAGIC: u32 = 0x2112_A442;

/// A STUN Binding request with the given transaction id.
#[must_use]
pub fn stun_request(txid: [u8; 12]) -> [u8; 20] {
    let mut out = [0u8; 20];
    out[0..2].copy_from_slice(&0x0001u16.to_be_bytes());
    // Message length 0: no attributes.
    out[4..8].copy_from_slice(&STUN_MAGIC.to_be_bytes());
    out[8..20].copy_from_slice(&txid);
    out
}

/// The mapped address of a STUN Binding success response for `txid`, or None for anything else.
/// XOR-MAPPED-ADDRESS wins over MAPPED-ADDRESS when both are present.
#[must_use]
pub fn stun_mapped(buf: &[u8], txid: [u8; 12]) -> Option<SocketAddr> {
    if buf.len() < 20 || u16::from_be_bytes([buf[0], buf[1]]) != 0x0101 {
        return None;
    }
    if u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]) != STUN_MAGIC || buf[8..20] != txid {
        return None;
    }
    let len = usize::from(u16::from_be_bytes([buf[2], buf[3]]));
    let body = buf.get(20..20 + len)?;
    let mut plain = None;
    let mut i = 0;
    while i + 4 <= body.len() {
        let kind = u16::from_be_bytes([body[i], body[i + 1]]);
        let alen = usize::from(u16::from_be_bytes([body[i + 2], body[i + 3]]));
        let value = body.get(i + 4..i + 4 + alen)?;
        match kind {
            0x0020 => return decode_addr(value, Some(&buf[4..20])),
            0x0001 => plain = decode_addr(value, None),
            _ => {}
        }
        i += 4 + alen.div_ceil(4) * 4;
    }
    plain
}

fn decode_addr(value: &[u8], xor: Option<&[u8]>) -> Option<SocketAddr> {
    if value.len() < 8 {
        return None;
    }
    let mut port = u16::from_be_bytes([value[2], value[3]]);
    let key = xor.unwrap_or(&[0u8; 16]);
    if xor.is_some() {
        port ^= u16::from_be_bytes([key[0], key[1]]);
    }
    match value[1] {
        0x01 => {
            let mut ip = [0u8; 4];
            for (k, b) in ip.iter_mut().enumerate() {
                *b = value[4 + k] ^ key[k];
            }
            Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(ip)), port))
        }
        0x02 if value.len() >= 20 => {
            let mut ip = [0u8; 16];
            for (k, b) in ip.iter_mut().enumerate() {
                *b = value[4 + k] ^ key[k];
            }
            Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(ip)), port))
        }
        _ => None,
    }
}

/// The probe's packets: 4-byte magic, kind, a session token both sides share, a sequence
/// number and the sender's send time (echoed back in a pong).
pub const PROBE_MAGIC: [u8; 4] = *b"CNP1";
pub const PACKET_LEN: usize = 4 + 1 + 8 + 4 + 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A hole punch. `heard` (bit 0x80 of the kind byte) says the sender has heard the peer.
    Punch {
        heard: bool,
    },
    Ping,
    Pong,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Packet {
    pub kind: Kind,
    pub token: u64,
    pub seq: u32,
    pub sent_us: u64,
}

impl Packet {
    #[must_use]
    pub fn encode(&self) -> [u8; PACKET_LEN] {
        let mut out = [0u8; PACKET_LEN];
        out[0..4].copy_from_slice(&PROBE_MAGIC);
        out[4] = match self.kind {
            Kind::Punch { heard } => 1 | if heard { 0x80 } else { 0 },
            Kind::Ping => 2,
            Kind::Pong => 3,
        };
        out[5..13].copy_from_slice(&self.token.to_be_bytes());
        out[13..17].copy_from_slice(&self.seq.to_be_bytes());
        out[17..25].copy_from_slice(&self.sent_us.to_be_bytes());
        out
    }

    /// A packet of this session, or None (a stray datagram, another run's token).
    #[must_use]
    pub fn decode(buf: &[u8], token: u64) -> Option<Self> {
        if buf.len() != PACKET_LEN || buf[0..4] != PROBE_MAGIC {
            return None;
        }
        let kind = match buf[4] & 0x7f {
            1 => Kind::Punch { heard: buf[4] & 0x80 != 0 },
            2 => Kind::Ping,
            3 => Kind::Pong,
            _ => return None,
        };
        let got = u64::from_be_bytes(buf[5..13].try_into().ok()?);
        if got != token {
            return None;
        }
        Some(Self {
            kind,
            token,
            seq: u32::from_be_bytes(buf[13..17].try_into().ok()?),
            sent_us: u64::from_be_bytes(buf[17..25].try_into().ok()?),
        })
    }
}

/// The `q` quantile (0..=1) of `samples` by nearest rank, or None when empty.
#[must_use]
pub fn quantile(samples: &[f64], q: f64) -> Option<f64> {
    if samples.is_empty() {
        return None;
    }
    let mut v = samples.to_vec();
    v.sort_by(f64::total_cmp);
    let rank = (q * v.len() as f64).ceil().max(1.0) as usize;
    Some(v[rank.min(v.len()) - 1])
}

/// Whether an address is worth offering as a candidate: not loopback, not unspecified, not
/// IPv6 link-local (which needs a scope the peer cannot know).
#[must_use]
pub fn usable_candidate(addr: &SocketAddr) -> bool {
    let ip = addr.ip();
    if ip.is_loopback() || ip.is_unspecified() || addr.port() == 0 {
        return false;
    }
    match ip {
        IpAddr::V6(v6) => (v6.segments()[0] & 0xffc0) != 0xfe80,
        IpAddr::V4(_) => true,
    }
}

/// One `tailscale ping` run's replies: each pong's round trip, and whether it came on a direct path (an `IP:port`)
/// rather than through a DERP relay or a peer relay.
#[derive(Debug, Default, PartialEq)]
pub struct TailscalePings {
    pub rtt_ms: Vec<f64>,
    pub direct: Vec<bool>,
    pub last_via: Option<String>,
}

/// Parses `tailscale ping` output: lines like `pong from host (100.x) via DERP(sfo) in 45ms` or
/// `... via 203.0.113.9:41641 in 3ms`. Other lines (timeouts, notes) are skipped.
#[must_use]
pub fn parse_tailscale_ping(text: &str) -> TailscalePings {
    let mut out = TailscalePings::default();
    for line in text.lines() {
        let Some(rest) = line.trim().strip_prefix("pong from ") else { continue };
        let Some((_, after)) = rest.split_once(" via ") else { continue };
        let Some((via, rtt)) = after.rsplit_once(" in ") else { continue };
        let ms = rtt.trim().strip_suffix("ms").and_then(|v| v.trim().parse::<f64>().ok());
        let Some(ms) = ms else { continue };
        out.direct.push(via.parse::<SocketAddr>().is_ok());
        out.rtt_ms.push(ms);
        out.last_via = Some(via.to_string());
    }
    out
}

#[cfg(test)]
mod tests;
