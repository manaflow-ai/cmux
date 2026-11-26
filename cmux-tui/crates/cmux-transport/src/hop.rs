//! hop/1: per-leg repair (RFD 0142 R4) and latest-wins (R5) on one relay
//! leg. The wire spec is `docs/cmux-next/relay-pop-hop.md`; this module is
//! its sans-IO implementation, used the same way by the phone, the Mac and
//! the UDP PoP (`cmux-hop-relay`).
//!
//! # Public API
//!
//! Codec (byte for byte what `tests/vectors/hop-frames.json` holds):
//!
//! ```text
//! pub const HOP_MAGIC: u8 = 0xC1;                  // first byte of every hop/1 datagram
//! pub fn is_hop(first_byte: u8) -> bool;           // also crate::classify::is_hop
//! pub enum HopClass { Control = 0, Interactive = 1, Input = 2, Bulk = 3, Media = 4 }
//! impl HopClass { fn from_byte(u8) -> Option<Self>; fn of_wireguard(&[u8]) -> Self }
//! pub struct StreamTag { pub key: u32, pub seq: u32 }
//! pub struct Record { pub class: HopClass, pub tag: Option<StreamTag>, pub bytes: Vec<u8> }
//! impl Record { fn new(HopClass, Vec<u8>) -> Self; fn tagged(key, seq, Vec<u8>) -> Self; fn encoded_len(&self) -> usize }
//! pub enum HopMsg { Data { seq, records }, Nack { base, bitmap, highest, loss_permille },
//!                   Parity { first_seq, count, len_xor, xor }, Bind { ticket }, BindOk { addr, lifetime_s },
//!                   Ping { nonce, sent_ms }, Pong { nonce, sent_ms, loss_permille }, Error { code } }
//! impl HopMsg { fn encode(&self) -> Result<Vec<u8>, HopError>; fn decode(&[u8]) -> Result<Self, HopError> }
//! pub fn decode_records(payload: &[u8]) -> Result<Vec<Record>, HopError>; // a DATA body after its 6-byte header
//! pub fn encode_records(records: &[Record]) -> Result<Vec<u8>, HopError>;
//! pub enum HopError { Short, Magic(u8), Type(u8), Trailing, NoRecords, RecordTruncated, Class(u8),
//!                     Flags(u8), TagClass, EmptyRecord, Family(u8), BadParity, TooLarge(usize) }
//! ```
//!
//! One leg endpoint (sender and receiver of one leg, both directions):
//!
//! ```text
//! pub struct Leg;
//! impl Leg {
//!     fn new(config: LegConfig, initial_seq: u32, now: Instant) -> Self; // initial_seq: random, from the caller
//!     fn send(&mut self, record: Record, now: Instant) -> Result<(), HopError>; // queue (R5 applies here)
//!     fn poll_transmit(&mut self, now: Instant) -> Option<Vec<u8>>;  // next datagram to put on the wire
//!     fn handle(&mut self, datagram: &[u8], now: Instant) -> Vec<Delivered>; // a datagram from the wire
//!     fn poll_timeout(&self) -> Option<Instant>;   // call poll_transmit again at or after this
//!     fn set_pacing_rate(&mut self, bytes_per_s: Option<u64>); // model or obey a congested leg
//!     fn queued_bytes(&self) -> usize;
//!     fn is_hop(&self) -> bool;                    // false while a Plain leg has seen no hop/1
//!     fn stats(&self) -> LegStats;
//! }
//! pub struct LegConfig { mode: LegMode, mtu: usize, nack: bool, fec: bool, latest_wins: bool,
//!                        initial_rtt: Duration, ping_interval: Duration, pacing_rate: Option<u64> }
//! pub enum LegMode { Hop, Plain }   // Plain: raw datagrams out, upgrades to Hop on the first hop/1 in
//! pub struct Delivered { pub record: Record, pub repair: Repair }
//! pub enum Repair { None, Nack, Fec }
//! pub struct LegStats { srtt, loss_permille, peer_loss_permille, sent, resent, parity_sent,
//!                       repaired_by_nack, repaired_by_fec, nacks_sent, dropped_superseded,
//!                       dropped_overflow, skipped_superseded_resend, tail_probes, delivered,
//!                       duplicates, malformed }
//! ```
//!
//! The PoP's forwarding core (two legs, records forwarded with their tag):
//!
//! ```text
//! pub enum Side { A, B }
//! pub struct HopRelay;
//! impl HopRelay {
//!     fn new(a: Leg, b: Leg) -> Self;
//!     fn handle(&mut self, from: Side, datagram: &[u8], now: Instant) -> usize; // records forwarded
//!     fn poll_transmit(&mut self, to: Side, now: Instant) -> Option<Vec<u8>>;
//!     fn poll_timeout(&self) -> Option<Instant>;
//!     fn leg(&self, Side) -> &Leg; fn leg_mut(&mut self, Side) -> &mut Leg;
//! }
//! ```
//!
//! The caller owns sockets and clocks: it feeds every received datagram to
//! [`Leg::handle`], drains [`Leg::poll_transmit`] (at the leg's rate when it
//! paces), and wakes at [`Leg::poll_timeout`]. Nothing here sleeps, spawns
//! or reads the clock.

