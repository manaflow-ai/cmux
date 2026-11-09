//! Ultra mode: spend extra bandwidth so a lossy link stops costing time.
//!
//! Every stream in the tunnel is TCP inside WireGuard, and smoltcp has no
//! SACK, so one lost datagram stalls its stream for a fast retransmit (one
//! round trip) or a retransmission timeout (200 ms to over 1 s). On a link
//! that drops 1 to 10 % of packets at random (cellular, hotel Wi-Fi, a long
//! international path) that is most of the latency. Ultra mode sends the
//! repair data up front, below WireGuard, so the receiver rebuilds a lost
//! datagram from what did arrive instead of waiting for TCP:
//!
//! - `dup` / `dupN` sends every datagram N times (default 2). The receiver
//!   needs no support: WireGuard's replay window drops the extra copies.
//!   Costs N times the bytes.
//! - `fec` / `fec:K:M` closes a group after K data datagrams or at the end of
//!   each driver pass, whichever comes first, and sends up to M parity
//!   datagrams after it. Parity `j` is the XOR of the ciphertexts of members
//!   `j, j + P, j + 2P, ...` (P parities in the group), so the receiver
//!   rebuilds any one lost member per parity, and a burst of up to P
//!   consecutive losses. Groups end at each pass so a lone keystroke is
//!   protected at once instead of waiting for K-1 more packets. Handshake
//!   messages are sent twice. A full group costs (K+M)/K of its datagrams;
//!   a parity is as long as the longest member it covers, and short groups
//!   (a pass with few datagrams) get a parity of their own, so bytes run
//!   higher in practice (1.25-1.35x for `fec:8:2` on the desktop bench) and
//!   never above twice the data bytes.
//! - `rs` / `rs:K:M` (default `rs:4:4`) groups datagrams the same way, but its
//!   parities are Reed-Solomon over GF(2^8) ([`crate::ultra_rs`]): any `n` of
//!   a group's parities rebuild any `n` of its lost members, wherever they
//!   fall, where XOR parity loses a group to two losses in one subgroup. A
//!   group of `n` members gets `ceil(n * M / K)` parities, and at least two
//!   (one when M is 1): most groups are a pass's one or two datagrams, and
//!   with one parity those are what still stall TCP at 10 % loss. Each parity
//!   is as long as the longest member, so a full group costs (K+M)/K and a
//!   lone datagram 3x; bytes stay under (1+M)x. It holds at loss rates where
//!   XOR parity collapses (10 %).
//!
//! A parity datagram is a header plus the XOR of ciphertexts; the WireGuard
//! header of a rebuilt datagram comes from the parity header, so a parity is
//! never larger than the largest member and fits the same path MTU. It
//! starts with [`TAG`], which no WireGuard or STUN message starts with: a
//! peer without ultra mode hands it to boringtun, which refuses it, so turning
//! the mode on never breaks an older peer, it only wastes the parity bytes.
//! Parity itself is not authenticated, so a receiver acts on parity only from
//! an origin (path and address) WireGuard has already authenticated a datagram
//! from, and keeps a data datagram (received or rebuilt) for rebuilding only
//! once WireGuard has authenticated that datagram itself. Rebuilding is
//! automatic: any side rebuilds from trusted parity, whatever its own mode.
//! Sending repair data is not learned from parity: the parity header is not
//! authenticated, and an on-path attacker could rewrap a genuine ciphertext as
//! parity whose rebuilt datagram authenticates, so a mode learned from parity
//! would be the attacker's choice. The two sides agree on the mode inside the
//! tunnel instead ([`crate::ultra_hello`]): each sends the mode it was started
//! with in an authenticated hello, and both send in the stronger of the two
//! ([`UltraMode::agree`]), so turning the mode on at one end protects both
//! directions.
//!
//! The mode is the `CMUX_WG_ULTRA` environment variable (`off`, `dup`,
//! `dup3`, `fec`, `fec:8:2`, `rs`, `rs:8:4`), read when a tunnel starts, else
//! the app's setting in [`crate::WgConfig::ultra`] ([`UltraMode::SETTING`]:
//! desktop `remote.ultraMode`, the iPhone's "Ultra mode on cellular").

use std::collections::{HashMap, VecDeque};
use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::{Context, Poll, ready};

use cmux_transport::{DatagramClass, PathId, classify};
use tokio::time::Instant;

use crate::pacing::Priority;
use crate::underlay::{DueProbes, Origin, Received, Underlay};

/// First byte of a parity datagram. WireGuard messages start with 1 to 4 and
/// STUN messages with two zero bits.
pub const TAG: u8 = 0xCF;
/// Parity header version for XOR parity.
const VERSION: u8 = 1;
/// Parity header version for Reed-Solomon parity: the same 16-byte layout,
/// with bytes 6-7 carrying the Reed-Solomon code of the members' lengths
/// instead of their XOR. A receiver that knows only version 1 ignores it.
const VERSION_RS: u8 = 2;
const PARITY_HEADER: usize = 16;
/// Type, receiver index and counter in front of a WireGuard data message's
/// ciphertext.
const WG_DATA_HEADER: usize = 16;
/// Received data datagrams kept for rebuilding. Parity follows its group
/// within one pass, so a few groups' worth is enough.
const KEEP: usize = 256;
/// Longest ciphertext kept: a path MTU's worth with room to spare. Bigger
/// datagrams are not kept, so the kept set stays under 512 KiB.
const MAX_KEPT: usize = 2048;
/// Parities waiting for a late (reordered) member or for more parities of
/// their group, newest last.
const PENDING: usize = 64;
/// Longest parity kept waiting: a parity covers members no longer than
/// [`MAX_KEPT`], so the waiting set stays under 132 KiB.
const MAX_PENDING_PARITY: usize = PARITY_HEADER + MAX_KEPT;
/// Origins WireGuard authenticated, newest last (paths of a multipath carrier,
/// and the address after a roam).
const TRUSTED: usize = 8;
/// Parity datagrams one `poll_recv` reads before it yields, so a flood of them
/// (trusted or not) cannot keep the driver from its other work.
const PARITY_PER_POLL: usize = 64;
const MAX_GROUP: u8 = 32;
const MAX_PARITY: u8 = 15;
const MAX_COPIES: u8 = 4;
/// The most bytes per data byte a peer can ask this side to send: a peer's
/// mode is taken up only when its full groups cost at most this many
/// datagrams per data datagram, and in a mode taken up from the peer the
/// bytes of each group (its datagrams and their repair) stay within this
/// multiple of its data bytes ([`rs_parity_datagrams`]).
const MAX_AGREED_OVERHEAD: u32 = 4;
/// The environment variable that turns the mode on.
pub const ENV: &str = "CMUX_WG_ULTRA";
/// `none` turns the tunnel's TCP congestion control off, so loss never
/// shrinks a window and each stream runs at what its window and the pacer
/// allow (Hysteria's "Brutal" idea, bounded by the 256 KiB window). For
/// benches: it is unfair to other traffic on a congested link.
pub const CC_ENV: &str = "CMUX_WG_ULTRA_CC";

/// Whether `datagram` is an ultra-mode parity datagram. A carrier that
/// classifies datagrams by shape should give parity the class the tunnel's
/// pacer sent it in, not treat it as control.
pub fn is_parity(datagram: &[u8]) -> bool {
    datagram.first() == Some(&TAG)
}

/// Whether [`CC_ENV`] asks for no congestion control.
pub(crate) fn loss_blind_from_env() -> bool {
    std::env::var(CC_ENV).is_ok_and(|value| value.trim().eq_ignore_ascii_case("none"))
}

/// How much repair data a tunnel sends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum UltraMode {
    #[default]
    Off,
    /// Every datagram `copies` times.
    Duplicate { copies: u8 },
    /// Up to `parity` XOR parities per group of up to `group` data datagrams.
    Fec { group: u8, parity: u8 },
    /// Up to `parity` Reed-Solomon parities per group of up to `group` data
    /// datagrams: any `parity` losses in a full group are rebuilt.
    Rs { group: u8, parity: u8 },
}

