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
//! The mode is the `CMUX_WG_ULTRA` environment variable (`off`, `auto`, `dup`,
//! `dup3`, `fec`, `fec:8:2`, `rs`, `rs:8:4`), read when a tunnel starts, else
//! the app's setting in [`crate::WgConfig::ultra`] (desktop `remote.ultra`,
//! the iPhone's Settings → Transport → Ultra mode: Off, Auto or Always). Auto,
//! the default, sends no repair data until it sees loss ([`crate::ultra_auto`]).

use std::collections::{HashMap, VecDeque};
use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::{Context, Poll, ready};

use cmux_transport::{DatagramClass, PathId, classify};
use tokio::time::Instant;

use crate::pacing::Priority;
use crate::ultra_auto::{LossMeter, LossSample};
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
    /// Times Auto turned the repair data on.
    pub auto_on: AtomicU64,
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
    pub auto_on: u64,
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
            auto_on: self.auto_on.load(Ordering::Relaxed),
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
/// times its bytes in parity. `cap` (a mode taken up from the peer:
/// [`MAX_AGREED_OVERHEAD`]; a metered network: `ultra_auto::METERED_OVERHEAD`)
/// keeps the group's datagrams and parity within that many times its data
/// bytes by sending fewer parities, at least one. XOR parity needs no cap:
/// each member is in one subgroup, so it is at most 2x the bytes.
fn rs_parity_datagrams(group: &Group, k: u8, m: u8, cap: Option<u32>) -> Vec<Vec<u8>> {
    let members = group.ciphertexts.len();
    let mut parities = UltraMode::rs_parities_for(k, m, members);
    if let Some(cap) = cap {
        parities = parities.min(rs_parity_budget(&group.ciphertexts, cap));
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

/// The most Reed-Solomon parities a group of `ciphertexts` sends under
/// `cap`: repair bytes at most `cap - 1` times the group's data bytes (whole
/// datagrams, header and all), and at least one parity.
fn rs_parity_budget(ciphertexts: &[Vec<u8>], cap: u32) -> usize {
    let data: usize = ciphertexts.iter().map(|ciphertext| WG_DATA_HEADER + ciphertext.len()).sum();
    let parity = PARITY_HEADER + ciphertexts.iter().map(Vec::len).max().unwrap_or(0);
    let repair = data * (cap.max(2) as usize - 1);
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
    /// The network is metered (or the peer's is): repair bytes stay within
    /// `ultra_auto::METERED_OVERHEAD` times the data.
    metered: bool,
    /// Loss on the way in, for Auto.
    meter: LossMeter,
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
    /// The staged datagram was rebuilt from parity.
    staged_rebuilt: bool,
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
            metered: false,
            meter: LossMeter::default(),
            group: None,
            received: Kept::default(),
            pending: VecDeque::new(),
            trusted: Vec::new(),
            rebuilt: VecDeque::new(),
            staged: None,
            staged_bytes: Vec::new(),
            staged_rebuilt: false,
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
                let cap = if self.metered {
                    Some(crate::ultra_auto::METERED_OVERHEAD)
                } else {
                    (self.mode != self.configured).then_some(MAX_AGREED_OVERHEAD)
                };
                rs_parity_datagrams(&group, k, m, cap)
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

    /// Keep repair bytes within the metered cap, or stop keeping them.
    pub(crate) fn set_metered(&mut self, metered: bool) {
        if metered != self.metered {
            self.close_group();
            self.metered = metered;
        }
    }

    /// Loss on the way in since the last call (for Auto).
    pub(crate) fn take_loss(&mut self) -> LossSample {
        self.meter.take()
    }

    /// Auto turned the repair data on.
    pub(crate) fn count_auto_on(&self) {
        UltraCounters::add(&self.counters.auto_on, 1);
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
        self.staged_rebuilt = false;
        let mut parities = 0;
        loop {
            if let Some((datagram, origin)) = self.rebuilt.pop_front() {
                if let Some(slot) = buffer.get_mut(..datagram.len()) {
                    slot.copy_from_slice(&datagram);
                    self.stage(&datagram);
                    self.staged_rebuilt = true;
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
        let staged = self.staged.take();
        if let Some((index, counter)) = staged {
            self.meter.observe(index, counter, self.staged_rebuilt);
        }
        if let Some((index, counter)) = staged
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
#[path = "ultra_tests.rs"]
mod tests;
