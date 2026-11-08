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
//!   messages are sent twice. Costs (K+M)/K of the bytes under load and at
//!   most twice the bytes when every pass sends one datagram.
//!
//! A parity datagram is a header plus the XOR of ciphertexts; the WireGuard
//! header of a rebuilt datagram comes from the parity header, so a parity is
//! never larger than the largest member and fits the same path MTU. It
//! starts with [`TAG`], which no WireGuard or STUN message starts with: a
//! peer without ultra mode hands it to boringtun, which refuses it, so turning
//! the mode on never breaks an older peer, it only wastes the parity bytes.
//! A peer that receives parity answers with the same mode, so one side's
//! setting protects both directions.
//!
//! The mode is the `CMUX_WG_ULTRA` environment variable (`off`, `dup`,
//! `dup3`, `fec`, `fec:8:2`), read when a tunnel starts.

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
const VERSION: u8 = 1;
const PARITY_HEADER: usize = 16;
/// Type, receiver index and counter in front of a WireGuard data message's
/// ciphertext.
const WG_DATA_HEADER: usize = 16;
/// Received data datagrams kept for rebuilding. Parity follows its group
/// within one pass, so a few groups' worth is enough.
const KEEP: usize = 256;
const MAX_GROUP: u8 = 32;
const MAX_PARITY: u8 = 15;
const MAX_COPIES: u8 = 4;
/// The environment variable that turns the mode on.
pub const ENV: &str = "CMUX_WG_ULTRA";
/// `none` turns the tunnel's TCP congestion control off, so loss never
/// shrinks a window and each stream runs at what its window and the pacer
/// allow (Hysteria's "Brutal" idea, bounded by the 256 KiB window). For
/// benches: it is unfair to other traffic on a congested link.
pub const CC_ENV: &str = "CMUX_WG_ULTRA_CC";

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
}

impl UltraMode {
    /// `off`, `dup`, `dupN`, `fec` or `fec:K:M`; `None` for anything else.
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim().to_ascii_lowercase();
        match text.as_str() {
            "" | "off" | "0" | "false" => return Some(Self::Off),
            "dup" => return Some(Self::Duplicate { copies: 2 }),
            "fec" => return Some(Self::Fec { group: 8, parity: 2 }),
            _ => {}
        }
        if let Some(copies) = text.strip_prefix("dup") {
            let copies: u8 = copies.trim_start_matches(':').parse().ok()?;
            return (2..=MAX_COPIES).contains(&copies).then_some(Self::Duplicate { copies });
        }
        let rest = text.strip_prefix("fec:")?;
        let (group, parity) = rest.split_once(':')?;
        let (group, parity): (u8, u8) = (group.parse().ok()?, parity.parse().ok()?);
        Self::fec(group, parity)
    }

    fn fec(group: u8, parity: u8) -> Option<Self> {
        ((1..=MAX_GROUP).contains(&group) && (1..=MAX_PARITY.min(group)).contains(&parity))
            .then_some(Self::Fec { group, parity })
    }

    /// The mode in [`ENV`], or off when it is unset or unreadable.
    pub fn from_env() -> Self {
        match std::env::var(ENV) {
            Ok(text) => Self::parse(&text).unwrap_or_else(|| {
                eprintln!(
                    "{ENV}={text:?} is not off, dup, dupN, fec or fec:K:M; ultra mode is off"
                );
                Self::Off
            }),
            Err(_) => Self::Off,
        }
    }

    /// Bytes sent per byte of data, at most: under load for FEC, and in
    /// every case for duplication.
    pub fn overhead_under_load(self) -> f64 {
        match self {
            Self::Off => 1.0,
            Self::Duplicate { copies } => f64::from(copies),
            Self::Fec { group, parity } => f64::from(group + parity) / f64::from(group),
        }
    }

    /// Parities for a group of `members`: in proportion to `parity / group`,
    /// at least one, so a small group pays no more than a full one would.
    fn parities_for(group: u8, parity: u8, members: usize) -> usize {
        let wanted = (members * usize::from(parity)).div_ceil(usize::from(group).max(1));
        wanted.clamp(1, usize::from(parity).min(members.max(1)))
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
}

/// A snapshot of [`UltraCounters`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UltraStats {
    pub copies_sent: u64,
    pub parity_sent: u64,
    pub parity_received: u64,
    pub recovered: u64,
    pub overhead_bytes: u64,
}