impl UltraMode {
    /// `off`, `dup`, `dupN`, `fec`, `fec:K:M`, `rs` or `rs:K:M`; `None` for
    /// anything else.
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim().to_ascii_lowercase();
        match text.as_str() {
            "" | "off" | "0" | "false" => return Some(Self::Off),
            "dup" => return Some(Self::Duplicate { copies: 2 }),
            "fec" => return Some(Self::Fec { group: 8, parity: 2 }),
            "rs" => return Some(Self::Rs { group: 4, parity: 4 }),
            _ => {}
        }
        if let Some(copies) = text.strip_prefix("dup") {
            let copies: u8 = copies.trim_start_matches(':').parse().ok()?;
            return (2..=MAX_COPIES).contains(&copies).then_some(Self::Duplicate { copies });
        }
        let (rs, rest) = match text.strip_prefix("rs:") {
            Some(rest) => (true, rest),
            None => (false, text.strip_prefix("fec:")?),
        };
        let (group, parity) = rest.split_once(':')?;
        let (group, parity): (u8, u8) = (group.parse().ok()?, parity.parse().ok()?);
        if rs { Self::rs(group, parity) } else { Self::fec(group, parity) }
    }

    /// This mode within the limits [`UltraMode::parse`] accepts: a value
    /// built in code with out-of-range fields becomes the nearest valid mode,
    /// or off.
    fn normalized(self) -> Self {
        match self {
            Self::Off => Self::Off,
            Self::Duplicate { copies } if copies < 2 => Self::Off,
            Self::Duplicate { copies } => Self::Duplicate { copies: copies.min(MAX_COPIES) },
            Self::Fec { group, parity } => Self::fec(group, parity).unwrap_or(Self::Off),
            Self::Rs { group, parity } => Self::rs(group, parity).unwrap_or(Self::Off),
        }
    }

    /// Reed-Solomon parity may outnumber a group's members (a lone datagram
    /// with two parities survives any two of the three being lost).
    fn rs(group: u8, parity: u8) -> Option<Self> {
        ((1..=MAX_GROUP).contains(&group) && (1..=MAX_PARITY).contains(&parity))
            .then_some(Self::Rs { group, parity })
    }

    fn fec(group: u8, parity: u8) -> Option<Self> {
        ((1..=MAX_GROUP).contains(&group) && (1..=MAX_PARITY.min(group)).contains(&parity))
            .then_some(Self::Fec { group, parity })
    }

    /// The mode an app's "ultra mode" setting turns on: Reed-Solomon `rs:4:4`,
    /// which holds the lossless latency up to 10 % random loss on the desktop
    /// bench at about 2.4-2.9x the bytes (#38861).
    pub const SETTING: Self = Self::Rs { group: 4, parity: 4 };

    /// The mode a tunnel starts with: [`ENV`] when it is set and not empty
    /// (so `CMUX_WG_ULTRA=off` turns a setting's mode off for one run), else
    /// the app's `setting`, else off. An unreadable [`ENV`] is reported and
    /// the setting applies.
    pub fn resolve(setting: Option<Self>) -> Self {
        Self::resolve_with(std::env::var(ENV).ok().as_deref(), setting)
    }

    /// [`UltraMode::resolve`] with [`ENV`]'s value given.
    fn resolve_with(env: Option<&str>, setting: Option<Self>) -> Self {
        let fallback = setting.unwrap_or(Self::Off);
        match env.map(str::trim).filter(|text| !text.is_empty()) {
            None => fallback,
            Some(text) => Self::parse(text).unwrap_or_else(|| {
                eprintln!(
                    "{ENV}={text:?} is not off, dup, dupN, fec, fec:K:M, rs or rs:K:M; using {fallback:?}"
                );
                fallback
            }),
        }
    }

    /// The mode in [`ENV`], or off when it is unset or unreadable.
    pub fn from_env() -> Self {
        match std::env::var(ENV) {
            Ok(text) => Self::parse(&text).unwrap_or_else(|| {
                eprintln!(
                    "{ENV}={text:?} is not off, dup, dupN, fec, fec:K:M, rs or rs:K:M; ultra mode is off"
                );
                Self::Off
            }),
            Err(_) => Self::Off,
        }
    }

    /// Datagrams sent per data datagram: for FEC with full groups (bytes can
    /// run higher, at most 2x), and in every case for duplication.
    pub fn overhead_under_load(self) -> f64 {
        match self {
            Self::Off => 1.0,
            Self::Duplicate { copies } => f64::from(copies),
            Self::Fec { group, parity } | Self::Rs { group, parity } => {
                f64::from(group + parity) / f64::from(group)
            }
        }
    }

    /// The mode a side started with `own` sends in once the peer says it
    /// started with `peer`: the one that sends more repair data (ties go to
    /// the stronger code: Reed-Solomon, then XOR, then copies), so both sides
    /// land on the same mode. A peer's mode costing more than
    /// [`MAX_AGREED_OVERHEAD`] times the datagrams is not taken up (this
    /// side keeps `own`). Reed-Solomon parity is as long as a group's longest
    /// datagram, so the datagram count alone would let bytes run higher when
    /// sizes differ; a side sending in a mode it took up from the peer also
    /// caps each group's repair bytes, so an authenticated peer can ask this
    /// side for up to 4x the bytes, no more.
    pub fn agree(own: Self, peer: Self) -> Self {
        let (own, peer) = (own.normalized(), peer.normalized());
        let costly = peer.overhead_under_load() > f64::from(MAX_AGREED_OVERHEAD);
        if costly || own.strength_cmp(peer).is_ge() { own } else { peer }
    }

    /// A total order on modes: bytes sent, then the code, then its numbers.
    fn strength_cmp(self, other: Self) -> std::cmp::Ordering {
        let key = |mode: Self| {
            let (kind, a, b) = mode.wire();
            let rank = match mode {
                Self::Off => 0,
                Self::Duplicate { .. } => 1,
                Self::Fec { .. } => 2,
                Self::Rs { .. } => 3,
            };
            (mode.overhead_under_load(), rank, kind, b, a)
        };
        let ((left, l1, l2, l3, l4), (right, r1, r2, r3, r4)) = (key(self), key(other));
        left.total_cmp(&right).then((l1, l2, l3, l4).cmp(&(r1, r2, r3, r4)))
    }

    /// The mode as the hello carries it: a kind byte and two numbers.
    pub(crate) fn wire(self) -> (u8, u8, u8) {
        match self {
            Self::Off => (0, 0, 0),
            Self::Duplicate { copies } => (1, copies, 0),
            Self::Fec { group, parity } => (2, group, parity),
            Self::Rs { group, parity } => (3, group, parity),
        }
    }

    /// The mode a hello carries, within limits; off for a kind this side does
    /// not know.
    pub(crate) fn from_wire(kind: u8, a: u8, b: u8) -> Self {
        let mode = match kind {
            1 => Self::Duplicate { copies: a },
            2 => Self::Fec { group: a, parity: b },
            3 => Self::Rs { group: a, parity: b },
            _ => Self::Off,
        };
        mode.normalized()
    }

    /// Parities for a group of `members`: in proportion to `parity / group`,
    /// at least one, so a small group pays no more than a full one would.
    fn parities_for(group: u8, parity: u8, members: usize) -> usize {
        let wanted = (members * usize::from(parity)).div_ceil(usize::from(group).max(1));
        wanted.clamp(1, usize::from(parity).min(members.max(1)))
    }

    /// Reed-Solomon parities for a group of `members`: in proportion like
    /// [`Self::parities_for`], not capped at the member count, and at least
    /// two (when `parity` allows), so a pass's lone datagram survives any two
    /// of its three datagrams being lost.
    fn rs_parities_for(group: u8, parity: u8, members: usize) -> usize {
        let wanted = (members * usize::from(parity)).div_ceil(usize::from(group).max(1));
        wanted.clamp(usize::from(parity).clamp(1, 2), usize::from(parity).max(1))
    }
}

/// What ultra mode did, for benches and diagnostics.
#[derive(Debug, Default)]
pub struct UltraCounters {
    /// Extra copies sent in duplicate mode, and handshakes sent twice.
    pub copies_sent: AtomicU64,
    pub parity_sent: AtomicU64,
    pub parity_received: AtomicU64,
    /// Datagrams rebuilt from parity.
    pub recovered: AtomicU64,
    /// Repair bytes sent beyond the data itself.
    pub overhead_bytes: AtomicU64,
    /// Bytes of the datagrams themselves, once each: the base the repair
    /// bytes are an overhead on.
    pub data_bytes: AtomicU64,
}

/// A snapshot of [`UltraCounters`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UltraStats {
    pub copies_sent: u64,
    pub parity_sent: u64,
    pub parity_received: u64,
    pub recovered: u64,
    pub overhead_bytes: u64,
    pub data_bytes: u64,
}

impl UltraCounters {
    pub fn snapshot(&self) -> UltraStats {
        UltraStats {
            copies_sent: self.copies_sent.load(Ordering::Relaxed),
            parity_sent: self.parity_sent.load(Ordering::Relaxed),
            parity_received: self.parity_received.load(Ordering::Relaxed),
            recovered: self.recovered.load(Ordering::Relaxed),
            overhead_bytes: self.overhead_bytes.load(Ordering::Relaxed),
            data_bytes: self.data_bytes.load(Ordering::Relaxed),
        }
    }

    fn add(counter: &AtomicU64, by: u64) {
        counter.fetch_add(by, Ordering::Relaxed);
    }
}

/// The receiver index and counter of a WireGuard data message.
fn data_id(datagram: &[u8]) -> Option<([u8; 4], u64)> {
    if classify(datagram) != DatagramClass::WireGuardData {
        return None;
    }
    let index: [u8; 4] = datagram.get(4..8)?.try_into().ok()?;
    let counter: [u8; 8] = datagram.get(8..16)?.try_into().ok()?;
    Some((index, u64::from_le_bytes(counter)))
}

/// The data datagrams of the group being sent.
struct Group {
    index: [u8; 4],
    first: u64,
    ciphertexts: Vec<Vec<u8>>,
    priority: Option<Priority>,
}

/// The parity datagrams for one closed group.
fn parity_datagrams(group: &Group, k: u8, m: u8) -> Vec<Vec<u8>> {
    let members = group.ciphertexts.len();
    let parities = UltraMode::parities_for(k, m, members);
    (0..parities)
        .map(|j| {
            let subgroup = group.ciphertexts.iter().skip(j).step_by(parities);
            let longest = subgroup.clone().map(Vec::len).max().unwrap_or(0);
            let mut xor = vec![0u8; longest];
            let mut lengths = 0u16;
            for ciphertext in subgroup {
                lengths ^= u16::try_from(ciphertext.len()).unwrap_or(u16::MAX);
                for (slot, byte) in xor.iter_mut().zip(ciphertext) {
                    *slot ^= byte;
                }
            }
            let mut header = [0u8; PARITY_HEADER];
            header[0] = TAG;
            header[1] = VERSION;
            header[2] = j as u8;
            header[3] = (m << 4) | parities as u8;
            header[4] = members as u8;
            header[5] = k;
            header[6..8].copy_from_slice(&lengths.to_be_bytes());
            header[8..12].copy_from_slice(&group.index);
            header[12..16].copy_from_slice(&(group.first as u32).to_le_bytes());
            let mut out = Vec::with_capacity(PARITY_HEADER + longest);
            out.extend_from_slice(&header);
            out.extend_from_slice(&xor);
            out
        })
        .collect()
}