mod leg;
mod queue;
mod relay;
mod rx;

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub use leg::{Delivered, Leg, LegConfig, LegMode, LegStats, Repair};
pub use relay::{HopRelay, Side};

pub const HOP_MAGIC: u8 = 0xC1;

pub const TYPE_DATA: u8 = 1;
pub const TYPE_NACK: u8 = 2;
pub const TYPE_PARITY: u8 = 3;
pub const TYPE_BIND: u8 = 4;
pub const TYPE_BIND_OK: u8 = 5;
pub const TYPE_PING: u8 = 6;
pub const TYPE_PONG: u8 = 7;
pub const TYPE_ERROR: u8 = 8;

/// `[magic][type][u32 hop_seq]`.
pub const DATA_HEADER_LEN: usize = 6;
/// Record flag: a `StreamTag` follows the flags byte.
pub const FLAG_TAGGED: u8 = 1;
/// Largest record a [`Leg`] accepts: one record plus the DATA and record
/// headers stays within a UDP payload and a u16 length.
pub const MAX_RECORD_BYTES: usize = 65_000;

/// Whether a datagram that starts with `first_byte` is hop/1. WireGuard
/// starts with 1 to 4 and STUN with two zero bits, so neither collides.
pub fn is_hop(first_byte: u8) -> bool {
    first_byte == HOP_MAGIC
}

/// What a record carries, highest priority first. A leg's egress queue
/// sends classes 0, 1 and 2 in strict order; bulk and media share the rest
/// by bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum HopClass {
    /// Handshakes and keepalives.
    Control = 0,
    /// Interactive state: latest-wins, tagged with its stream (R5).
    Interactive = 1,
    /// Input: keystrokes, TCP ACKs, small requests.
    Input = 2,
    /// Bulk transfers.
    Bulk = 3,
    /// Media (video).
    Media = 4,
}

impl HopClass {
    pub const ALL: [Self; 5] =
        [Self::Control, Self::Interactive, Self::Input, Self::Bulk, Self::Media];

    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Control),
            1 => Some(Self::Interactive),
            2 => Some(Self::Input),
            3 => Some(Self::Bulk),
            4 => Some(Self::Media),
            _ => None,
        }
    }

    pub(crate) fn index(self) -> usize {
        self as usize
    }

    /// The class of a plain WireGuard datagram by its shape, as
    /// `cmux-mobile-link`'s `send_class` does: handshakes and keepalives are
    /// control, data up to 400 bytes input, larger data bulk. A plain
    /// datagram is never interactive: only its sender can tag that.
    pub fn of_wireguard(datagram: &[u8]) -> Self {
        use crate::classify::{DatagramClass, WG_DATA_MIN_LEN, classify};
        match classify(datagram) {
            DatagramClass::WireGuardData if datagram.len() > 400 => Self::Bulk,
            DatagramClass::WireGuardData if datagram.len() > WG_DATA_MIN_LEN => Self::Input,
            DatagramClass::Unknown if datagram.len() > 400 => Self::Bulk,
            DatagramClass::Unknown => Self::Input,
            _ => Self::Control,
        }
    }
}