impl UltraCounters {
    pub fn snapshot(&self) -> UltraStats {
        UltraStats {
            copies_sent: self.copies_sent.load(Ordering::Relaxed),
            parity_sent: self.parity_sent.load(Ordering::Relaxed),
            parity_received: self.parity_received.load(Ordering::Relaxed),
            recovered: self.recovered.load(Ordering::Relaxed),
            overhead_bytes: self.overhead_bytes.load(Ordering::Relaxed),
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
            let mut out = vec![0u8; PARITY_HEADER + longest];
            let mut lengths = 0u16;
            for ciphertext in subgroup {
                lengths ^= u16::try_from(ciphertext.len()).unwrap_or(u16::MAX);
                for (slot, byte) in out[PARITY_HEADER..].iter_mut().zip(ciphertext) {
                    *slot ^= byte;
                }
            }
            out[0] = TAG;
            out[1] = VERSION;
            out[2] = j as u8;
            out[3] = (m << 4) | parities as u8;
            out[4] = members as u8;
            out[5] = k;
            out[6..8].copy_from_slice(&lengths.to_be_bytes());
            out[8..12].copy_from_slice(&group.index);
            out[12..16].copy_from_slice(&(group.first as u32).to_le_bytes());
            out
        })
        .collect()
}

/// A parsed parity header.
struct Parity<'a> {
    j: usize,
    parities: usize,
    members: usize,
    k: u8,
    m: u8,
    lengths: u16,
    index: [u8; 4],
    first_low: u32,
    xor: &'a [u8],
}

fn parse_parity(datagram: &[u8]) -> Option<Parity<'_>> {
    let header = datagram.get(..PARITY_HEADER)?;
    if header[0] != TAG || header[1] != VERSION {
        return None;
    }
    let parities = usize::from(header[3] & 0x0F);
    let (j, members) = (usize::from(header[2]), usize::from(header[4]));
    if parities == 0 || j >= parities || members == 0 || members > usize::from(MAX_GROUP) {
        return None;
    }
    Some(Parity {
        j,
        parities,
        members,
        k: header[5],
        m: header[3] >> 4,
        lengths: u16::from_be_bytes([header[6], header[7]]),
        index: header[8..12].try_into().ok()?,
        first_low: u32::from_le_bytes(header[12..16].try_into().ok()?),
        xor: &datagram[PARITY_HEADER..],
    })
}

/// The full counter whose low 32 bits are `low`, nearest to `near`.
fn widen(low: u32, near: u64) -> u64 {
    let base = (near & !0xFFFF_FFFF) | u64::from(low);
    [base.wrapping_sub(1 << 32), base, base.wrapping_add(1 << 32)]
        .into_iter()
        .min_by_key(|candidate| candidate.abs_diff(near))
        .unwrap_or(base)
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

    /// The datagram rebuilt from `parity`, when exactly one member of its
    /// subgroup is missing.
    fn rebuild(&self, parity: &Parity<'_>) -> Option<Vec<u8>> {
        let near = *self.newest.get(&parity.index)?;
        let first = widen(parity.first_low, near);
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
                None => return None,
            }
        }
        let counter = missing?;
        let length = usize::from(lengths);
        if length < WG_DATA_HEADER || length > xor.len() {
            return None;
        }
        let mut datagram = Vec::with_capacity(WG_DATA_HEADER + length);
        datagram.extend_from_slice(&[4, 0, 0, 0]);
        datagram.extend_from_slice(&parity.index);
        datagram.extend_from_slice(&counter.to_le_bytes());
        datagram.extend_from_slice(&xor[..length]);
        Some(datagram)
    }
}

/// The driver's underlay: the carrier it was given, plus ultra mode's repair
/// data on the way out and rebuilding on the way in. With the mode off and no
/// parity from the peer it only forwards.
pub(crate) struct UltraUnderlay {
    inner: Box<dyn Underlay>,
    mode: UltraMode,
    group: Option<Group>,
    received: Kept,
    /// Rebuild from parity: on when this side sends FEC or the peer does.
    decoding: bool,
    rebuilt: VecDeque<(Vec<u8>, Origin)>,
    counters: Arc<UltraCounters>,
}