/// The Reed-Solomon parity datagrams for one closed group: the XOR layout,
/// version [`VERSION_RS`], bytes 6-7 the length code.
///
/// Each parity is as long as the group's longest datagram, so a group of one
/// full datagram and small ones (a frame and keystrokes) would send several
/// times its bytes in parity. `capped` (a mode taken up from the peer) keeps
/// the group's datagrams and parity within [`MAX_AGREED_OVERHEAD`] times its
/// data bytes by sending fewer parities, at least one. XOR parity needs no
/// cap: each member is in one subgroup, so it is at most 2x the bytes.
fn rs_parity_datagrams(group: &Group, k: u8, m: u8, capped: bool) -> Vec<Vec<u8>> {
    let members = group.ciphertexts.len();
    let mut parities = UltraMode::rs_parities_for(k, m, members);
    if capped {
        parities = parities.min(rs_parity_budget(&group.ciphertexts));
    }
    (0..parities)
        .filter_map(|j| {
            let (code, body) = crate::ultra_rs::encode(j, &group.ciphertexts)?;
            let mut header = [0u8; PARITY_HEADER];
            header[0] = TAG;
            header[1] = VERSION_RS;
            header[2] = u8::try_from(j).ok()?;
            header[3] = (m << 4) | u8::try_from(parities).ok()?;
            header[4] = u8::try_from(members).ok()?;
            header[5] = k;
            header[6..8].copy_from_slice(&code);
            header[8..12].copy_from_slice(&group.index);
            header[12..16].copy_from_slice(&(group.first as u32).to_le_bytes());
            let mut out = Vec::with_capacity(PARITY_HEADER + body.len());
            out.extend_from_slice(&header);
            out.extend_from_slice(&body);
            Some(out)
        })
        .collect()
}

/// The most Reed-Solomon parities a group of `ciphertexts` sends in a mode
/// taken up from the peer: repair bytes at most `MAX_AGREED_OVERHEAD - 1`
/// times the group's data bytes (whole datagrams, header and all), and at
/// least one parity.
fn rs_parity_budget(ciphertexts: &[Vec<u8>]) -> usize {
    let data: usize = ciphertexts.iter().map(|ciphertext| WG_DATA_HEADER + ciphertext.len()).sum();
    let parity = PARITY_HEADER + ciphertexts.iter().map(Vec::len).max().unwrap_or(0);
    let repair = data * (MAX_AGREED_OVERHEAD as usize - 1);
    (repair / parity.max(1)).max(1)
}

/// Which code a parity carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Code {
    Xor,
    ReedSolomon,
}

/// A parsed parity header. Bytes 3 (high nibble) and 5 carry the sender's
/// M and K; they are not read, since a mode learned from unauthenticated
/// parity would be an attacker's choice.
struct Parity<'a> {
    code: Code,
    j: usize,
    parities: usize,
    members: usize,
    lengths: u16,
    index: [u8; 4],
    first_low: u32,
    xor: &'a [u8],
}

fn parse_parity(datagram: &[u8]) -> Option<Parity<'_>> {
    let header: [u8; PARITY_HEADER] = datagram.get(..PARITY_HEADER)?.try_into().ok()?;
    let code = match (header[0], header[1]) {
        (TAG, VERSION) => Code::Xor,
        (TAG, VERSION_RS) => Code::ReedSolomon,
        _ => return None,
    };
    let parities = usize::from(header[3] & 0x0F);
    let (j, members) = (usize::from(header[2]), usize::from(header[4]));
    if parities == 0 || j >= parities || members == 0 || members > usize::from(MAX_GROUP) {
        return None;
    }
    Some(Parity {
        code,
        j,
        parities,
        members,
        lengths: u16::from_be_bytes([header[6], header[7]]),
        index: [header[8], header[9], header[10], header[11]],
        first_low: u32::from_le_bytes([header[12], header[13], header[14], header[15]]),
        xor: datagram.get(PARITY_HEADER..)?,
    })
}

/// The group a Reed-Solomon parity belongs to: its siblings share it.
type GroupKey = ([u8; 4], u32, usize, usize);

impl Parity<'_> {
    fn group_key(&self) -> GroupKey {
        (self.index, self.first_low, self.members, self.parities)
    }
}

/// The rebuilt WireGuard data datagram for `ciphertext` at `counter`.
fn data_datagram(index: [u8; 4], counter: u64, ciphertext: &[u8]) -> Vec<u8> {
    let mut datagram = Vec::with_capacity(WG_DATA_HEADER + ciphertext.len());
    datagram.extend_from_slice(&[4, 0, 0, 0]);
    datagram.extend_from_slice(&index);
    datagram.extend_from_slice(&counter.to_le_bytes());
    datagram.extend_from_slice(ciphertext);
    datagram
}

/// The full counter whose low 32 bits are `low`, nearest to `near`.
fn widen(low: u32, near: u64) -> u64 {
    let base = (near & !0xFFFF_FFFF) | u64::from(low);
    [base.wrapping_sub(1 << 32), base, base.wrapping_add(1 << 32)]
        .into_iter()
        .min_by_key(|candidate| candidate.abs_diff(near))
        .unwrap_or(base)
}

/// What a parity can do with the members received so far.
#[derive(Debug, PartialEq, Eq)]
enum Rebuild {
    /// Exactly one member was missing: here it is.
    Done(Vec<u8>),
    /// Reed-Solomon: every missing member, rebuilt.
    DoneAll(Vec<Vec<u8>>),
    /// Nothing to do: every member arrived, or the parity is malformed.
    Whole,
    /// Two or more members are missing; a late one may still arrive.
    Waiting,
}

impl Rebuild {
    #[cfg(test)]
    fn rebuilt(self) -> Option<Vec<u8>> {
        match self {
            Self::Done(datagram) => Some(datagram),
            _ => None,
        }
    }
}

/// Received data ciphertexts, for rebuilding a lost one from parity.
#[derive(Default)]
struct Kept {
    kept: HashMap<([u8; 4], u64), Vec<u8>>,
    order: VecDeque<([u8; 4], u64)>,
    newest: HashMap<[u8; 4], u64>,
}

impl Kept {
    fn keep(&mut self, index: [u8; 4], counter: u64, ciphertext: &[u8]) {
        if ciphertext.len() > MAX_KEPT {
            return;
        }
        let newest = self.newest.entry(index).or_insert(counter);
        *newest = (*newest).max(counter);
        if self.kept.insert((index, counter), ciphertext.to_vec()).is_none() {
            self.order.push_back((index, counter));
        }
        while self.order.len() > KEEP {
            if let Some(old) = self.order.pop_front() {
                self.kept.remove(&old);
            }
        }
        if self.newest.len() > 8 {
            // Sessions rotate every two minutes; forget all but the live one.
            self.newest.retain(|kept, _| *kept == index);
        }
    }

    /// The first counter of `parity`'s group, once a member of its session
    /// arrived.
    fn first(&self, parity: &Parity<'_>) -> Option<u64> {
        let near = *self.newest.get(&parity.index)?;
        Some(widen(parity.first_low, near))
    }

    /// The datagram rebuilt from `parity`, when exactly one member of its
    /// subgroup is missing.
    fn rebuild(&self, parity: &Parity<'_>) -> Rebuild {
        let Some(first) = self.first(parity) else { return Rebuild::Waiting };
        let mut missing = None;
        let mut xor = parity.xor.to_vec();
        let mut lengths = parity.lengths;
        for member in (parity.j..parity.members).step_by(parity.parities) {
            let counter = first.wrapping_add(member as u64);
            match self.kept.get(&(parity.index, counter)) {
                Some(ciphertext) => {
                    lengths ^= u16::try_from(ciphertext.len()).unwrap_or(u16::MAX);
                    for (slot, byte) in xor.iter_mut().zip(ciphertext) {
                        *slot ^= byte;
                    }
                }
                None if missing.is_none() => missing = Some(counter),
                None => return Rebuild::Waiting,
            }
        }
        let Some(counter) = missing else { return Rebuild::Whole };
        let length = usize::from(lengths);
        let Some(body) = xor.get(..length).filter(|_| length >= WG_DATA_HEADER) else {
            return Rebuild::Whole;
        };
        Rebuild::Done(data_datagram(parity.index, counter, body))
    }

