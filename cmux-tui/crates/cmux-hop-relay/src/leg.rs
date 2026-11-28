//! One hop/1 leg, sans-IO: what the PoP and hop-bench drive per peer.
//!
//! Interim implementation of docs/cmux-next/relay-pop-hop.md's sender and
//! receiver rules (DATA, NACK, PING/PONG; R4 repair and R5 latest-wins) until
//! `cmux_transport::hop::Leg` lands on lane/relay-pop-repair; then this module
//! becomes an adapter over it.
//!
//! PARITY: once the peer reports loss, every `k` DATA (k from the loss: 16 at
//! up to 1 %, 8 at 3 %, 4 at 10 %, else 2) are followed by their XOR, and a
//! partial group is closed after a short idle (`max(5 ms, RTT / 8)`). The idle
//! close is what saves a lone keystroke: a gap is only seen when a later DATA
//! arrives, which at keystroke cadence is after the sender stopped keeping it
//! for NACK repair. A group of one is a copy.
//!
//! Egress order, highest first: leg control (NACK, PING, PONG), resends,
//! then records by class: 0 control, 2 input, 1 interactive state, 3 bulk and
//! 4 media. A class-1 record replaces a queued class-1 record of its key with
//! a lower key_seq (R5). Queued records pack into one DATA up to the MTU.

use std::collections::{BTreeMap, VecDeque};
use std::time::Duration;

use tokio::time::Instant;

use crate::wire::MAGIC;

pub const T_DATA: u8 = 1;
pub const T_NACK: u8 = 2;
pub const T_PARITY: u8 = 3;
pub const T_PING: u8 = 6;
pub const T_PONG: u8 = 7;

/// Payload budget of one DATA (a 1280-byte IPv6 minimum path fits it with
/// the 8-byte UDP and 40-byte IPv6 headers to spare).
pub const MTU: usize = 1400;
const KEEP_BYTES: usize = 256 * 1024;
const DEDUP_WINDOW: u32 = 1024;
const MAX_ASKS: u32 = 3;
/// Received DATA kept for PARITY recovery.
const RECENT_SEQS: usize = 256;
const PING_EVERY: Duration = Duration::from_secs(1);
/// Per-class queue bounds (mobile-link class_queue.rs): past it a class
/// drops its oldest record.
const CLASS_BYTES: [usize; 5] = [16 * 1024, 64 * 1024, 64 * 1024, 256 * 1024, 256 * 1024];
/// Dequeue order by class index.
const ORDER: [u8; 5] = [0, 2, 1, 3, 4];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub class: u8,
    pub tag: Option<(u32, u32)>,
    pub bytes: Vec<u8>,
}

impl Record {
    fn wire_len(&self) -> usize {
        4 + self.bytes.len() + if self.tag.is_some() { 8 } else { 0 }
    }

    fn encode_into(&self, out: &mut Vec<u8>) {
        out.push(self.class);
        out.push(u8::from(self.tag.is_some()));
        if let Some((key, seq)) = self.tag {
            out.extend_from_slice(&key.to_be_bytes());
            out.extend_from_slice(&seq.to_be_bytes());
        }
        let len = u16::try_from(self.bytes.len()).unwrap_or(u16::MAX);
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(self.bytes.get(..usize::from(len)).unwrap_or_default());
    }
}

