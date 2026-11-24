//! One endpoint of one hop/1 leg: its egress queue (R5), the DATA it keeps
//! for repair, the NACKs and parity it sends (R4), and RTT and loss.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::queue::EgressQueue;
use super::rx::{PendingParity, Rx, Seen};
use super::{
    DATA_HEADER_LEN, HOP_MAGIC, HopClass, HopError, HopMsg, MAX_RECORD_BYTES, Record, StreamTag,
    TYPE_DATA, is_hop,
};

/// The receiver waits at least this long for a reordered DATA before it
/// NACKs a gap (`max(3 ms, RTT / 8)`).
pub const MIN_REORDER_GUARD: Duration = Duration::from_millis(3);
/// The sender keeps a DATA for repair `4 x RTT + 50 ms` past its send.
pub const RETAIN_SLACK: Duration = Duration::from_millis(50);
pub const RETAIN_MAX: Duration = Duration::from_secs(2);
/// And at most this many bytes of them per leg.
pub const RETAIN_BYTES: usize = 256 * 1024;
/// A gap is asked for at most this many times.
pub const MAX_ASKS: u8 = 3;
/// An open parity group is closed `max(FEC_FLUSH, RTT / 8)` after its last
/// DATA, so the tail of a burst is covered too, and at most `RTT / 2` after
/// its first, so its parity still beats a NACK round trip.
pub const FEC_FLUSH: Duration = Duration::from_millis(5);
// A lost last DATA opens no gap the receiver can see, so the sender resends
// it once `RTT + reorder guard` after it went out if nothing followed (a
// tail-loss probe; a duplicate when nothing was lost).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LegMode {
    /// hop/1 both ways.
    Hop,
    /// Plain datagrams both ways (a TURN-like forwarder): each record goes
    /// out as its bytes alone, a received datagram is one untagged record
    /// classed by its shape. The first hop/1 datagram received upgrades the
    /// leg to [`LegMode::Hop`] (a Mac that speaks hop/1 toward the PoP).
    Plain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LegConfig {
    pub mode: LegMode,
    /// Largest DATA datagram the packer builds from several records. A
    /// single larger record still goes, alone.
    pub mtu: usize,
    /// R4: NACK gaps and resend what the peer NACKs.
    pub nack: bool,
    /// R4: send XOR parity when the peer reports loss.
    pub fec: bool,
    /// R5: latest-wins for class 1 in the egress queue, and no resend of a
    /// superseded class-1 DATA.
    pub latest_wins: bool,
    /// RTT assumed until the first PONG.
    pub initial_rtt: Duration,
    pub ping_interval: Duration,
    /// Egress pacing in bytes per second (`None`: send as fast as polled).
    pub pacing_rate: Option<u64>,
}

impl Default for LegConfig {
    fn default() -> Self {
        Self {
            mode: LegMode::Hop,
            mtu: 1200,
            nack: true,
            fec: true,
            latest_wins: true,
            initial_rtt: Duration::from_millis(100),
            ping_interval: Duration::from_secs(1),
            pacing_rate: None,
        }
    }
}

impl LegConfig {
    /// A plain leg (no repair) that still queues by class.
    pub fn plain() -> Self {
        Self { mode: LegMode::Plain, ..Self::default() }
    }
}