    /// The datagrams rebuilt from the Reed-Solomon `parities` of one group
    /// (siblings: one [`GroupKey`]), once no more members are missing than
    /// distinct parities arrived.
    fn rebuild_rs(&self, parities: &[Parity<'_>]) -> Rebuild {
        let Some(first_parity) = parities.first() else { return Rebuild::Whole };
        let Some(first) = self.first(first_parity) else { return Rebuild::Waiting };
        let mut received = Vec::new();
        let mut missing = Vec::new();
        for member in 0..first_parity.members {
            match self.kept.get(&(first_parity.index, first.wrapping_add(member as u64))) {
                Some(ciphertext) => received.push((member, ciphertext.as_slice())),
                None => missing.push(member),
            }
        }
        if missing.is_empty() {
            return Rebuild::Whole;
        }
        let mut shards: Vec<crate::ultra_rs::Shard<'_>> = Vec::with_capacity(missing.len());
        for parity in parities {
            if shards.len() == missing.len() {
                break;
            }
            if !shards.iter().any(|shard| shard.parity == parity.j) {
                shards.push(crate::ultra_rs::Shard {
                    parity: parity.j,
                    code: parity.lengths.to_be_bytes(),
                    body: parity.xor,
                });
            }
        }
        if shards.len() < missing.len() {
            return Rebuild::Waiting;
        }
        let Some(ciphertexts) = crate::ultra_rs::decode(&shards, &received, &missing) else {
            return Rebuild::Whole;
        };
        if ciphertexts.iter().any(|ciphertext| ciphertext.len() < WG_DATA_HEADER) {
            return Rebuild::Whole;
        }
        let rebuilt = missing
            .iter()
            .zip(ciphertexts)
            .map(|(member, ciphertext)| {
                data_datagram(first_parity.index, first.wrapping_add(*member as u64), &ciphertext)
            })
            .collect();
        Rebuild::DoneAll(rebuilt)
    }
}

/// The driver's underlay: the carrier it was given, plus ultra mode's repair
/// data on the way out and rebuilding on the way in. With the mode off and no
/// parity from the peer it only forwards.
pub(crate) struct UltraUnderlay {
    inner: Box<dyn Underlay>,
    mode: UltraMode,
    /// The mode this side was started with; a different `mode` was taken up
    /// from the peer, and its repair bytes are capped.
    configured: UltraMode,
    group: Option<Group>,
    received: Kept,
    /// Rebuild from parity: on when this side sends FEC or the peer does.
    decoding: bool,
    /// Parities still waiting for a member, with where they came from.
    pending: VecDeque<(Vec<u8>, Origin)>,
    /// Origins WireGuard authenticated a datagram from.
    trusted: Vec<Origin>,
    /// Rebuilt datagrams for the tunnel, with where their parity came from.
    rebuilt: VecDeque<(Vec<u8>, Origin)>,
    /// The data datagram just handed to the tunnel: kept for rebuilding only
    /// once WireGuard authenticates it, so a forged one cannot move a
    /// session's counter epoch or fill the kept set.
    /// Staged whatever the mode, so a hello that turns rebuilding on can
    /// still keep the datagram that carried it.
    staged: Option<([u8; 4], u64)>,
    staged_bytes: Vec<u8>,
    counters: Arc<UltraCounters>,
}

impl UltraUnderlay {
    pub(crate) fn new(
        inner: Box<dyn Underlay>,
        mode: UltraMode,
        counters: Arc<UltraCounters>,
    ) -> Self {
        let mode = mode.normalized();
        Self {
            inner,
            decoding: matches!(mode, UltraMode::Fec { .. } | UltraMode::Rs { .. }),
            mode,
            configured: mode,
            group: None,
            received: Kept::default(),
            pending: VecDeque::new(),
            trusted: Vec::new(),
            rebuilt: VecDeque::new(),
            staged: None,
            staged_bytes: Vec::new(),
            counters,
        }
    }

    /// Carry on over a new carrier after a network change; the mode stays.
    pub(crate) fn replace(&mut self, inner: Box<dyn Underlay>) {
        self.close_group();
        self.inner = inner;
        self.rebuilt.clear();
        self.pending.clear();
        self.trusted.clear();
    }

    fn forward(&mut self, datagram: &[u8], priority: Option<Priority>) {
        match priority {
            Some(priority) => self.inner.send_classified(datagram, priority),
            None => self.inner.send(datagram),
        }
    }

    fn send_with(&mut self, datagram: &[u8], priority: Option<Priority>) {
        self.forward(datagram, priority);
        UltraCounters::add(&self.counters.data_bytes, datagram.len() as u64);
        match self.mode {
            UltraMode::Off => {}
            UltraMode::Duplicate { copies } => {
                for _ in 1..copies {
                    self.forward(datagram, priority);
                }
                let extra = u64::from(copies - 1);
                UltraCounters::add(&self.counters.copies_sent, extra);
                UltraCounters::add(&self.counters.overhead_bytes, extra * datagram.len() as u64);
            }
            UltraMode::Fec { group, .. } | UltraMode::Rs { group, .. } => match data_id(datagram) {
                Some((index, counter)) => {
                    self.add_member(index, counter, datagram, priority, group);
                }
                None => {
                    // A lost handshake costs WireGuard a 5 s retry.
                    if matches!(
                        classify(datagram),
                        DatagramClass::WireGuardInitiation | DatagramClass::WireGuardResponse
                    ) {
                        self.forward(datagram, priority);
                        UltraCounters::add(&self.counters.copies_sent, 1);
                        UltraCounters::add(&self.counters.overhead_bytes, datagram.len() as u64);
                    }
                }
            },
        }
    }

    fn add_member(
        &mut self,
        index: [u8; 4],
        counter: u64,
        datagram: &[u8],
        priority: Option<Priority>,
        k: u8,
    ) {
        // One class per group: parity takes its group's class, so repair for
        // input never waits behind bulk data, and never hangs on it arriving.
        let follows = self.group.as_ref().is_some_and(|group| {
            group.index == index
                && group.first.wrapping_add(group.ciphertexts.len() as u64) == counter
                && (priority.is_none() || group.priority.is_none() || group.priority == priority)
        });
        if !follows {
            self.close_group();
        }
        let group = self.group.get_or_insert_with(|| Group {
            index,
            first: counter,
            ciphertexts: Vec::with_capacity(usize::from(k)),
            priority,
        });
        group.ciphertexts.push(datagram.get(WG_DATA_HEADER..).unwrap_or_default().to_vec());
        group.priority = priority.or(group.priority);
        if group.ciphertexts.len() >= usize::from(k) {
            self.close_group();
        }
    }

    fn close_group(&mut self) {
        let Some(group) = self.group.take() else { return };
        let parities = match self.mode {
            UltraMode::Fec { group: k, parity: m } => parity_datagrams(&group, k, m),
            UltraMode::Rs { group: k, parity: m } => {
                rs_parity_datagrams(&group, k, m, self.mode != self.configured)
            }
            UltraMode::Off | UltraMode::Duplicate { .. } => return,
        };
        for parity in parities {
            UltraCounters::add(&self.counters.parity_sent, 1);
            UltraCounters::add(&self.counters.overhead_bytes, parity.len() as u64);
            self.forward(&parity, group.priority);
        }
    }

    fn trusts(&self, origin: Origin) -> bool {
        self.trusted.contains(&origin)
    }

    /// Hold a data datagram handed to the tunnel until WireGuard says whether
    /// it is genuine (see [`Underlay::authenticated`]).
    fn stage(&mut self, datagram: &[u8]) {
        if let Some((index, counter)) = data_id(datagram) {
            let ciphertext = datagram.get(WG_DATA_HEADER..).unwrap_or_default();
            self.staged_bytes.clear();
            self.staged_bytes.extend_from_slice(ciphertext);
            self.staged = Some((index, counter));
        }
    }

    /// Send in `mode` from now on: the mode the two sides agreed inside the
    /// tunnel. A mode that sends parity also means the peer sends it, so
    /// rebuilding starts now, before the peer's first parity arrives.
    pub(crate) fn set_mode(&mut self, mode: UltraMode) {
        let mode = mode.normalized();
        if mode == self.mode {
            return;
        }
        self.close_group();
        self.mode = mode;
        self.decoding |= matches!(mode, UltraMode::Fec { .. } | UltraMode::Rs { .. });
    }

    fn on_parity(&mut self, datagram: &[u8], origin: Origin) {
        // Parity is not authenticated: from anyone else it could make this
        // side buffer datagrams or spend bytes on parity of its own.
        if !self.trusts(origin) {
            return;
        }
        let Some(parity) = parse_parity(datagram) else { return };
        UltraCounters::add(&self.counters.parity_received, 1);
        // Kept datagrams start with the first trusted parity; that group is
        // not rebuilt.
        self.decoding = true;
        if parity.code == Code::ReedSolomon {
            let key = parity.group_key();
            self.retry_rs_group(key, Some((datagram.to_vec(), origin)));
            return;
        }
        match self.received.rebuild(&parity) {
            Rebuild::Done(rebuilt) => self.on_rebuilt(rebuilt, origin),
            Rebuild::DoneAll(_) | Rebuild::Whole => {}
            Rebuild::Waiting => self.wait(datagram.to_vec(), origin),
        }
    }

    /// Keep a parity until a late member or a sibling parity arrives; the
    /// oldest goes when the waiting set is full.
    fn wait(&mut self, datagram: Vec<u8>, origin: Origin) {
        if datagram.len() > MAX_PENDING_PARITY {
            return;
        }
        while self.pending.len() >= PENDING {
            self.pending.pop_front();
        }
        self.pending.push_back((datagram, origin));
    }

