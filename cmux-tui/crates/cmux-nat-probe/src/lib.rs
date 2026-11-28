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

/// The `N` bytes of `buf` at `at`, or None when `buf` is too short.
fn bytes_at<const N: usize>(buf: &[u8], at: usize) -> Option<[u8; N]> {
    buf.get(at..at.checked_add(N)?)?.try_into().ok()
}

fn be_u16(buf: &[u8], at: usize) -> Option<u16> {
    bytes_at(buf, at).map(u16::from_be_bytes)
}

fn be_u32(buf: &[u8], at: usize) -> Option<u32> {
    bytes_at(buf, at).map(u32::from_be_bytes)
}

fn be_u64(buf: &[u8], at: usize) -> Option<u64> {
    bytes_at(buf, at).map(u64::from_be_bytes)
}

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
    if be_u16(buf, 0)? != 0x0101 || be_u32(buf, 4)? != STUN_MAGIC || bytes_at::<12>(buf, 8)? != txid
    {
        return None;
    }
    let key: [u8; 16] = bytes_at(buf, 4)?;
    let len = usize::from(be_u16(buf, 2)?);
    let body = buf.get(20..20usize.checked_add(len)?)?;
    let mut plain = None;
    let mut rest = body;
    while let (Some(kind), Some(alen)) = (be_u16(rest, 0), be_u16(rest, 2)) {
        let alen = usize::from(alen);
        let value = rest.get(4..4usize.checked_add(alen)?)?;
        match kind {
            0x0020 => return decode_addr(value, Some(&key)),
            0x0001 => plain = decode_addr(value, None),
            _ => {}
        }
        let step = alen.div_ceil(4).checked_mul(4)?.checked_add(4)?;
        let Some(next) = rest.get(step..) else { break };
        rest = next;
    }
    plain
}

fn decode_addr(value: &[u8], xor: Option<&[u8; 16]>) -> Option<SocketAddr> {
    let key = xor.copied().unwrap_or([0u8; 16]);
    let mut port = be_u16(value, 2)?;
    if xor.is_some() {
        port ^= be_u16(&key, 0)?;
    }
    match *value.get(1)? {
        0x01 => {
            let mut ip: [u8; 4] = bytes_at(value, 4)?;
            for (b, k) in ip.iter_mut().zip(key) {
                *b ^= k;
            }
            Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(ip)), port))
        }
        0x02 => {
            let mut ip: [u8; 16] = bytes_at(value, 4)?;
            for (b, k) in ip.iter_mut().zip(key) {
                *b ^= k;
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
        if buf.len() != PACKET_LEN || bytes_at::<4>(buf, 0)? != PROBE_MAGIC {
            return None;
        }
        let k = *buf.get(4)?;
        let kind = match k & 0x7f {
            1 => Kind::Punch { heard: k & 0x80 != 0 },
            2 => Kind::Ping,
            3 => Kind::Pong,
            _ => return None,
        };
        if be_u64(buf, 5)? != token {
            return None;
        }
        Some(Self { kind, token, seq: be_u32(buf, 13)?, sent_us: be_u64(buf, 17)? })
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
    v.get(rank.min(v.len()).saturating_sub(1)).copied()
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
        IpAddr::V6(v6) => !v6.is_unicast_link_local(),
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