/// How a delivered record arrived.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Repair {
    None,
    /// Resent after this leg's NACK.
    Nack,
    /// Rebuilt from a PARITY.
    Fec,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delivered {
    pub record: Record,
    pub repair: Repair,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LegStats {
    pub srtt: Duration,
    /// Loss this endpoint measured on what it receives.
    pub loss_permille: u16,
    /// Loss the peer reported on what this endpoint sends.
    pub peer_loss_permille: u16,
    /// DATA datagrams sent (first sends).
    pub sent: u64,
    pub resent: u64,
    pub parity_sent: u64,
    pub repaired_by_nack: u64,
    pub repaired_by_fec: u64,
    pub nacks_sent: u64,
    /// Class-1 records R5 dropped from the egress queue.
    pub dropped_superseded: u64,
    /// Records dropped past a class's byte bound (or media past its age).
    pub dropped_overflow: u64,
    /// NACKed DATA not resent because every record in it was superseded.
    pub skipped_superseded_resend: u64,
    /// Last DATA resent once after a quiet RTT (also counted in `resent`).
    pub tail_probes: u64,
    pub delivered: u64,
    pub duplicates: u64,
    pub malformed: u64,
}

struct Sent {
    seq: u64,
    at: Instant,
    bytes: Vec<u8>,
    tags: Vec<StreamTag>,
    /// Every record is tagged class 1.
    supersedable: bool,
}

struct FecGroup {
    first: u64,
    count: u8,
    size: u8,
    xor: Vec<u8>,
    len_xor: u16,
    first_at: Instant,
    last_at: Instant,
}

pub struct Leg {
    config: LegConfig,
    hop: bool,
    epoch: Instant,
    last_now: Instant,
    queue: EgressQueue,
    next_seq: u64,
    retain: VecDeque<Sent>,
    retain_bytes: usize,
    resend: VecDeque<u64>,
    fec: Option<FecGroup>,
    /// When to probe the tail, and the DATA to resend then.
    tail_probe: Option<(Instant, u64)>,
    parity_out: VecDeque<Vec<u8>>,
    peer_loss: u16,
    pace_at: Instant,
    control_out: VecDeque<Vec<u8>>,
    next_ping: Instant,
    ping_nonce: u32,
    srtt: Option<Duration>,
    rx: Rx,
    stats: LegStats,
}

impl Leg {
    /// `initial_seq` is this direction's first `hop_seq`; pass a random
    /// value.
    pub fn new(config: LegConfig, initial_seq: u32, now: Instant) -> Self {
        Self {
            config,
            hop: config.mode == LegMode::Hop,
            epoch: now,
            last_now: now,
            queue: EgressQueue::new(config.latest_wins),
            next_seq: (1u64 << 32) + u64::from(initial_seq),
            retain: VecDeque::new(),
            retain_bytes: 0,
            resend: VecDeque::new(),
            fec: None,
            tail_probe: None,
            parity_out: VecDeque::new(),
            peer_loss: 0,
            pace_at: now,
            control_out: VecDeque::new(),
            next_ping: now,
            ping_nonce: 0,
            srtt: None,
            rx: Rx::new(),
            stats: LegStats::default(),
        }
    }

    pub fn is_hop(&self) -> bool {
        self.hop
    }

    pub fn set_pacing_rate(&mut self, bytes_per_s: Option<u64>) {
        self.config.pacing_rate = bytes_per_s.filter(|&rate| rate > 0);
    }

    /// Bytes of records waiting in the egress queue.
    pub fn queued_bytes(&self) -> usize {
        self.queue.bytes()
    }

    pub fn stats(&self) -> LegStats {
        LegStats {
            srtt: self.rtt(),
            loss_permille: self.rx.loss_permille,
            peer_loss_permille: self.peer_loss,
            dropped_overflow: self.stats.dropped_overflow + self.queue.media_expired,
            ..self.stats
        }
    }

    fn rtt(&self) -> Duration {
        self.srtt.unwrap_or(self.config.initial_rtt)
    }

    /// Queues a record for this leg. A class-1 record replaces a queued
    /// older one of its stream, or is dropped if a newer one is queued or
    /// was sent (R5).
    pub fn send(&mut self, record: Record, now: Instant) -> Result<(), HopError> {
        if record.bytes.is_empty() {
            return Err(HopError::EmptyRecord);
        }
        if record.bytes.len() > MAX_RECORD_BYTES {
            return Err(HopError::TooLarge(record.bytes.len()));
        }
        if record.tag.is_some() && record.class != HopClass::Interactive {
            return Err(HopError::TagClass);
        }
        self.last_now = now;
        let outcome = self.queue.push(record, now);
        self.stats.dropped_superseded += outcome.superseded;
        self.stats.dropped_overflow += outcome.overflow;
        Ok(())
    }

    /// The next datagram to send, if any is due now. Call until `None`,
    /// then again at [`Leg::poll_timeout`] or after `send`/`handle`.
    pub fn poll_transmit(&mut self, now: Instant) -> Option<Vec<u8>> {
        self.last_now = now;
        self.queue.expire(now);
        if self.hop {
            self.housekeep(now);
        }
        if let Some(datagram) = self.control_out.pop_front() {
            return Some(datagram);
        }
        if self.config.pacing_rate.is_some() && now < self.pace_at {
            return None;
        }
        let datagram = if self.hop {
            self.next_paced(now)
        } else {
            self.queue.pop().map(|record| record.bytes)
        }?;
        self.charge(datagram.len(), now);
        Some(datagram)
    }

    /// When [`Leg::poll_transmit`] next has something to do. A time at or
    /// before now means at once.
    pub fn poll_timeout(&self) -> Option<Instant> {
        let mut earliest: Option<Instant> = None;
        let mut at = |time: Instant| earliest = Some(earliest.map_or(time, |e| e.min(time)));
        if !self.control_out.is_empty() {
            at(self.last_now);
        }
        if !self.queue.is_empty() || !self.resend.is_empty() || !self.parity_out.is_empty() {
            at(if self.config.pacing_rate.is_some() {
                self.pace_at.max(self.last_now)
            } else {
                self.last_now
            });
        }
        if self.hop {
            at(self.next_ping);
            if let Some(next) = self.rx.missing.values().map(|m| m.next_at).min() {
                at(next);
            }
            if let Some(group) = &self.fec {
                at(self.fec_close_at(group));
            }
            if let Some((probe_at, _)) = self.tail_probe {
                at(probe_at);
            }
        }
        earliest
    }

    /// A datagram from the leg. Returns the records it delivers, at once
    /// and in any order.
    pub fn handle(&mut self, datagram: &[u8], now: Instant) -> Vec<Delivered> {
        self.last_now = now;
        let mut out = Vec::new();
        let Some(&first) = datagram.first() else { return out };
        if !is_hop(first) {
            self.stats.delivered += 1;
            out.push(Delivered {
                record: Record::new(HopClass::of_wireguard(datagram), datagram.to_vec()),
                repair: Repair::None,
            });
            return out;
        }
        let Ok(msg) = HopMsg::decode(datagram) else {
            self.stats.malformed += 1;
            return out;
        };
        if !self.hop {
            self.hop = true;
            self.next_ping = now;
        }
        match msg {
            HopMsg::Data { seq, records } => {
                self.on_data(seq, records, datagram, now, false, &mut out);
                self.recover(now, &mut out);
            }
            HopMsg::Parity { first_seq, count, len_xor, xor } => {
                if let Some(first) = self.rx.extend(first_seq).filter(|_| self.rx.highest.is_some())
                {
                    self.rx.add_parity(PendingParity { first, count, len_xor, xor }, now);
                    self.recover(now, &mut out);
                }
            }
            HopMsg::Nack { base, bitmap, loss_permille, .. } => {
                self.peer_loss = loss_permille;
                self.on_nack(base, bitmap);
            }
            HopMsg::Ping { nonce, sent_ms } => {
                let pong = HopMsg::Pong { nonce, sent_ms, loss_permille: self.rx.loss_permille };
                if let Ok(bytes) = pong.encode() {
                    self.control_out.push_back(bytes);
                }
            }
            HopMsg::Pong { sent_ms, loss_permille, .. } => {
                self.peer_loss = loss_permille;
                let elapsed = self.ms(now).wrapping_sub(sent_ms);
                if elapsed < 60_000 {
                    let sample = Duration::from_millis(u64::from(elapsed));
                    self.srtt = Some(match self.srtt {
                        None => sample,
                        Some(srtt) => (srtt * 7 + sample) / 8,
                    });
                }
            }
            // The PoP's allocation layer reads these before the leg.
            HopMsg::Bind { .. } | HopMsg::BindOk { .. } | HopMsg::Error { .. } => {}
        }
        out
    }

    fn ms(&self, now: Instant) -> u32 {
        now.saturating_duration_since(self.epoch).as_millis() as u32
    }

    fn guard(&self) -> Duration {
        (self.rtt() / 8).max(MIN_REORDER_GUARD)
    }

    fn on_data(
        &mut self,
        wire_seq: u32,
        records: Vec<Record>,
        raw: &[u8],
        now: Instant,
        by_fec: bool,
        out: &mut Vec<Delivered>,
    ) {
        let Some(seq) = self.rx.extend(wire_seq) else { return };
        let guard = self.guard();
        let was_missing = self.rx.missing.remove(&seq);
        if self.rx.arrive(seq, now, guard) != Seen::Fresh {
            self.stats.duplicates += 1;
            return;
        }
        let repair = if by_fec {
            if !was_missing.as_ref().is_some_and(|m| m.counted) {
                self.rx.note_lost();
            }
            self.stats.repaired_by_fec += 1;
            Repair::Fec
        } else if was_missing.is_some_and(|m| m.asks > 0) {
            self.stats.repaired_by_nack += 1;
            Repair::Nack
        } else {
            Repair::None
        };
        if self.rx.wants_raw(now) {
            self.rx.keep_raw(seq, raw);
        }
        for record in records {
            self.stats.delivered += 1;
            out.push(Delivered { record, repair });
        }
    }

    fn recover(&mut self, now: Instant, out: &mut Vec<Delivered>) {
        while let Some((seq, datagram)) = self.rx.recover_one() {
            if let Ok(HopMsg::Data { seq: wire, records }) = HopMsg::decode(&datagram)
                && self.rx.extend(wire) == Some(seq)
            {
                self.on_data(wire, records, &datagram, now, true, out);
            }
        }
    }

    fn on_nack(&mut self, base: u32, bitmap: u64) {
        let Some(last) = self.next_seq.checked_sub(1) else { return };
        let delta = i64::from(base.wrapping_sub(last as u32) as i32);
        let Some(base) = i64::try_from(last).ok().and_then(|l| l.checked_add(delta)) else {
            return;
        };
        let Ok(base) = u64::try_from(base) else { return };
        for bit in 0..64u64 {
            if bitmap & (1 << bit) == 0 {
                continue;
            }
            let seq = base + bit;
            if seq < self.next_seq && !self.resend.contains(&seq) {
                self.resend.push_back(seq);
            }
        }
    }

    fn find_sent(&self, seq: u64) -> Option<&Sent> {
        let front = self.retain.front()?.seq;
        let index = usize::try_from(seq.checked_sub(front)?).ok()?;
        self.retain.get(index).filter(|sent| sent.seq == seq)
    }

    fn superseded(&self, sent: &Sent) -> bool {
        self.config.latest_wins
            && sent.supersedable
            && sent.tags.iter().all(|&tag| self.queue.strictly_superseded(tag))
    }

    fn next_paced(&mut self, now: Instant) -> Option<Vec<u8>> {
        while let Some(seq) = self.resend.pop_front() {
            let Some(sent) = self.find_sent(seq) else { continue };
            if self.superseded(sent) {
                self.stats.skipped_superseded_resend += 1;
                continue;
            }
            let bytes = sent.bytes.clone();
            self.stats.resent += 1;
            return Some(bytes);
        }
        if let Some(parity) = self.parity_out.pop_front() {
            return Some(parity);
        }
        self.build_data(now)
    }

    /// Packs queued records into one DATA, up to the MTU.
    fn build_data(&mut self, now: Instant) -> Option<Vec<u8>> {
        let first = self.queue.pop()?;
        let seq = self.next_seq;
        let mut datagram = Vec::with_capacity(self.config.mtu);
        datagram.extend_from_slice(&[HOP_MAGIC, TYPE_DATA]);
        datagram.extend_from_slice(&(seq as u32).to_be_bytes());
        let mut tags = Vec::new();
        let mut supersedable = true;
        let mut record = Some(first);
        while let Some(next) = record.take() {
            match (next.class, next.tag) {
                (HopClass::Interactive, Some(tag)) => tags.push(tag),
                _ => supersedable = false,
            }
            // Records were checked in `send`; one that fails here is dropped.
            if next.encode_into(&mut datagram).is_err() {
                self.stats.malformed += 1;
            }
            if self.queue.peek_len().is_some_and(|len| datagram.len() + len <= self.config.mtu) {
                record = self.queue.pop();
            }
        }
        if datagram.len() <= DATA_HEADER_LEN {
            return None;
        }
        self.next_seq += 1;
        self.stats.sent += 1;
        self.retain_bytes += datagram.len();
        self.retain.push_back(Sent { seq, at: now, bytes: datagram.clone(), tags, supersedable });
        while self.retain_bytes > RETAIN_BYTES {
            let Some(old) = self.retain.pop_front() else { break };
            self.retain_bytes = self.retain_bytes.saturating_sub(old.bytes.len());
        }
        self.add_to_fec_group(seq, &datagram, now);
        if self.config.nack {
            self.tail_probe = Some((after(now, self.rtt() + self.guard()), seq));
        }
        Some(datagram)
    }

    fn add_to_fec_group(&mut self, seq: u64, datagram: &[u8], now: Instant) {
        if !self.config.fec || self.peer_loss == 0 {
            self.fec = None;
            return;
        }
        let size = fec_group_size(self.peer_loss);
        if self.fec.as_ref().is_some_and(|g| g.first + u64::from(g.count) != seq) {
            self.fec = None;
        }
        let group = self.fec.get_or_insert_with(|| FecGroup {
            first: seq,
            count: 0,
            size,
            xor: Vec::new(),
            len_xor: 0,
            first_at: now,
            last_at: now,
        });
        if group.xor.len() < datagram.len() {
            group.xor.resize(datagram.len(), 0);
        }
        for (out, byte) in group.xor.iter_mut().zip(datagram) {
            *out ^= byte;
        }
        group.len_xor ^= datagram.len() as u16;
        group.count += 1;
        group.last_at = now;
        if group.count >= group.size {
            self.close_fec_group();
        }
    }

    fn fec_close_at(&self, group: &FecGroup) -> Instant {
        let idle = after(group.last_at, (self.rtt() / 8).max(FEC_FLUSH));
        idle.min(after(group.first_at, (self.rtt() / 2).max(FEC_FLUSH)))
    }

    fn close_fec_group(&mut self) {
        let Some(group) = self.fec.take() else { return };
        let parity = HopMsg::Parity {
            first_seq: group.first as u32,
            count: group.count,
            len_xor: group.len_xor,
            xor: group.xor,
        };
        if let Ok(bytes) = parity.encode() {
            self.parity_out.push_back(bytes);
            self.stats.parity_sent += 1;
        }
    }

    fn housekeep(&mut self, now: Instant) {
        let keep = (self.rtt() * 4 + RETAIN_SLACK).min(RETAIN_MAX);
        while self.retain.front().is_some_and(|s| now.saturating_duration_since(s.at) > keep) {
            if let Some(old) = self.retain.pop_front() {
                self.retain_bytes = self.retain_bytes.saturating_sub(old.bytes.len());
            }
        }
        if self.fec.as_ref().is_some_and(|g| now >= self.fec_close_at(g)) {
            self.close_fec_group();
        }
        if let Some((probe_at, seq)) = self.tail_probe
            && now >= probe_at
        {
            self.tail_probe = None;
            if seq + 1 == self.next_seq && !self.resend.contains(&seq) {
                self.resend.push_back(seq);
                self.stats.tail_probes += 1;
            }
        }
        if now >= self.next_ping {
            self.ping_nonce = self.ping_nonce.wrapping_add(1);
            let ping = HopMsg::Ping { nonce: self.ping_nonce, sent_ms: self.ms(now) };
            if let Ok(bytes) = ping.encode() {
                self.control_out.push_back(bytes);
            }
            self.next_ping = after(now, self.config.ping_interval);
        }
        self.make_nacks(now);
    }

    fn make_nacks(&mut self, now: Instant) {
        let reask = self.rtt() * 3 / 2;
        let mut due = Vec::new();
        let mut gone = Vec::new();
        let mut newly_lost = 0;
        for (&seq, missing) in &mut self.rx.missing {
            if missing.next_at > now {
                continue;
            }
            if !missing.counted {
                missing.counted = true;
                newly_lost += 1;
            }
            if !self.config.nack || missing.asks >= MAX_ASKS {
                gone.push(seq);
                continue;
            }
            missing.asks += 1;
            missing.next_at = after(now, reask);
            due.push(seq);
        }
        for _ in 0..newly_lost {
            self.rx.note_lost();
        }
        for seq in gone {
            self.rx.missing.remove(&seq);
        }
        let highest = self.rx.highest.unwrap_or(0) as u32;
        let loss_permille = self.rx.loss_permille;
        let mut pending: Option<(u64, u64)> = None;
        let mut nacks = Vec::new();
        for seq in due {
            match &mut pending {
                Some((base, bitmap)) if seq - *base < 64 => *bitmap |= 1 << (seq - *base),
                _ => {
                    nacks.extend(pending.take());
                    pending = Some((seq, 1));
                }
            }
        }
        nacks.extend(pending);
        for (base, bitmap) in nacks {
            let nack = HopMsg::Nack { base: base as u32, bitmap, highest, loss_permille };
            if let Ok(bytes) = nack.encode() {
                self.control_out.push_back(bytes);
                self.stats.nacks_sent += 1;
            }
        }
    }

    fn charge(&mut self, len: usize, now: Instant) {
        let Some(rate) = self.config.pacing_rate else { return };
        let nanos = |bytes: usize| {
            Duration::from_nanos((bytes as u64).saturating_mul(1_000_000_000) / rate)
        };
        let burst = nanos(2 * self.config.mtu);
        let floor = now.checked_sub(burst).unwrap_or(now);
        self.pace_at = after(self.pace_at.max(floor), nanos(len));
    }
}

/// One PARITY per this many DATA, from the loss the peer reports.
pub fn fec_group_size(loss_permille: u16) -> u8 {
    match loss_permille {
        50.. => 4,
        20.. => 8,
        _ => 16,
    }
}

fn after(time: Instant, by: Duration) -> Instant {
    time.checked_add(by).unwrap_or(time)
}