    /// Try to rebuild the Reed-Solomon group `key` from every parity of it
    /// that arrived (the waiting ones and `new`): its parities go once the
    /// group is whole or rebuilt, and wait otherwise.
    fn retry_rs_group(&mut self, key: GroupKey, new: Option<(Vec<u8>, Origin)>) {
        let is_sibling = |datagram: &[u8]| {
            parse_parity(datagram)
                .is_some_and(|parity| parity.code == Code::ReedSolomon && parity.group_key() == key)
        };
        let (mut siblings, others): (VecDeque<_>, VecDeque<_>) =
            std::mem::take(&mut self.pending).into_iter().partition(|(d, _)| is_sibling(d));
        self.pending = others;
        siblings.extend(new);
        let outcome = {
            let parsed: Vec<Parity<'_>> =
                siblings.iter().filter_map(|(datagram, _)| parse_parity(datagram)).collect();
            self.received.rebuild_rs(&parsed)
        };
        match outcome {
            Rebuild::DoneAll(rebuilt) => {
                // Every sibling came from a trusted origin; the newest's is
                // where the tunnel would have received the lost ones.
                let Some(&(_, origin)) = siblings.back() else { return };
                for datagram in rebuilt {
                    self.on_rebuilt(datagram, origin);
                }
            }
            Rebuild::Done(_) | Rebuild::Whole => {}
            Rebuild::Waiting => {
                for (datagram, origin) in siblings {
                    self.wait(datagram, origin);
                }
            }
        }
    }

    fn on_rebuilt(&mut self, rebuilt: Vec<u8>, origin: Origin) {
        UltraCounters::add(&self.counters.recovered, 1);
        self.rebuilt.push_back((rebuilt, origin));
    }

    /// WireGuard authenticated a data datagram: keep it, and retry the
    /// waiting parities whose subgroup it belongs to.
    fn on_data(&mut self, index: [u8; 4], counter: u64, ciphertext: &[u8]) {
        // The session's first datagram fixes its counter epoch, which a
        // parity that arrived before it needed to place its group.
        let new_epoch = !self.received.newest.contains_key(&index);
        self.received.keep(index, counter, ciphertext);
        if self.pending.is_empty() {
            return;
        }
        let mut waiting = std::mem::take(&mut self.pending);
        let mut done = Vec::new();
        let mut rs_groups: Vec<GroupKey> = Vec::new();
        waiting.retain(|(datagram, origin)| {
            let Some(parity) = parse_parity(datagram) else { return false };
            if parity.code == Code::ReedSolomon {
                let covers = parity.index == index
                    && (new_epoch
                        || self.received.first(&parity).is_some_and(|first| {
                            counter.wrapping_sub(first) < parity.members as u64
                        }));
                if covers && !rs_groups.contains(&parity.group_key()) {
                    rs_groups.push(parity.group_key());
                }
                return true;
            }
            let covers = parity.index == index
                && (new_epoch
                    || self.received.first(&parity).is_some_and(|first| {
                        let offset = counter.wrapping_sub(first);
                        offset < parity.members as u64
                            && offset as usize % parity.parities == parity.j
                    }));
            if !covers {
                return true;
            }
            match self.received.rebuild(&parity) {
                Rebuild::Done(rebuilt) => {
                    done.push((rebuilt, *origin));
                    false
                }
                Rebuild::DoneAll(_) | Rebuild::Whole => false,
                Rebuild::Waiting => true,
            }
        });
        self.pending = waiting;
        for (rebuilt, origin) in done {
            self.on_rebuilt(rebuilt, origin);
        }
        for key in rs_groups {
            self.retry_rs_group(key, None);
        }
    }
}

impl Underlay for UltraUnderlay {
    fn send(&mut self, datagram: &[u8]) {
        self.send_with(datagram, None);
    }

    fn send_classified(&mut self, datagram: &[u8], priority: Priority) {
        self.send_with(datagram, Some(priority));
    }

    fn send_on(&mut self, path: PathId, datagram: &[u8]) {
        self.inner.send_on(path, datagram);
    }

    fn poll_probes(&mut self, now: Instant) -> DueProbes {
        self.inner.poll_probes(now)
    }

    fn on_pong(&mut self, path: PathId, id: u64, now: Instant) {
        self.inner.on_pong(path, id, now);
    }

    fn set_max_datagram(&mut self, bytes: usize) {
        self.inner.set_max_datagram(bytes);
    }

    /// The driver flushes at the end of every pass: a pass's datagrams are
    /// one group, so its parity leaves right behind them.
    fn flush(&mut self) {
        self.close_group();
        self.inner.flush();
    }

    fn backlogged(&self) -> bool {
        self.inner.backlogged()
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.inner.poll_flush(cx)
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        // Whatever the tunnel received last was authenticated by now, or not.
        self.staged = None;
        let mut parities = 0;
        loop {
            if let Some((datagram, origin)) = self.rebuilt.pop_front() {
                if let Some(slot) = buffer.get_mut(..datagram.len()) {
                    slot.copy_from_slice(&datagram);
                    self.stage(&datagram);
                    return Poll::Ready(Ok(Received { len: datagram.len(), origin }));
                }
                continue;
            }
            let received = ready!(self.inner.poll_recv(cx, buffer))?;
            let Some(datagram) = buffer.get(..received.len) else {
                return Poll::Ready(Ok(received));
            };
            if datagram.first() == Some(&TAG) {
                // Parity from an origin WireGuard never authenticated is
                // dropped unread and uncopied.
                if self.trusts(received.origin) {
                    let datagram = datagram.to_vec();
                    self.on_parity(&datagram, received.origin);
                }
                parities += 1;
                if parities >= PARITY_PER_POLL {
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                }
                continue;
            }
            self.stage(datagram);
            return Poll::Ready(Ok(received));
        }
    }

    /// The driver calls this right after handling the datagram `poll_recv`
    /// returned, when WireGuard authenticated it.
    fn authenticated(&mut self, origin: Origin) {
        if let Some((index, counter)) = self.staged.take()
            && self.decoding
        {
            let ciphertext = std::mem::take(&mut self.staged_bytes);
            self.on_data(index, counter, &ciphertext);
            self.staged_bytes = ciphertext;
        }
        if !self.trusts(origin) {
            if self.trusted.len() >= TRUSTED {
                self.trusted.remove(0);
            }
            self.trusted.push(origin);
        }
        self.inner.authenticated(origin);
    }

    fn has_peer(&self) -> bool {
        self.inner.has_peer()
    }

