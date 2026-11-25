//! A leg's receive side: the duplicate window, the gaps it NACKs, the loss
//! it measures and the DATA it keeps for parity recovery.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

/// Duplicates are dropped within this many sequence numbers of the highest.
pub(crate) const WINDOW: u64 = 1024;
/// DATA kept for parity recovery, in sequence numbers behind the highest.
pub(crate) const RAW_KEEP: u64 = 128;
/// Parity groups waiting for more DATA.
const MAX_PARITIES: usize = 64;
/// Loss is sampled over this many expected sequence numbers.
const LOSS_SAMPLE: u64 = 100;
/// After a PARITY, the receiver keeps DATA for recovery this long.
const PARITY_INTEREST: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Seen {
    Fresh,
    Duplicate,
    TooOld,
}

pub(crate) struct Missing {
    pub(crate) next_at: Instant,
    pub(crate) asks: u8,
    /// Counted as lost: still missing after the reorder guard, or recovered
    /// by parity.
    pub(crate) counted: bool,
}

pub(crate) struct PendingParity {
    pub(crate) first: u64,
    pub(crate) count: u8,
    pub(crate) len_xor: u16,
    pub(crate) xor: Vec<u8>,
}

pub(crate) struct Rx {
    /// Highest extended sequence number seen.
    pub(crate) highest: Option<u64>,
    bits: [u64; (WINDOW / 64) as usize],
    pub(crate) missing: BTreeMap<u64, Missing>,
    pub(crate) raw: BTreeMap<u64, Vec<u8>>,
    pub(crate) parities: Vec<PendingParity>,
    parity_seen_at: Option<Instant>,
    expected: u64,
    lost: u64,
    pub(crate) loss_permille: u16,
}

impl Rx {
    pub(crate) fn new() -> Self {
        Self {
            highest: None,
            bits: [0; (WINDOW / 64) as usize],
            missing: BTreeMap::new(),
            raw: BTreeMap::new(),
            parities: Vec::new(),
            parity_seen_at: None,
            expected: 0,
            lost: 0,
            loss_permille: 0,
        }
    }

    /// Extends a wire sequence number to 64 bits around the highest seen.
    /// The first one seen lands at `2^32 + seq`, so earlier ones still fit.
    pub(crate) fn extend(&self, seq: u32) -> Option<u64> {
        match self.highest {
            None => Some((1u64 << 32) + u64::from(seq)),
            Some(highest) => {
                let delta = i64::from(seq.wrapping_sub(highest as u32) as i32);
                u64::try_from(i64::try_from(highest).ok()?.checked_add(delta)?).ok()
            }
        }
    }

    fn bit(&self, seq: u64) -> bool {
        let slot = seq % WINDOW;
        self.bits.get((slot / 64) as usize).is_some_and(|word| word & (1 << (slot % 64)) != 0)
    }

    fn set_bit(&mut self, seq: u64, on: bool) {
        let slot = seq % WINDOW;
        if let Some(word) = self.bits.get_mut((slot / 64) as usize) {
            if on {
                *word |= 1 << (slot % 64);
            } else {
                *word &= !(1 << (slot % 64));
            }
        }
    }

    /// Whether `seq` was received (within the window).
    pub(crate) fn received(&self, seq: u64) -> bool {
        match self.highest {
            Some(highest) if seq <= highest => highest - seq < WINDOW && self.bit(seq),
            _ => false,
        }
    }