/// `(stream key id, key seq)` of a class-1 record: an opaque per-session id
/// and a counter. Only steers dropping; the authenticated inner header is
/// the truth.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct StreamTag {
    pub key: u32,
    pub seq: u32,
}

/// One datagram of the session (a WireGuard message) with its class.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub class: HopClass,
    pub tag: Option<StreamTag>,
    pub bytes: Vec<u8>,
}

impl Record {
    pub fn new(class: HopClass, bytes: Vec<u8>) -> Self {
        Self { class, tag: None, bytes }
    }

    /// A class-1 record of stream `key` at `seq`.
    pub fn tagged(key: u32, seq: u32, bytes: Vec<u8>) -> Self {
        Self { class: HopClass::Interactive, tag: Some(StreamTag { key, seq }), bytes }
    }

    /// Bytes this record takes inside a DATA datagram.
    pub fn encoded_len(&self) -> usize {
        4 + if self.tag.is_some() { 8 } else { 0 } + self.bytes.len()
    }

    pub(crate) fn encode_into(&self, out: &mut Vec<u8>) -> Result<(), HopError> {
        if self.tag.is_some() && self.class != HopClass::Interactive {
            return Err(HopError::TagClass);
        }
        if self.bytes.is_empty() {
            return Err(HopError::EmptyRecord);
        }
        let len =
            u16::try_from(self.bytes.len()).map_err(|_| HopError::TooLarge(self.bytes.len()))?;
        out.push(self.class as u8);
        match self.tag {
            Some(tag) => {
                out.push(FLAG_TAGGED);
                out.extend_from_slice(&tag.key.to_be_bytes());
                out.extend_from_slice(&tag.seq.to_be_bytes());
            }
            None => out.push(0),
        }
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(&self.bytes);
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HopMsg {
    Data { seq: u32, records: Vec<Record> },
    Nack { base: u32, bitmap: u64, highest: u32, loss_permille: u16 },
    Parity { first_seq: u32, count: u8, len_xor: u16, xor: Vec<u8> },
    Bind { ticket: Vec<u8> },
    BindOk { addr: SocketAddr, lifetime_s: u32 },
    Ping { nonce: u32, sent_ms: u32 },
    Pong { nonce: u32, sent_ms: u32, loss_permille: u16 },
    Error { code: u16 },
}

/// Why bytes are not a hop/1 message. Decoders check in the order the
/// vector file's `format` line gives.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HopError {
    /// Fewer bytes than the message's fixed fields (or BIND's ticket) need.
    Short,
    Magic(u8),
    Type(u8),
    /// Bytes past the end of a fixed-size message.
    Trailing,
    /// A DATA with no records.
    NoRecords,
    /// A record header or body runs past the datagram.
    RecordTruncated,
    Class(u8),
    /// Unknown flag bits in a record.
    Flags(u8),
    /// A tag on a record that is not class 1.
    TagClass,
    EmptyRecord,
    Family(u8),
    /// A PARITY with `count` 0 or no xor bytes.
    BadParity,
    /// Encode only: a field past its length prefix.
    TooLarge(usize),
}

impl HopMsg {
    pub fn encode(&self) -> Result<Vec<u8>, HopError> {
        let mut out = Vec::with_capacity(32);
        out.push(HOP_MAGIC);
        match self {
            Self::Data { seq, records } => {
                if records.is_empty() {
                    return Err(HopError::NoRecords);
                }
                out.push(TYPE_DATA);
                out.extend_from_slice(&seq.to_be_bytes());
                for record in records {
                    record.encode_into(&mut out)?;
                }
            }
            Self::Nack { base, bitmap, highest, loss_permille } => {
                out.push(TYPE_NACK);
                out.extend_from_slice(&base.to_be_bytes());
                out.extend_from_slice(&bitmap.to_be_bytes());
                out.extend_from_slice(&highest.to_be_bytes());
                out.extend_from_slice(&loss_permille.to_be_bytes());
            }
            Self::Parity { first_seq, count, len_xor, xor } => {
                if *count == 0 || xor.is_empty() {
                    return Err(HopError::BadParity);
                }
                out.push(TYPE_PARITY);
                out.extend_from_slice(&first_seq.to_be_bytes());
                out.push(*count);
                out.extend_from_slice(&len_xor.to_be_bytes());
                out.extend_from_slice(xor);
            }
            Self::Bind { ticket } => {
                let len =
                    u16::try_from(ticket.len()).map_err(|_| HopError::TooLarge(ticket.len()))?;
                out.push(TYPE_BIND);
                out.extend_from_slice(&len.to_be_bytes());
                out.extend_from_slice(ticket);
            }
            Self::BindOk { addr, lifetime_s } => {
                out.push(TYPE_BIND_OK);
                match addr.ip() {
                    IpAddr::V4(ip) => {
                        out.push(4);
                        out.extend_from_slice(&ip.octets());
                    }
                    IpAddr::V6(ip) => {
                        out.push(6);
                        out.extend_from_slice(&ip.octets());
                    }
                }
                out.extend_from_slice(&addr.port().to_be_bytes());
                out.extend_from_slice(&lifetime_s.to_be_bytes());
            }
            Self::Ping { nonce, sent_ms } => {
                out.push(TYPE_PING);
                out.extend_from_slice(&nonce.to_be_bytes());
                out.extend_from_slice(&sent_ms.to_be_bytes());
            }
            Self::Pong { nonce, sent_ms, loss_permille } => {
                out.push(TYPE_PONG);
                out.extend_from_slice(&nonce.to_be_bytes());
                out.extend_from_slice(&sent_ms.to_be_bytes());
                out.extend_from_slice(&loss_permille.to_be_bytes());
            }
            Self::Error { code } => {
                out.push(TYPE_ERROR);
                out.extend_from_slice(&code.to_be_bytes());
            }
        }
        Ok(out)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, HopError> {
        let Some((&magic, rest)) = bytes.split_first() else {
            return Err(HopError::Short);
        };
        if magic != HOP_MAGIC {
            return Err(HopError::Magic(magic));
        }
        let Some((&kind, body)) = rest.split_first() else {
            return Err(HopError::Short);
        };
        let mut r = Reader { rest: body };
        let msg = match kind {
            TYPE_DATA => {
                let seq = r.u32().ok_or(HopError::Short)?;
                return Ok(Self::Data { seq, records: decode_records(r.rest)? });
            }
            TYPE_NACK => {
                let (Some(base), Some(bitmap), Some(highest), Some(loss_permille)) =
                    (r.u32(), r.u64(), r.u32(), r.u16())
                else {
                    return Err(HopError::Short);
                };
                Self::Nack { base, bitmap, highest, loss_permille }
            }
            TYPE_PARITY => {
                let (Some(first_seq), Some(count), Some(len_xor)) = (r.u32(), r.u8(), r.u16())
                else {
                    return Err(HopError::Short);
                };
                if count == 0 || r.rest.is_empty() {
                    return Err(HopError::BadParity);
                }
                return Ok(Self::Parity { first_seq, count, len_xor, xor: r.rest.to_vec() });
            }
            TYPE_BIND => {
                let len = r.u16().ok_or(HopError::Short)?;
                let ticket = r.take(usize::from(len)).ok_or(HopError::Short)?;
                Self::Bind { ticket: ticket.to_vec() }
            }
            TYPE_BIND_OK => {
                let family = r.u8().ok_or(HopError::Short)?;
                let ip = match family {
                    4 => {
                        let octets: [u8; 4] =
                            r.take(4).and_then(|b| b.try_into().ok()).ok_or(HopError::Short)?;
                        IpAddr::V4(Ipv4Addr::from(octets))
                    }
                    6 => {
                        let octets: [u8; 16] =
                            r.take(16).and_then(|b| b.try_into().ok()).ok_or(HopError::Short)?;
                        IpAddr::V6(Ipv6Addr::from(octets))
                    }
                    other => return Err(HopError::Family(other)),
                };
                let (Some(port), Some(lifetime_s)) = (r.u16(), r.u32()) else {
                    return Err(HopError::Short);
                };
                Self::BindOk { addr: SocketAddr::new(ip, port), lifetime_s }
            }
            TYPE_PING => {
                let (Some(nonce), Some(sent_ms)) = (r.u32(), r.u32()) else {
                    return Err(HopError::Short);
                };
                Self::Ping { nonce, sent_ms }
            }
            TYPE_PONG => {
                let (Some(nonce), Some(sent_ms), Some(loss_permille)) = (r.u32(), r.u32(), r.u16())
                else {
                    return Err(HopError::Short);
                };
                Self::Pong { nonce, sent_ms, loss_permille }
            }
            TYPE_ERROR => Self::Error { code: r.u16().ok_or(HopError::Short)? },
            other => return Err(HopError::Type(other)),
        };
        if !r.rest.is_empty() {
            return Err(HopError::Trailing);
        }
        Ok(msg)
    }
}

/// The records of a DATA body (everything after `[magic][type][u32 seq]`),
/// or of a relay frame that carries the same record layout. At least one
/// record; errors as [`HopMsg::decode`] gives them for a DATA.
pub fn decode_records(payload: &[u8]) -> Result<Vec<Record>, HopError> {
    if payload.is_empty() {
        return Err(HopError::NoRecords);
    }
    let mut r = Reader { rest: payload };
    let mut records = Vec::new();
    while !r.rest.is_empty() {
        records.push(decode_record(&mut r)?);
    }
    Ok(records)
}

/// The inverse of [`decode_records`].
pub fn encode_records(records: &[Record]) -> Result<Vec<u8>, HopError> {
    if records.is_empty() {
        return Err(HopError::NoRecords);
    }
    let mut out = Vec::with_capacity(records.iter().map(Record::encoded_len).sum());
    for record in records {
        record.encode_into(&mut out)?;
    }
    Ok(out)
}

/// `[u8 class][u8 flags][u32 key, u32 key_seq if flags & 1][u16 len][bytes]`,
/// checked in that order.
fn decode_record(r: &mut Reader<'_>) -> Result<Record, HopError> {
    let (Some(class_byte), Some(flags)) = (r.u8(), r.u8()) else {
        return Err(HopError::RecordTruncated);
    };
    let class = HopClass::from_byte(class_byte).ok_or(HopError::Class(class_byte))?;
    if flags & !FLAG_TAGGED != 0 {
        return Err(HopError::Flags(flags));
    }
    let tag = if flags & FLAG_TAGGED != 0 {
        if class != HopClass::Interactive {
            return Err(HopError::TagClass);
        }
        let (Some(key), Some(seq)) = (r.u32(), r.u32()) else {
            return Err(HopError::RecordTruncated);
        };
        Some(StreamTag { key, seq })
    } else {
        None
    };
    let len = r.u16().ok_or(HopError::RecordTruncated)?;
    if len == 0 {
        return Err(HopError::EmptyRecord);
    }
    let bytes = r.take(usize::from(len)).ok_or(HopError::RecordTruncated)?;
    Ok(Record { class, tag, bytes: bytes.to_vec() })
}

struct Reader<'a> {
    rest: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        let (head, tail) = self.rest.split_at_checked(len)?;
        self.rest = tail;
        Some(head)
    }

    fn array<const N: usize>(&mut self) -> Option<[u8; N]> {
        let (head, tail) = self.rest.split_first_chunk::<N>()?;
        self.rest = tail;
        Some(*head)
    }

    fn u8(&mut self) -> Option<u8> {
        self.array::<1>().map(|[b]| b)
    }

    fn u16(&mut self) -> Option<u16> {
        self.array().map(u16::from_be_bytes)
    }

    fn u32(&mut self) -> Option<u32> {
        self.array().map(u32::from_be_bytes)
    }

    fn u64(&mut self) -> Option<u64> {
        self.array().map(u64::from_be_bytes)
    }
}

/// `a` is later than `b` in a wrapping u32 sequence space.
pub(crate) fn seq_newer(a: u32, b: u32) -> bool {
    (a.wrapping_sub(b) as i32) > 0
}

#[cfg(test)]
#[path = "hop_tests.rs"]
mod tests;