    fn take_path_change(&mut self) -> bool {
        self.inner.take_path_change()
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        self.inner.peer_hint()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data(index: [u8; 4], counter: u64, len: usize, fill: u8) -> Vec<u8> {
        let mut out = vec![4, 0, 0, 0];
        out.extend_from_slice(&index);
        out.extend_from_slice(&counter.to_le_bytes());
        out.extend((0..len).map(|i| fill.wrapping_add(i as u8)));
        out
    }

    #[test]
    fn the_environment_overrides_the_setting() {
        let on = Some(UltraMode::SETTING);
        assert_eq!(UltraMode::resolve_with(None, None), UltraMode::Off);
        assert_eq!(UltraMode::resolve_with(None, on), UltraMode::SETTING);
        assert_eq!(UltraMode::resolve_with(Some(""), on), UltraMode::SETTING);
        assert_eq!(UltraMode::resolve_with(Some("  "), None), UltraMode::Off);
        assert_eq!(UltraMode::resolve_with(Some("off"), on), UltraMode::Off);
        assert_eq!(UltraMode::resolve_with(Some("dup"), on), UltraMode::Duplicate { copies: 2 });
        assert_eq!(
            UltraMode::resolve_with(Some("fec:8:2"), None),
            UltraMode::Fec { group: 8, parity: 2 }
        );
        assert_eq!(UltraMode::resolve_with(Some("bogus"), on), UltraMode::SETTING);
        assert_eq!(UltraMode::resolve_with(Some("bogus"), None), UltraMode::Off);
    }

    #[test]
    fn the_setting_is_rs_4_4() {
        assert_eq!(UltraMode::parse("rs"), Some(UltraMode::SETTING));
        assert_eq!(UltraMode::SETTING.normalized(), UltraMode::SETTING);
    }

    #[test]
    fn parses_modes() {
        assert_eq!(UltraMode::parse("off"), Some(UltraMode::Off));
        assert_eq!(UltraMode::parse("dup"), Some(UltraMode::Duplicate { copies: 2 }));
        assert_eq!(UltraMode::parse("dup3"), Some(UltraMode::Duplicate { copies: 3 }));
        assert_eq!(UltraMode::parse("fec"), Some(UltraMode::Fec { group: 8, parity: 2 }));
        assert_eq!(UltraMode::parse("fec:10:3"), Some(UltraMode::Fec { group: 10, parity: 3 }));
        assert_eq!(UltraMode::parse("fec:2:3"), None);
        assert_eq!(UltraMode::parse("dup9"), None);
        assert_eq!(UltraMode::parse("brutal"), None);
    }

    #[test]
    fn parity_count_follows_group_size() {
        assert_eq!(UltraMode::parities_for(8, 2, 1), 1);
        assert_eq!(UltraMode::parities_for(8, 2, 4), 1);
        assert_eq!(UltraMode::parities_for(8, 2, 5), 2);
        assert_eq!(UltraMode::parities_for(8, 2, 8), 2);
    }

    #[test]
    fn widen_picks_the_nearest_epoch() {
        assert_eq!(widen(5, 7), 5);
        assert_eq!(widen(0xFFFF_FFFE, 0x1_0000_0001), 0xFFFF_FFFE);
        assert_eq!(widen(1, 0xFFFF_FFFF), 0x1_0000_0001);
    }

    /// Every single loss in every subgroup of a group, with members of
    /// different lengths, is rebuilt byte for byte.
    #[test]
    fn rebuilds_any_one_lost_member_per_parity() {
        let index = [9, 8, 7, 6];
        let first = 0xFFFF_FFFC_u64; // the counter crosses a 32-bit boundary
        let sent: Vec<Vec<u8>> =
            (0..8).map(|i| data(index, first + i, 40 + 37 * i as usize, i as u8)).collect();
        let group = Group {
            index,
            first,
            ciphertexts: sent.iter().map(|d| d[WG_DATA_HEADER..].to_vec()).collect(),
            priority: None,
        };
        let parities = parity_datagrams(&group, 8, 2);
        assert_eq!(parities.len(), 2);
        let longest = sent.iter().map(Vec::len).max().unwrap();
        assert!(parities.iter().all(|p| p.len() <= longest), "parity fits the path MTU");
        for lost in 0..8 {
            let mut received = Kept::default();
            for (i, d) in sent.iter().enumerate() {
                if i != lost {
                    received.keep(index, first + i as u64, &d[WG_DATA_HEADER..]);
                }
            }
            let rebuilt: Vec<Vec<u8>> = parities
                .iter()
                .filter_map(|p| received.rebuild(&parse_parity(p).unwrap()).rebuilt())
                .collect();
            assert_eq!(rebuilt, vec![sent[lost].clone()], "lost member {lost}");
        }
    }

    #[test]
    fn two_losses_in_one_subgroup_rebuild_nothing() {
        let index = [1, 2, 3, 4];
        let sent: Vec<Vec<u8>> = (0..4).map(|i| data(index, 100 + i, 64, i as u8)).collect();
        let group = Group {
            index,
            first: 100,
            ciphertexts: sent.iter().map(|d| d[WG_DATA_HEADER..].to_vec()).collect(),
            priority: None,
        };
        let parity = &parity_datagrams(&group, 4, 1)[0];
        let mut received = Kept::default();
        received.keep(index, 100, &sent[0][WG_DATA_HEADER..]);
        received.keep(index, 103, &sent[3][WG_DATA_HEADER..]);
        assert_eq!(received.rebuild(&parse_parity(parity).unwrap()), Rebuild::Waiting);
    }

    /// What a test carrier sent.
    type Wire = Arc<std::sync::Mutex<Vec<Vec<u8>>>>;

    /// A carrier that hands out queued datagrams and records what is sent.
    struct Script {
        inbox: VecDeque<(Vec<u8>, Origin)>,
        sent: Wire,
    }

    impl Underlay for Script {
        fn send(&mut self, datagram: &[u8]) {
            self.sent.lock().unwrap().push(datagram.to_vec());
        }
        fn poll_recv(
            &mut self,
            _cx: &mut Context<'_>,
            buffer: &mut [u8],
        ) -> Poll<io::Result<Received>> {
            match self.inbox.pop_front() {
                Some((datagram, origin)) => {
                    buffer[..datagram.len()].copy_from_slice(&datagram);
                    Poll::Ready(Ok(Received { len: datagram.len(), origin }))
                }
                None => Poll::Pending,
            }
        }
        fn has_peer(&self) -> bool {
            true
        }
    }

    fn origin(port: u16) -> Origin {
        Origin { path: PathId(0), addr: Some(SocketAddr::from(([127, 0, 0, 1], port))) }
    }

    /// An ultra underlay in `mode` that will receive `inbox`, and what it
    /// handed the tunnel. Like the driver, it reports each handed-over
    /// datagram in `authentic` as authenticated before the next receive.
    fn receive(
        mode: UltraMode,
        trusted: Option<Origin>,
        inbox: Vec<(Vec<u8>, Origin)>,
        authentic: &[Vec<u8>],
    ) -> (UltraUnderlay, Vec<Vec<u8>>, Wire) {
        let sent = Arc::default();
        let script = Script { inbox: inbox.into(), sent: Arc::clone(&sent) };
        let mut ultra = UltraUnderlay::new(Box::new(script), mode, Arc::default());
        if let Some(origin) = trusted {
            ultra.authenticated(origin);
        }
        let mut cx = Context::from_waker(std::task::Waker::noop());
        let mut buffer = vec![0u8; 4096];
        let mut out = Vec::new();
        while let Poll::Ready(Ok(received)) = ultra.poll_recv(&mut cx, &mut buffer) {
            let datagram = buffer[..received.len].to_vec();
            if authentic.contains(&datagram) {
                ultra.authenticated(received.origin);
            }
            out.push(datagram);
        }
        (ultra, out, sent)
    }

    fn group_of(index: [u8; 4], first: u64, n: u64) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
        let sent: Vec<Vec<u8>> = (0..n).map(|i| data(index, first + i, 80, i as u8)).collect();
        let group = Group {
            index,
            first,
            ciphertexts: sent.iter().map(|d| d[WG_DATA_HEADER..].to_vec()).collect(),
            priority: None,
        };
        let parities = parity_datagrams(&group, n as u8, 1);
        (sent, parities)
    }

    /// Parity from an origin WireGuard never authenticated turns nothing on:
    /// no buffering, no rebuilding, no parity of our own.
    #[test]
    fn parity_from_an_unauthenticated_origin_is_ignored() {
        let index = [5, 5, 5, 5];
        let (sent, parities) = group_of(index, 10, 4);
        let stranger = origin(9999);
        let mut inbox: Vec<_> = parities.iter().map(|p| (p.clone(), stranger)).collect();
        inbox.extend(sent.iter().skip(1).map(|d| (d.clone(), stranger)));
        inbox.extend(parities.iter().map(|p| (p.clone(), stranger)));
        let (mut ultra, out, wire) = receive(UltraMode::Off, Some(origin(1)), inbox, &[]);
        assert_eq!(out.len(), 3, "data is still delivered, nothing is rebuilt");
        assert!(!ultra.decoding, "an untrusted parity starts no buffering");
        assert_eq!(ultra.mode, UltraMode::Off, "and does not turn our parity on");
        assert_eq!(ultra.counters.snapshot().parity_received, 0);
        ultra.send(&data(index, 1, 40, 0));
        ultra.flush();
        assert_eq!(wire.lock().unwrap().len(), 1, "no parity goes out");
    }

    /// From an authenticated origin, the same parity turns rebuilding on,
    /// but never this side's own parity.
    #[test]
    fn parity_from_the_authenticated_origin_rebuilds_without_sending_parity() {
        let index = [6, 6, 6, 6];
        let peer = origin(1);
        let (first_group, first_parity) = group_of(index, 0, 4);
        let (sent, parity) = group_of(index, 4, 4);
        let mut inbox: Vec<_> = first_group.iter().map(|d| (d.clone(), peer)).collect();
        inbox.push((first_parity[0].clone(), peer));
        inbox.extend([0, 1, 3].map(|i| (sent[i].clone(), peer)));
        inbox.push((parity[0].clone(), peer));
        // WireGuard accepts every genuine datagram, the rebuilt one too.
        let (mut ultra, out, wire) = receive(UltraMode::Off, Some(peer), inbox, &sent);
        assert_eq!(out.last(), Some(&sent[2]), "the lost member is rebuilt");
        assert_eq!(ultra.mode, UltraMode::Off, "the peer's mode is not adopted");
        ultra.send(&data(index, 1, 40, 0));
        ultra.flush();
        assert_eq!(wire.lock().unwrap().len(), 1, "no parity goes out");
    }

    /// A side with the mode off keeps nothing until the peer's first trusted
    /// parity: a loss in that first group stays lost (TCP retransmits it),
    /// and every later group is rebuilt.
    #[test]
    fn an_off_receiver_rebuilds_from_the_second_group_on() {
        let index = [7, 7, 7, 7];
        let peer = origin(1);
        let (first_group, first_parity) = group_of(index, 0, 4);
        let (second_group, second_parity) = group_of(index, 4, 4);
        let mut inbox: Vec<_> = [0, 1, 3].map(|i| (first_group[i].clone(), peer)).to_vec();
        inbox.push((first_parity[0].clone(), peer));
        inbox.extend([0, 2, 3].map(|i| (second_group[i].clone(), peer)));
        inbox.push((second_parity[0].clone(), peer));
        let authentic: Vec<_> = first_group.iter().chain(&second_group).cloned().collect();
        let (ultra, out, _) = receive(UltraMode::Off, Some(peer), inbox, &authentic);
        assert!(!out.contains(&first_group[2]), "the first group is not rebuilt: {out:?}");
        assert_eq!(out.last(), Some(&second_group[1]), "the second group is: {out:?}");
        assert_eq!(ultra.counters.snapshot().recovered, 1);
    }

    /// An on-path attacker drops a genuine datagram and sends its unchanged
    /// ciphertext as single-member parity with a costly mode in the header.
    /// The rebuilt datagram is the genuine one and authenticates, and still
    /// this side sends nothing extra.
    #[test]
    fn rewrapped_genuine_ciphertext_does_not_switch_the_mode() {
        let index = [8, 8, 8, 8];
        let peer = origin(1);
        let (sent, _) = group_of(index, 0, 3);
        let rewrapped = parity_datagrams(
            &Group {
                index,
                first: 1,
                ciphertexts: vec![sent[1][WG_DATA_HEADER..].to_vec()],
                priority: None,
            },
            1,
            1,
        );
        let inbox = vec![
            (sent[0].clone(), peer),
            (rewrapped[0].clone(), peer), // stands in for the dropped counter 1
            (sent[2].clone(), peer),      // places the counter epoch
        ];
        let (mut ultra, out, wire) = receive(UltraMode::Off, Some(peer), inbox, &sent);
        assert_eq!(
            out,
            vec![sent[0].clone(), sent[2].clone(), sent[1].clone()],
            "the genuine datagram is rebuilt and authenticates"
        );
        assert_eq!(ultra.mode, UltraMode::Off, "the attacker's mode is not adopted");
        ultra.send(&data(index, 3, 40, 0));
        ultra.flush();
        assert_eq!(wire.lock().unwrap().len(), 1, "no parity goes out");
    }