    /// Records the arrival of `seq`; marks the gap it opens as missing, to
    /// be NACKed after `guard`.
    pub(crate) fn arrive(&mut self, seq: u64, now: Instant, guard: Duration) -> Seen {
        let Some(highest) = self.highest else {
            self.highest = Some(seq);
            self.set_bit(seq, true);
            self.expected += 1;
            return Seen::Fresh;
        };
        if seq > highest {
            let gap = seq - highest;
            let start = highest + 1 + gap.saturating_sub(WINDOW);
            for skipped in start..seq {
                self.set_bit(skipped, false);
                self.missing.insert(
                    skipped,
                    Missing {
                        next_at: now.checked_add(guard).unwrap_or(now),
                        asks: 0,
                        counted: false,
                    },
                );
            }
            self.set_bit(seq, true);
            self.highest = Some(seq);
            self.note_expected(gap);
            let floor = seq.saturating_sub(WINDOW);
            self.missing = self.missing.split_off(&floor);
            self.raw = self.raw.split_off(&seq.saturating_sub(RAW_KEEP));
            let parity_floor = seq.saturating_sub(RAW_KEEP);
            self.parities.retain(|p| p.first + u64::from(p.count) > parity_floor);
            return Seen::Fresh;
        }
        if highest - seq >= WINDOW {
            return Seen::TooOld;
        }
        if self.bit(seq) {
            return Seen::Duplicate;
        }
        self.set_bit(seq, true);
        Seen::Fresh
    }

    pub(crate) fn wants_raw(&self, now: Instant) -> bool {
        // The sender adds parity once this side reports loss, so keep DATA
        // from then on, and for a while after the last PARITY seen.
        self.loss_permille > 0
            || self
                .parity_seen_at
                .is_some_and(|at| now.saturating_duration_since(at) < PARITY_INTEREST)
    }

    pub(crate) fn keep_raw(&mut self, seq: u64, datagram: &[u8]) {
        self.raw.insert(seq, datagram.to_vec());
    }

    pub(crate) fn add_parity(&mut self, parity: PendingParity, now: Instant) {
        self.parity_seen_at = Some(now);
        if self.parities.len() >= MAX_PARITIES {
            self.parities.remove(0);
        }
        self.parities.push(parity);
    }

    fn note_expected(&mut self, count: u64) {
        self.expected += count;
        if self.expected >= LOSS_SAMPLE {
            let sample = (self.lost.min(self.expected) * 1000 / self.expected) as u16;
            self.loss_permille = if self.loss_permille == 0 && self.lost > 0 {
                sample
            } else {
                ((u32::from(self.loss_permille) * 3 + u32::from(sample)) / 4) as u16
            };
            self.expected = 0;
            self.lost = 0;
        }
    }

    pub(crate) fn note_lost(&mut self) {
        self.lost += 1;
    }

    /// Tries every pending parity; returns the recovered DATA datagram of
    /// the first group that is missing exactly one, with its sequence
    /// number. Groups fully received or unrecoverable are dropped.
    pub(crate) fn recover_one(&mut self) -> Option<(u64, Vec<u8>)> {
        let mut index = 0;
        while index < self.parities.len() {
            let Some(parity) = self.parities.get(index) else { break };
            match self.try_parity(parity) {
                ParityState::Waiting => index += 1,
                ParityState::Done => {
                    self.parities.remove(index);
                }
                ParityState::Recovered(seq, datagram) => {
                    self.parities.remove(index);
                    return Some((seq, datagram));
                }
            }
        }
        None
    }

    fn try_parity(&self, parity: &PendingParity) -> ParityState {
        let range = parity.first..parity.first + u64::from(parity.count);
        let mut lost = None;
        for seq in range.clone() {
            if !self.received(seq) {
                if lost.is_some() {
                    return ParityState::Waiting;
                }
                lost = Some(seq);
            }
        }
        let Some(lost) = lost else { return ParityState::Done };
        let mut buf = parity.xor.clone();
        let mut len = usize::from(parity.len_xor);
        for seq in range {
            if seq == lost {
                continue;
            }
            let Some(raw) = self.raw.get(&seq) else { return ParityState::Done };
            if raw.len() > buf.len() {
                return ParityState::Done;
            }
            for (out, byte) in buf.iter_mut().zip(raw) {
                *out ^= byte;
            }
            len ^= raw.len();
        }
        if len == 0 || len > buf.len() {
            return ParityState::Done;
        }
        buf.truncate(len);
        ParityState::Recovered(lost, buf)
    }
}

enum ParityState {
    Waiting,
    Done,
    Recovered(u64, Vec<u8>),
}