pub fn decode_records(mut body: &[u8]) -> Option<Vec<Record>> {
    let mut out = Vec::new();
    while !body.is_empty() {
        let ([class, flags], rest) = body.split_first_chunk::<2>()?;
        let (tag, rest) = if flags & 1 == 1 {
            let (k, rest) = rest.split_first_chunk::<4>()?;
            let (s, rest) = rest.split_first_chunk::<4>()?;
            (Some((u32::from_be_bytes(*k), u32::from_be_bytes(*s))), rest)
        } else {
            (None, rest)
        };
        let (len, rest) = rest.split_first_chunk::<2>()?;
        let len = usize::from(u16::from_be_bytes(*len));
        let bytes = rest.get(..len)?.to_vec();
        body = rest.get(len..)?;
        out.push(Record { class: *class, tag, bytes });
    }
    Some(out)
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct LegStats {
    pub rtt_ms: Option<f64>,
    /// Loss this end measured on what it received.
    pub loss_permille: u16,
    /// Loss the peer reported on what this end sent.
    pub peer_loss_permille: u16,
    pub sent: u64,
    pub resent: u64,
    /// Gaps filled by a resend after this end NACKed them.
    pub repaired: u64,
    pub received: u64,
    pub nacks_sent: u64,
    pub parity_sent: u64,
    /// DATA rebuilt from a PARITY (a subset of `repaired`).
    pub fec_recovered: u64,
    /// Class-1 records replaced in the queue or not resent (R5).
    pub superseded: u64,
    /// Records that rode in a DATA beside another record.
    pub coalesced: u64,
    /// Records dropped by a class's byte bound.
    pub dropped: u64,
    pub queued_bytes: usize,
}

struct Sent {
    at: Instant,
    datagram: Vec<u8>,
    /// The class-1 tags it carried, and whether it carried anything else.
    tags: Vec<(u32, u32)>,
    untagged: bool,
}

struct Missing {
    next_ask: Instant,
    asks: u32,
}

pub struct HopLeg {
    epoch: Instant,
    // Sender.
    next_seq: u32,
    queues: [VecDeque<Record>; 5],
    queue_bytes: [usize; 5],
    /// Highest key_seq queued or sent per class-1 key.
    latest: BTreeMap<u32, u32>,
    sent: BTreeMap<u32, Sent>,
    sent_bytes: usize,
    resend: VecDeque<u32>,
    control: VecDeque<Vec<u8>>,
    next_ping: Instant,
    ping_nonce: u32,
    /// DATA sent since the last PARITY, and when the newest left.
    group: Vec<(u32, Vec<u8>)>,
    last_data_at: Instant,
    // Receiver.
    highest: Option<u32>,
    seen: BTreeMap<u32, ()>,
    missing: BTreeMap<u32, Missing>,
    recent: BTreeMap<u32, Vec<u8>>,
    loss_ewma: f64,
    srtt: Option<f64>,
    stats: LegStats,
}

impl HopLeg {
    pub fn new(now: Instant) -> Self {
        let mut seed = [0_u8; 4];
        let _ = getrandom::fill(&mut seed);
        Self {
            epoch: now,
            next_seq: u32::from_be_bytes(seed),
            queues: Default::default(),
            queue_bytes: [0; 5],
            latest: BTreeMap::new(),
            sent: BTreeMap::new(),
            sent_bytes: 0,
            resend: VecDeque::new(),
            control: VecDeque::new(),
            next_ping: now,
            ping_nonce: 0,
            group: Vec::new(),
            last_data_at: now,
            highest: None,
            seen: BTreeMap::new(),
            missing: BTreeMap::new(),
            recent: BTreeMap::new(),
            loss_ewma: 0.0,
            srtt: None,
            stats: LegStats::default(),
        }
    }

    fn rtt(&self) -> Duration {
        Duration::from_secs_f64(self.srtt.unwrap_or(100.0) / 1000.0)
    }

    fn ms(&self, now: Instant) -> u32 {
        u32::try_from(now.saturating_duration_since(self.epoch).as_millis() % (1 << 32))
            .unwrap_or(0)
    }

    /// Queues a record for the peer (R5 applies to class 1).
    pub fn push(&mut self, class: u8, tag: Option<(u32, u32)>, bytes: &[u8], _now: Instant) {
        let idx = usize::from(class.min(4));
        let record = Record { class, tag, bytes: bytes.to_vec() };
        if class == 1
            && let Some((key, seq)) = tag
        {
            if self.latest.get(&key).is_some_and(|&l| seq_lt(seq, l)) {
                self.stats.superseded += 1;
                return;
            }
            self.latest.insert(key, seq);
            if let Some(queue) = self.queues.get_mut(idx) {
                let before = queue.len();
                let mut freed = 0;
                queue.retain(|r| {
                    let stale = r.tag.is_some_and(|(k, s)| k == key && seq_lt(s, seq));
                    if stale {
                        freed += r.wire_len();
                    }
                    !stale
                });
                self.stats.superseded += (before - queue.len()) as u64;
                if let Some(b) = self.queue_bytes.get_mut(idx) {
                    *b -= freed;
                }
            }
        }
        let len = record.wire_len();
        let bound = CLASS_BYTES.get(idx).copied().unwrap_or(0);
        if let (Some(queue), Some(bytes)) =
            (self.queues.get_mut(idx), self.queue_bytes.get_mut(idx))
        {
            queue.push_back(record);
            *bytes += len;
            while *bytes > bound {
                let Some(old) = queue.pop_front() else { break };
                *bytes -= old.wire_len();
                self.stats.dropped += 1;
            }
        }
    }

    pub fn has_pending(&self) -> bool {
        !self.control.is_empty()
            || !self.resend.is_empty()
            || self.queue_bytes.iter().any(|&b| b > 0)
    }

    /// One received datagram; returns the records it delivers.
    pub fn handle(&mut self, datagram: &[u8], now: Instant) -> Vec<Record> {
        let [MAGIC, kind, body @ ..] = datagram else { return Vec::new() };
        match *kind {
            T_DATA => self.on_data(datagram, body, now),
            T_PARITY => self.on_parity(body, now),
            T_NACK => {
                self.on_nack(body, now);
                Vec::new()
            }
            T_PING => {
                if let Some((head, _)) = body.split_first_chunk::<8>() {
                    let mut pong = vec![MAGIC, T_PONG];
                    pong.extend_from_slice(head);
                    pong.extend_from_slice(&self.loss_permille().to_be_bytes());
                    self.control.push_back(pong);
                }
                Vec::new()
            }
            T_PONG => {
                if let Some((_nonce, rest)) = body.split_first_chunk::<4>()
                    && let Some((sent_ms, rest)) = rest.split_first_chunk::<4>()
                {
                    let sent_ms = u32::from_be_bytes(*sent_ms);
                    let rtt = f64::from(self.ms(now).wrapping_sub(sent_ms));
                    if rtt < 60_000.0 {
                        self.srtt = Some(self.srtt.map_or(rtt, |s| 0.875 * s + 0.125 * rtt));
                    }
                    if let Some((loss, _)) = rest.split_first_chunk::<2>() {
                        self.stats.peer_loss_permille = u16::from_be_bytes(*loss);
                    }
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn loss_permille(&self) -> u16 {
        (self.loss_ewma * 1000.0).round().clamp(0.0, 1000.0) as u16
    }

    /// PARITY group size for the loss the peer reports; 0: none.
    fn parity_k(&self) -> usize {
        match self.stats.peer_loss_permille {
            0 => 0,
            1..=10 => 16,
            11..=30 => 8,
            31..=100 => 4,
            _ => 2,
        }
    }

    fn tail_delay(&self) -> Duration {
        self.rtt().div_f64(8.0).max(Duration::from_millis(5))
    }

    fn close_group(&mut self) {
        let group = std::mem::take(&mut self.group);
        let Some((first, _)) = group.first() else { return };
        let longest = group.iter().map(|(_, d)| d.len()).max().unwrap_or(0);
        let mut xor = vec![0_u8; longest];
        let mut len_xor = 0_u16;
        for (_, d) in &group {
            len_xor ^= u16::try_from(d.len()).unwrap_or(u16::MAX);
            for (x, b) in xor.iter_mut().zip(d) {
                *x ^= b;
            }
        }
        let mut out = vec![MAGIC, T_PARITY];
        out.extend_from_slice(&first.to_be_bytes());
        out.push(u8::try_from(group.len()).unwrap_or(u8::MAX));
        out.extend_from_slice(&len_xor.to_be_bytes());
        out.extend_from_slice(&xor);
        self.control.push_back(out);
        self.stats.parity_sent += 1;
    }

    fn on_parity(&mut self, body: &[u8], now: Instant) -> Vec<Record> {
        let Some((first, rest)) = body.split_first_chunk::<4>() else { return Vec::new() };
        let Some(([count], rest)) = rest.split_first_chunk::<1>() else { return Vec::new() };
        let Some((len_xor, xor)) = rest.split_first_chunk::<2>() else { return Vec::new() };
        let first = u32::from_be_bytes(*first);
        let mut lost = None;
        let mut out = xor.to_vec();
        let mut len = u16::from_be_bytes(*len_xor);
        for i in 0..u32::from(*count) {
            let seq = first.wrapping_add(i);
            match self.recent.get(&seq) {
                Some(d) => {
                    len ^= u16::try_from(d.len()).unwrap_or(u16::MAX);
                    for (x, b) in out.iter_mut().zip(d) {
                        *x ^= b;
                    }
                }
                None if lost.is_none() => lost = Some(seq),
                // Two missing: this PARITY cannot help.
                None => return Vec::new(),
            }
        }
        let Some(seq) = lost else { return Vec::new() };
        let within_window = self.highest.is_none_or(|h| !seq_lt(seq, h.wrapping_sub(DEDUP_WINDOW)));
        if self.seen.contains_key(&seq) || !within_window {
            return Vec::new();
        }
        out.truncate(usize::from(len));
        let ok = matches!(out.as_slice(), [MAGIC, T_DATA, _, _, _, _, ..])
            && out.get(2..6).is_some_and(|s| s == seq.to_be_bytes());
        if !ok {
            return Vec::new();
        }
        let gap = self.missing.contains_key(&seq);
        let body = out.get(2..).unwrap_or_default().to_vec();
        let records = self.on_data(&out, &body, now);
        self.stats.fec_recovered += 1;
        if !gap {
            // A tail loss: never seen as a gap, so on_data did not count it.
            self.stats.repaired += 1;
        }
        records
    }

    fn on_data(&mut self, datagram: &[u8], body: &[u8], now: Instant) -> Vec<Record> {
        let Some((seq, records)) = body.split_first_chunk::<4>() else { return Vec::new() };
        let seq = u32::from_be_bytes(*seq);
        let Some(records) = decode_records(records) else { return Vec::new() };
        let highest = *self.highest.get_or_insert(seq.wrapping_sub(1));
        if seq_lt(highest, seq) {
            let guard = self.rtt().div_f64(8.0).max(Duration::from_millis(3));
            let gap = seq.wrapping_sub(highest).saturating_sub(1).min(DEDUP_WINDOW);
            for i in 1..=gap {
                let s = highest.wrapping_add(i);
                self.missing.insert(s, Missing { next_ask: now + guard, asks: 0 });
                self.loss_ewma = 0.99 * self.loss_ewma + 0.01;
            }
            self.highest = Some(seq);
        } else if !self.missing.contains_key(&seq)
            && (self.seen.contains_key(&seq) || seq_lt(seq, highest.wrapping_sub(DEDUP_WINDOW)))
        {
            // A duplicate, or older than the window.
            return Vec::new();
        }
        if let Some(m) = self.missing.remove(&seq)
            && m.asks > 0
        {
            self.stats.repaired += 1;
        }
        self.loss_ewma *= 0.99;
        self.seen.insert(seq, ());
        self.recent.insert(seq, datagram.to_vec());
        while self.recent.len() > RECENT_SEQS {
            self.recent.pop_first();
        }
        let floor = self.highest.unwrap_or(seq).wrapping_sub(DEDUP_WINDOW);
        while let Some((&s, ())) = self.seen.first_key_value() {
            if seq_lt(s, floor) {
                self.seen.remove(&s);
            } else {
                break;
            }
        }
        self.stats.received += 1;
        records
    }

    fn on_nack(&mut self, body: &[u8], now: Instant) {
        let Some((base, rest)) = body.split_first_chunk::<4>() else { return };
        let Some((bitmap, rest)) = rest.split_first_chunk::<8>() else { return };
        let Some((_highest, rest)) = rest.split_first_chunk::<4>() else { return };
        if let Some((loss, _)) = rest.split_first_chunk::<2>() {
            self.stats.peer_loss_permille = u16::from_be_bytes(*loss);
        }
        let base = u32::from_be_bytes(*base);
        let bitmap = u64::from_be_bytes(*bitmap);
        self.expire(now);
        for i in 0..64 {
            if bitmap & (1 << i) == 0 {
                continue;
            }
            let seq = base.wrapping_add(i);
            let Some(sent) = self.sent.get(&seq) else { continue };
            let all_superseded = !sent.untagged
                && sent
                    .tags
                    .iter()
                    .all(|(k, s)| self.latest.get(k).is_some_and(|&l| seq_lt(*s, l)));
            if all_superseded {
                self.stats.superseded += 1;
            } else if !self.resend.contains(&seq) {
                self.resend.push_back(seq);
            }
        }
    }

    fn expire(&mut self, now: Instant) {
        let keep = (self.rtt() * 2).max(Duration::from_millis(50));
        while let Some((&seq, sent)) = self.sent.first_key_value() {
            if now.saturating_duration_since(sent.at) > keep || self.sent_bytes > KEEP_BYTES {
                self.sent_bytes -= sent.datagram.len();
                self.sent.remove(&seq);
            } else {
                break;
            }
        }
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        let mut wake = self.next_ping;
        if let Some(m) = self.missing.values().map(|m| m.next_ask).min() {
            wake = wake.min(m);
        }
        if !self.group.is_empty() {
            wake = wake.min(self.last_data_at + self.tail_delay());
        }
        Some(wake)
    }

    pub fn on_timeout(&mut self, now: Instant) {
        if now >= self.next_ping {
            let mut ping = vec![MAGIC, T_PING];
            self.ping_nonce = self.ping_nonce.wrapping_add(1);
            ping.extend_from_slice(&self.ping_nonce.to_be_bytes());
            ping.extend_from_slice(&self.ms(now).to_be_bytes());
            self.control.push_back(ping);
            self.next_ping = now + PING_EVERY;
        }
        if !self.group.is_empty() && now >= self.last_data_at + self.tail_delay() {
            self.close_group();
        }
        let reask = self.rtt().mul_f64(1.5);
        let mut due: Vec<u32> = Vec::new();
        self.missing.retain(|&seq, m| {
            if now < m.next_ask {
                return true;
            }
            if m.asks >= MAX_ASKS {
                return false;
            }
            m.asks += 1;
            m.next_ask = now + reask;
            due.push(seq);
            true
        });
        due.sort_by_key(|&s| s.wrapping_sub(self.highest.unwrap_or(0)));
        let mut i = 0;
        while let Some(&base) = due.get(i) {
            let mut bitmap = 0_u64;
            while let Some(&s) = due.get(i) {
                let off = s.wrapping_sub(base);
                if off >= 64 {
                    break;
                }
                bitmap |= 1 << off;
                i += 1;
            }
            let mut nack = vec![MAGIC, T_NACK];
            nack.extend_from_slice(&base.to_be_bytes());
            nack.extend_from_slice(&bitmap.to_be_bytes());
            nack.extend_from_slice(&self.highest.unwrap_or(0).to_be_bytes());
            nack.extend_from_slice(&self.loss_permille().to_be_bytes());
            self.control.push_back(nack);
            self.stats.nacks_sent += 1;
        }
    }

    /// The next datagram to send, if any.
    pub fn poll_transmit(&mut self, now: Instant) -> Option<Vec<u8>> {
        if let Some(c) = self.control.pop_front() {
            return Some(c);
        }
        self.expire(now);
        while let Some(seq) = self.resend.pop_front() {
            if let Some(sent) = self.sent.get(&seq) {
                self.stats.resent += 1;
                return Some(sent.datagram.clone());
            }
        }
        if self.queue_bytes.iter().all(|&b| b == 0) {
            return None;
        }
        let seq = self.next_seq;
        let mut out = vec![MAGIC, T_DATA];
        out.extend_from_slice(&seq.to_be_bytes());
        let mut tags = Vec::new();
        let mut untagged = false;
        let mut count = 0_u64;
        for class in ORDER {
            let idx = usize::from(class);
            let (Some(queue), Some(qb)) = (self.queues.get_mut(idx), self.queue_bytes.get_mut(idx))
            else {
                continue;
            };
            while let Some(front) = queue.front() {
                if count > 0 && out.len() + front.wire_len() > MTU {
                    break;
                }
                let Some(r) = queue.pop_front() else { break };
                *qb -= r.wire_len();
                r.encode_into(&mut out);
                match (r.class, r.tag) {
                    (1, Some(tag)) => tags.push(tag),
                    _ => untagged = true,
                }
                count += 1;
            }
            if count > 0 && queue.front().is_some() {
                break;
            }
        }
        self.next_seq = seq.wrapping_add(1);
        self.stats.sent += 1;
        self.stats.coalesced += count.saturating_sub(1);
        self.sent_bytes += out.len();
        self.sent.insert(seq, Sent { at: now, datagram: out.clone(), tags, untagged });
        self.last_data_at = now;
        let k = self.parity_k();
        if k == 0 {
            self.group.clear();
        } else {
            self.group.push((seq, out.clone()));
            if self.group.len() >= k {
                self.close_group();
            }
        }
        Some(out)
    }

    pub fn stats(&self) -> LegStats {
        LegStats {
            rtt_ms: self.srtt.map(|r| (r * 10.0).round() / 10.0),
            loss_permille: self.loss_permille(),
            queued_bytes: self.queue_bytes.iter().sum(),
            ..self.stats.clone()
        }
    }
}

/// Serial-number order (RFC 1982) on u32 sequence numbers.
pub fn seq_lt(a: u32, b: u32) -> bool {
    a != b && b.wrapping_sub(a) < 1 << 31
}

#[cfg(test)]
#[path = "leg_tests.rs"]
mod tests;