    /// The session's first data datagram is lost and its group of one has a
    /// parity: the parity waits until a later datagram places the epoch.
    #[test]
    fn a_lost_first_datagram_is_rebuilt_once_the_epoch_is_known() {
        let index = [3, 3, 3, 3];
        let peer = origin(1);
        let (first, parity) = group_of(index, 7, 1);
        let (later, _) = group_of(index, 8, 1);
        let inbox = vec![(parity[0].clone(), peer), (later[0].clone(), peer)];
        let authentic = [first[0].clone(), later[0].clone()];
        let (_, out, _) =
            receive(UltraMode::Fec { group: 1, parity: 1 }, Some(peer), inbox, &authentic);
        assert_eq!(out, vec![later[0].clone(), first[0].clone()]);
    }

    /// A datagram WireGuard refuses is never kept: a forged one from the
    /// peer's address cannot move the counter epoch and break rebuilding.
    #[test]
    fn a_refused_datagram_cannot_move_the_counter_epoch() {
        let index = [2, 2, 2, 2];
        let peer = origin(1);
        let forged = data(index, 1 << 32, 80, 0xEE);
        let (sent, parity) = group_of(index, 100, 4);
        let mut inbox = vec![(forged, peer)];
        inbox.extend([0, 1, 3].map(|i| (sent[i].clone(), peer)));
        inbox.push((parity[0].clone(), peer));
        let (_, out, _) = receive(UltraMode::Fec { group: 4, parity: 1 }, Some(peer), inbox, &sent);
        assert_eq!(out.last(), Some(&sent[2]), "the lost member is still rebuilt: {out:?}");
    }

    /// The first datagram WireGuard authenticates from a new origin is kept,
    /// so a loss later in its group is still rebuilt.
    #[test]
    fn the_first_authenticated_datagram_is_kept() {
        let index = [1, 1, 1, 1];
        let peer = origin(1);
        let (sent, parity) = group_of(index, 0, 4);
        let mut inbox: Vec<_> = [0, 1, 3].map(|i| (sent[i].clone(), peer)).to_vec();
        inbox.push((parity[0].clone(), peer));
        let (_, out, _) = receive(UltraMode::Fec { group: 4, parity: 1 }, None, inbox, &sent);
        assert_eq!(out.last(), Some(&sent[2]), "rebuilt with the first member kept: {out:?}");
    }

    /// A flood of parity makes `poll_recv` yield after `PARITY_PER_POLL` of
    /// them, with a wake to come back, so the driver keeps doing its other
    /// work; the data behind the flood still arrives on a later poll.
    #[test]
    fn a_parity_flood_yields_to_the_driver() {
        let index = [4, 4, 4, 4];
        let (sent, parities) = group_of(index, 0, 1);
        let stranger = origin(9999);
        let mut inbox: Vec<_> =
            (0..PARITY_PER_POLL + 10).map(|_| (parities[0].clone(), stranger)).collect();
        inbox.push((sent[0].clone(), origin(1)));
        let script = Script { inbox: inbox.into(), sent: Arc::default() };
        let mut ultra = UltraUnderlay::new(Box::new(script), UltraMode::Off, Arc::default());
        let mut cx = Context::from_waker(std::task::Waker::noop());
        let mut buffer = vec![0u8; 4096];
        assert!(ultra.poll_recv(&mut cx, &mut buffer).is_pending(), "the flood yields");
        match ultra.poll_recv(&mut cx, &mut buffer) {
            Poll::Ready(Ok(received)) => assert_eq!(buffer[..received.len], sent[0][..]),
            other => panic!("the data behind the flood arrives: {other:?}"),
        }
        assert_eq!(ultra.counters.snapshot().parity_received, 0, "untrusted parity is unread");
    }

    /// A parity that arrives before a reordered member waits for it, and
    /// rebuilds the member that is really lost once the late one lands.
    #[test]
    fn parity_waits_for_a_reordered_member() {
        let index = [7, 7, 7, 7];
        let peer = origin(1);
        let (sent, parity) = group_of(index, 20, 4);
        let mut inbox: Vec<_> = [0, 3].map(|i| (sent[i].clone(), peer)).to_vec();
        inbox.push((parity[0].clone(), peer)); // members 1 and 2 still missing
        inbox.push((sent[1].clone(), peer)); // 1 arrives late; 2 is lost
        let (ultra, out, _) =
            receive(UltraMode::Fec { group: 4, parity: 1 }, Some(peer), inbox, &sent);
        assert_eq!(out.last(), Some(&sent[2]), "rebuilt after the late member: {out:?}");
        assert!(ultra.pending.is_empty());
    }

    /// The hello that agrees on FEC arrives in the session's first data
    /// datagram, while this side is still off. The driver sets the mode
    /// before reporting that datagram authenticated, so it is kept and a loss
    /// in the first group is rebuilt (no parity had arrived before).
    #[test]
    fn an_agreed_mode_rebuilds_the_first_group() {
        let index = [6, 5, 4, 3];
        let peer = origin(1);
        let (sent, parity) = group_of(index, 0, 4);
        let inbox: Vec<_> = [0, 1, 3].map(|i| (sent[i].clone(), peer)).to_vec();
        let script = Script { inbox: inbox.into(), sent: Arc::default() };
        let mut ultra = UltraUnderlay::new(Box::new(script), UltraMode::Off, Arc::default());
        let mut cx = Context::from_waker(std::task::Waker::noop());
        let mut buffer = vec![0u8; 4096];
        let mut first = true;
        while let Poll::Ready(Ok(received)) = ultra.poll_recv(&mut cx, &mut buffer) {
            if first {
                // The hello this datagram carried.
                ultra.set_mode(UltraMode::Fec { group: 4, parity: 1 });
                first = false;
            }
            ultra.authenticated(received.origin);
        }
        ultra.on_parity(&parity[0], peer);
        let rebuilt = ultra.rebuilt.pop_front().map(|(datagram, _)| datagram);
        assert_eq!(rebuilt, Some(sent[2].clone()), "the first group is rebuilt");
    }

    #[test]
    fn modes_built_in_code_are_brought_within_limits() {
        assert_eq!(UltraMode::Duplicate { copies: 0 }.normalized(), UltraMode::Off);
        assert_eq!(UltraMode::Duplicate { copies: 1 }.normalized(), UltraMode::Off);
        assert_eq!(
            UltraMode::Duplicate { copies: 9 }.normalized(),
            UltraMode::Duplicate { copies: MAX_COPIES }
        );
        assert_eq!(UltraMode::Fec { group: 8, parity: 0 }.normalized(), UltraMode::Off);
        assert_eq!(UltraMode::Fec { group: 0, parity: 1 }.normalized(), UltraMode::Off);
        assert_eq!(UltraMode::Fec { group: 2, parity: 3 }.normalized(), UltraMode::Off);
        let ultra = UltraUnderlay::new(
            Box::new(Script { inbox: VecDeque::new(), sent: Arc::default() }),
            UltraMode::Duplicate { copies: 0 },
            Arc::default(),
        );
        assert_eq!(ultra.mode, UltraMode::Off);
    }

    #[test]
    fn parses_reed_solomon_modes() {
        assert_eq!(UltraMode::parse("rs"), Some(UltraMode::Rs { group: 4, parity: 4 }));
        assert_eq!(UltraMode::parse("RS:16:8"), Some(UltraMode::Rs { group: 16, parity: 8 }));
        assert_eq!(UltraMode::parse("rs:2:3"), Some(UltraMode::Rs { group: 2, parity: 3 }));
        assert_eq!(UltraMode::parse("rs:8:16"), None);
        assert_eq!(UltraMode::parse("rs:33:4"), None);
        assert_eq!(UltraMode::parse("rs:8:0"), None);
        assert_eq!(UltraMode::Rs { group: 8, parity: 0 }.normalized(), UltraMode::Off);
        assert_eq!(UltraMode::Rs { group: 8, parity: 4 }.overhead_under_load(), 1.5);
        assert_eq!(UltraMode::rs_parities_for(8, 4, 1), 2, "at least two");
        assert_eq!(UltraMode::rs_parities_for(8, 4, 5), 3);
        assert_eq!(UltraMode::rs_parities_for(8, 4, 8), 4);
        assert_eq!(UltraMode::rs_parities_for(8, 1, 8), 1, "never more than M");
        assert_eq!(UltraMode::rs_parities_for(1, 3, 1), 3, "not capped at the members");
    }

    fn rs_group(
        index: [u8; 4],
        first: u64,
        lengths: &[usize],
        m: u8,
    ) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
        let sent: Vec<Vec<u8>> = lengths
            .iter()
            .enumerate()
            .map(|(i, len)| data(index, first.wrapping_add(i as u64), *len, i as u8 * 13))
            .collect();
        let group = Group {
            index,
            first,
            ciphertexts: sent.iter().map(|d| d[WG_DATA_HEADER..].to_vec()).collect(),
            priority: None,
        };
        let parities = rs_parity_datagrams(&group, lengths.len() as u8, m, false);
        (sent, parities)
    }