impl UltraUnderlay {
    pub(crate) fn new(
        inner: Box<dyn Underlay>,
        mode: UltraMode,
        counters: Arc<UltraCounters>,
    ) -> Self {
        Self {
            inner,
            decoding: matches!(mode, UltraMode::Fec { .. }),
            mode,
            group: None,
            received: Kept::default(),
            rebuilt: VecDeque::new(),
            counters,
        }
    }

    /// Carry on over a new carrier after a network change; the mode stays.
    pub(crate) fn replace(&mut self, inner: Box<dyn Underlay>) {
        self.close_group();
        self.inner = inner;
        self.rebuilt.clear();
    }

    fn forward(&mut self, datagram: &[u8], priority: Option<Priority>) {
        match priority {
            Some(priority) => self.inner.send_classified(datagram, priority),
            None => self.inner.send(datagram),
        }
    }

    fn send_with(&mut self, datagram: &[u8], priority: Option<Priority>) {
        self.forward(datagram, priority);
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
            UltraMode::Fec { group, .. } => match data_id(datagram) {
                Some((index, counter)) => {
                    self.add_member(index, counter, datagram, priority, group)
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
        let follows = self.group.as_ref().is_some_and(|group| {
            group.index == index
                && group.first.wrapping_add(group.ciphertexts.len() as u64) == counter
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
        group.ciphertexts.push(datagram[WG_DATA_HEADER..].to_vec());
        group.priority = priority.or(group.priority);
        if group.ciphertexts.len() >= usize::from(k) {
            self.close_group();
        }
    }

    fn close_group(&mut self) {
        let Some(group) = self.group.take() else { return };
        let UltraMode::Fec { group: k, parity: m } = self.mode else { return };
        for parity in parity_datagrams(&group, k, m) {
            UltraCounters::add(&self.counters.parity_sent, 1);
            UltraCounters::add(&self.counters.overhead_bytes, parity.len() as u64);
            self.forward(&parity, group.priority);
        }
    }

    fn on_parity(&mut self, datagram: &[u8], origin: Origin) {
        let Some(parity) = parse_parity(datagram) else { return };
        UltraCounters::add(&self.counters.parity_received, 1);
        if !self.decoding {
            // Kept datagrams start now; this first group is not rebuilt.
            self.decoding = true;
        }
        if self.mode == UltraMode::Off
            && let Some(mode) = UltraMode::fec(parity.k, parity.m)
        {
            self.mode = mode;
        }
        if let Some(rebuilt) = self.received.rebuild(&parity) {
            if let Some((index, counter)) = data_id(&rebuilt) {
                self.received.keep(index, counter, &rebuilt[WG_DATA_HEADER..]);
            }
            UltraCounters::add(&self.counters.recovered, 1);
            self.rebuilt.push_back((rebuilt, origin));
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
        loop {
            if let Some((datagram, origin)) = self.rebuilt.pop_front() {
                if let Some(slot) = buffer.get_mut(..datagram.len()) {
                    slot.copy_from_slice(&datagram);
                    return Poll::Ready(Ok(Received { len: datagram.len(), origin }));
                }
                continue;
            }
            let received = ready!(self.inner.poll_recv(cx, buffer))?;
            let Some(datagram) = buffer.get(..received.len) else {
                return Poll::Ready(Ok(received));
            };
            if datagram.first() == Some(&TAG) {
                let datagram = datagram.to_vec();
                self.on_parity(&datagram, received.origin);
                continue;
            }
            if self.decoding
                && let Some((index, counter)) = data_id(datagram)
            {
                self.received.keep(index, counter, &datagram[WG_DATA_HEADER..]);
            }
            return Poll::Ready(Ok(received));
        }
    }

    fn authenticated(&mut self, origin: Origin) {
        self.inner.authenticated(origin);
    }

    fn has_peer(&self) -> bool {
        self.inner.has_peer()
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
                .filter_map(|p| received.rebuild(&parse_parity(p).unwrap()))
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
        assert!(received.rebuild(&parse_parity(parity).unwrap()).is_none());
    }

    #[test]
    fn parity_is_never_a_wireguard_or_stun_message() {
        let group =
            Group { index: [0; 4], first: 0, ciphertexts: vec![vec![0; 32]], priority: None };
        let parity = &parity_datagrams(&group, 8, 2)[0];
        assert_eq!(classify(parity), DatagramClass::Unknown);
    }
}