    /// Every way to lose up to M of a group's K+M datagrams (data and parity),
    /// with members of mixed lengths and the counter crossing a 32-bit
    /// boundary, rebuilds every lost data datagram byte for byte; every way to
    /// lose M+1 that takes a data datagram rebuilds nothing.
    #[test]
    fn reed_solomon_rebuilds_any_m_losses_of_a_group() {
        let index = [9, 9, 9, 9];
        let first = 0xFFFF_FFFD_u64;
        let lengths = [40, 1380, 16, 77, 1200, 300, 17, 999];
        let (sent, parities) = rs_group(index, first, &lengths, 4);
        assert_eq!(parities.len(), 4);
        let longest = sent.iter().map(Vec::len).max().unwrap();
        assert!(parities.iter().all(|p| p.len() == longest), "parity fits the path MTU");
        let total = sent.len() + parities.len();
        let mut checked = 0;
        for lost in 0u32..(1 << total) {
            let losses = lost.count_ones() as usize;
            let lost_data: Vec<usize> = (0..sent.len()).filter(|i| lost & (1 << i) != 0).collect();
            if losses > 5 || lost_data.is_empty() {
                continue;
            }
            let mut received = Kept::default();
            for (i, d) in sent.iter().enumerate() {
                if lost & (1 << i) == 0 {
                    received.keep(index, first.wrapping_add(i as u64), &d[WG_DATA_HEADER..]);
                }
            }
            let arrived: Vec<Parity<'_>> = (0..parities.len())
                .filter(|j| lost & (1 << (sent.len() + j)) == 0)
                .map(|j| parse_parity(&parities[j]).unwrap())
                .collect();
            if arrived.is_empty() {
                continue; // nothing to rebuild from
            }
            // The epoch is known once any member arrived; with all of them
            // lost a later group would place it.
            if received.newest.is_empty() {
                received.newest.insert(index, first);
            }
            let outcome = received.rebuild_rs(&arrived);
            if losses <= 4 {
                let expected: Vec<Vec<u8>> = lost_data.iter().map(|i| sent[*i].clone()).collect();
                assert_eq!(outcome, Rebuild::DoneAll(expected), "lost {lost:b}");
            } else {
                assert_eq!(outcome, Rebuild::Waiting, "M+1 losses {lost:b}");
            }
            checked += 1;
        }
        assert!(checked > 1000, "{checked} loss patterns");
    }

    /// Through the underlay: two losses in what would be one XOR subgroup
    /// are rebuilt once the second parity lands, and the first parity waits
    /// for it.
    #[test]
    fn reed_solomon_parity_waits_for_its_sibling() {
        let index = [6, 5, 4, 3];
        let peer = origin(1);
        let (sent, parities) = rs_group(index, 40, &[80, 90, 100, 110, 120, 130, 140, 150], 4);
        let mut inbox: Vec<_> = [0, 1, 3, 4, 5, 7].map(|i| (sent[i].clone(), peer)).to_vec();
        inbox.push((parities[1].clone(), peer));
        inbox.push((parities[3].clone(), peer));
        let mode = UltraMode::Rs { group: 8, parity: 4 };
        let (ultra, out, _) = receive(mode, Some(peer), inbox, &sent);
        assert_eq!(out[6..], [sent[2].clone(), sent[6].clone()], "both rebuilt: {out:?}");
        assert!(ultra.pending.is_empty());
        assert_eq!(ultra.counters.snapshot().recovered, 2);
    }

    /// Reed-Solomon parity from an origin WireGuard never authenticated is
    /// ignored, and from the peer it never turns this side's parity on.
    #[test]
    fn reed_solomon_parity_follows_the_trust_rules() {
        let index = [5, 4, 3, 2];
        let peer = origin(1);
        let stranger = origin(9999);
        let (sent, parities) = rs_group(index, 0, &[60, 70, 80, 90], 2);
        let mut inbox: Vec<_> = [0, 3].map(|i| (sent[i].clone(), peer)).to_vec();
        inbox.extend(parities.iter().map(|p| (p.clone(), stranger)));
        let (ultra, out, _) = receive(UltraMode::Off, Some(peer), inbox.clone(), &sent);
        assert_eq!(out.len(), 2, "nothing rebuilt from a stranger: {out:?}");
        assert_eq!(ultra.counters.snapshot().parity_received, 0);
        // From the peer: its first parity turns rebuilding on (that group is
        // whole), and the next group's two losses are rebuilt.
        let (earlier, earlier_parity) = rs_group(index, 100, &[60], 1);
        let mut inbox = vec![(earlier[0].clone(), peer), (earlier_parity[0].clone(), peer)];
        inbox.extend([0, 3].map(|i| (sent[i].clone(), peer)));
        inbox.extend(parities.iter().map(|p| (p.clone(), peer)));
        let authentic: Vec<_> = earlier.iter().chain(&sent).cloned().collect();
        let (mut ultra, out, wire) = receive(UltraMode::Off, Some(peer), inbox, &authentic);
        // (The earlier group's datagram was not kept, so it is rebuilt too.)
        assert_eq!(
            out[out.len() - 2..],
            [sent[1].clone(), sent[2].clone()],
            "rebuilt from the peer: {out:?}"
        );
        assert_eq!(ultra.mode, UltraMode::Off, "the peer's mode is not adopted");
        ultra.send(&data(index, 9, 40, 0));
        ultra.flush();
        assert_eq!(wire.lock().unwrap().len(), 1, "no parity goes out");
    }

    /// Bytes a group of `lengths` (ciphertext bytes) costs in `mode`, sent by
    /// a side started `configured`: (sent bytes / data bytes, parities).
    fn group_cost(configured: UltraMode, mode: UltraMode, lengths: &[usize]) -> (f64, u64) {
        let script = Script { inbox: VecDeque::new(), sent: Arc::default() };
        let mut ultra = UltraUnderlay::new(Box::new(script), configured, Arc::default());
        ultra.set_mode(mode);
        for (i, len) in lengths.iter().enumerate() {
            ultra.send(&data([2, 2, 2, 2], i as u64, *len, 0));
        }
        ultra.flush();
        let stats = ultra.counters.snapshot();
        let ratio = (stats.data_bytes + stats.overhead_bytes) as f64 / stats.data_bytes as f64;
        (ratio, stats.parity_sent)
    }

    /// The 4x a peer can ask for counts bytes. Reed-Solomon parity is as
    /// long as the group's longest datagram, so a full datagram among small
    /// ones (the case from the review: `rs:5:15` with one 1232-byte member
    /// and four of 80) sent 12.9x its bytes; taken up from the peer, it now
    /// sends at most 4x, with fewer parities. The side's own mode is the
    /// user's choice and is not capped, and groups of like sizes keep every
    /// parity.
    #[test]
    fn a_mode_taken_up_from_the_peer_sends_at_most_four_times_the_bytes() {
        let mixed = [1232 - WG_DATA_HEADER, 64, 64, 64, 64];
        let costly = UltraMode::Rs { group: 5, parity: 15 };
        let (own, parities) = group_cost(costly, costly, &mixed);
        assert!(own > 12.0 && parities == 15, "own mode, uncapped: {own:.2}x, {parities}");
        let (taken_up, parities) = group_cost(UltraMode::Off, costly, &mixed);
        assert!(taken_up <= 4.0, "{taken_up:.2}x with {parities} parities");
        assert!(parities >= 1);

        let setting = UltraMode::Rs { group: 4, parity: 4 };
        let shapes: [&[usize]; 5] =
            [&[1216, 64, 64, 64], &[1216], &[64], &[1216, 1216, 1216, 1216], &[1216, 64]];
        for lengths in shapes {
            let (ratio, _) = group_cost(UltraMode::Off, setting, lengths);
            assert!(ratio <= 4.0, "{lengths:?}: {ratio:.2}x");
        }
        let full = [1216; 4];
        assert_eq!(group_cost(UltraMode::Off, setting, &full).1, 4, "like sizes keep all four");
        assert_eq!(group_cost(UltraMode::Off, setting, &[64]).1, 2, "a lone datagram keeps two");
        let (own, parities) = group_cost(setting, setting, &[1216, 64, 64, 64]);
        assert!(own > 4.0 && parities == 4, "the setting at its own side: {own:.2}x");
    }

    /// A Reed-Solomon sender sends its parities after each group, and an XOR
    /// receiver's parser and a Reed-Solomon one tell them apart.
    #[test]
    fn a_reed_solomon_sender_sends_versioned_parity() {
        let wire: Wire = Arc::default();
        let script = Script { inbox: VecDeque::new(), sent: Arc::clone(&wire) };
        let mode = UltraMode::Rs { group: 4, parity: 2 };
        let mut ultra = UltraUnderlay::new(Box::new(script), mode, Arc::default());
        for i in 0..4 {
            ultra.send(&data([1, 1, 1, 1], i, 50, 0));
        }
        ultra.send(&data([1, 1, 1, 1], 4, 50, 0));
        ultra.flush();
        let wire = wire.lock().unwrap();
        let parity: Vec<&Vec<u8>> = wire.iter().filter(|d| is_parity(d)).collect();
        assert_eq!(parity.len(), 4, "2 for the full group, and 2 for the lone datagram");
        assert!(parity.iter().all(|p| p[1] == VERSION_RS && classify(p) == DatagramClass::Unknown));
        assert!(parity.iter().all(|p| parse_parity(p).unwrap().code == Code::ReedSolomon));
    }

    #[test]
    fn parity_is_never_a_wireguard_or_stun_message() {
        let group =
            Group { index: [0; 4], first: 0, ciphertexts: vec![vec![0; 32]], priority: None };
        let parity = &parity_datagrams(&group, 8, 2)[0];
        assert_eq!(classify(parity), DatagramClass::Unknown);
    }
}
