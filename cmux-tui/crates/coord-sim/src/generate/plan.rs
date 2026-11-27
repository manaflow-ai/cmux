//! One coordinator's step stream: when each event lands and what it is, drawn from the shape.
//!
//! Time: a chat is a run of units, each a burst (events within 50 ms of each other, its length from
//! `burst_len_50ms`) or a single event, with a gap from `gap_ms` above 50 ms between units and a gap
//! from `gap_ms` at or below 50 ms inside a burst. One burst of the coordinator's peak (drawn from
//! `per_session.peak_events_1s`, or `--peak`) lands inside one second at a random point, and no other
//! burst is longer than it, so the chat's busiest second is its drawn peak.
//!
//! What: each event's kind is drawn by count from `kind_bytes` (the kinds of the coordinator's harness
//! family only), its size from that kind's histogram. A few kinds are the structural ops of the script
//! format: `mux:user_message` is a user turn (with an attachment before it at the shape's rate),
//! `in:subagent_spawned` a subagent, `in:compaction` a compaction, and with more than one coordinator
//! `mux:queued` is a message another coordinator sent (`SendTo` in the sender's script).

use crate::rng::Rng;
use crate::shape::{Hist, Shape};
use std::collections::VecDeque;

/// Kinds the generator never draws: a permission still pending in a static log would show as waiting on
/// every open (0.007% of the shape's events).
const NEVER: &[&str] =
    &["mux:permission_request", "mux:permission_group", "mux:permission_reissued"];

pub const USER_TURN: &str = "mux:user_message";
pub const SUBAGENT: &str = "in:subagent_spawned";
pub const COMPACTION: &str = "in:compaction";
pub const RECEIPT: &str = "mux:queued";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    Claude,
    Codex,
}

impl Family {
    pub fn name(self) -> &'static str {
        match self {
            Family::Claude => "claude",
            Family::Codex => "codex",
        }
    }

    pub fn parse(s: &str) -> Option<Family> {
        match s {
            "claude" => Some(Family::Claude),
            "codex" => Some(Family::Codex),
            _ => None,
        }
    }

    /// Whether the shape key `dir:kind` belongs in this family's chats.
    pub fn keeps(self, key: &str) -> bool {
        let kind = key.split_once(':').map_or(key, |(_, k)| k);
        let claude = kind.starts_with("claude.");
        let codex = kind.starts_with("codex.");
        match self {
            Family::Claude => !codex,
            Family::Codex => !claude,
        }
    }
}

/// The kinds a coordinator draws from, with their weights and size histograms.
#[derive(Debug, Clone)]
pub struct KindTable {
    pub keys: Vec<String>,
    pub weights: Vec<u64>,
    cum: Vec<u64>,
    pub sizes: Vec<RangeHist>,
}

impl KindTable {
    pub fn new(shape: &Shape, family: Family) -> Result<KindTable, String> {
        let mut t =
            KindTable { keys: Vec::new(), weights: Vec::new(), cum: Vec::new(), sizes: Vec::new() };
        let mut total = 0;
        for (key, h) in &shape.acpmux.kind_bytes {
            if h.n == 0 || NEVER.contains(&key.as_str()) || !family.keeps(key) {
                continue;
            }
            total += h.n;
            t.keys.push(key.clone());
            t.weights.push(h.n);
            t.cum.push(total);
            t.sizes.push(size_hist(h));
        }
        if t.keys.is_empty() {
            return Err("shape: no event kinds in acpmux.kind_bytes".into());
        }
        Ok(t)
    }

    pub fn draw(&self, rng: &mut Rng) -> usize {
        let total = self.cum.last().copied().unwrap_or(0);
        let pick = rng.below(total);
        self.cum.partition_point(|&c| c <= pick).min(self.keys.len().saturating_sub(1))
    }

    /// The share of each kind, by key.
    pub fn shares(&self) -> Vec<(String, f64)> {
        let total = self.cum.last().copied().unwrap_or(0).max(1) as f64;
        self.keys.iter().zip(&self.weights).map(|(k, w)| (k.clone(), *w as f64 / total)).collect()
    }

    pub fn index(&self, key: &str) -> Option<usize> {
        self.keys.iter().position(|k| k == key)
    }
}

/// A histogram sampled only inside `[lo, hi]`: a bucket by its count times the share of it inside the
/// range, then uniform in that part.
#[derive(Debug, Clone, Default)]
pub struct RangeHist {
    parts: Vec<(u64, u64)>, // (lo, hi inclusive)
    cum: Vec<u64>,          // running weight through each part
}

impl RangeHist {
    pub fn new(h: &Hist, lo: u64, hi: u64) -> RangeHist {
        let hi = if h.max > 0 { hi.min(h.max.max(lo)) } else { hi };
        let mut parts = Vec::new();
        let mut cum = Vec::new();
        let mut total = 0u64;
        for (b, c) in &h.log2 {
            let Ok(b) = b.parse::<u32>() else { continue };
            let (blo, bhi) = if b == 0 {
                (0, 0)
            } else {
                (1u64 << (b - 1).min(63), (1u64 << b.min(63)).saturating_sub(1))
            };
            let (plo, phi) = (blo.max(lo), bhi.min(hi));
            if plo > phi || *c == 0 {
                continue;
            }
            let share = (phi - plo + 1) as f64 / (bhi - blo + 1) as f64;
            let w = ((*c as f64) * share * 1024.0).round() as u64;
            if w > 0 {
                total += w;
                parts.push((plo, phi));
                cum.push(total);
            }
        }
        RangeHist { parts, cum }
    }

    pub fn sample(&self, rng: &mut Rng, fallback: u64) -> u64 {
        let Some(&total) = self.cum.last() else { return fallback };
        let pick = rng.below(total);
        let i = self.cum.partition_point(|&c| c <= pick);
        match self.parts.get(i) {
            Some(&(lo, hi)) => lo + rng.below(hi - lo + 1),
            None => fallback,
        }
    }
}

/// A kind's sizes: its histogram, sampled inside `[0, max]`.
pub fn size_hist(h: &Hist) -> RangeHist {
    RangeHist::new(h, 0, u64::MAX)
}

/// The time model, shared by every coordinator of one run.
#[derive(Debug, Clone)]
pub struct Timing {
    pub gap_in: RangeHist,
    pub gap_out: RangeHist,
    pub burst: RangeHist,
    /// The chance a unit is a burst rather than a single event.
    pub p_burst: f64,
}

pub const BURST_MS: u64 = 50;

impl Timing {
    pub fn new(shape: &Shape) -> Timing {
        let a = &shape.acpmux;
        let burst = RangeHist::new(&a.burst_len_50ms, 2, u64::MAX);
        let events = a.per_session.events.sum.max(a.event_bytes.n);
        let singles = events.saturating_sub(a.burst_len_50ms.sum);
        let bursts = a.burst_len_50ms.n;
        let p_burst =
            if bursts + singles == 0 { 0.0 } else { bursts as f64 / (bursts + singles) as f64 };
        Timing {
            gap_in: RangeHist::new(&a.gap_ms, 0, BURST_MS),
            gap_out: RangeHist::new(&a.gap_ms, BURST_MS + 1, u64::MAX),
            burst,
            p_burst,
        }
    }
}

/// What one step is.
#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    /// An event of the table's kind `kind`.
    Event(usize),
    UserTurn,
    Subagent {
        events: u32,
    },
    Compaction,
    Attachment,
    /// Another coordinator's message arrives (acpmux `mux:queued`); the sender's script has the `SendTo`.
    Receipt {
        from: u32,
    },
    SendTo {
        to: u32,
    },
}

#[derive(Debug, Clone)]
pub struct Step {
    pub at_ms: u64,
    pub item: Item,
    /// The payload's size on the wire: for an acpmux line, the whole line with its newline.
    pub bytes: u64,
}

/// Per-coordinator settings the run decides.
#[derive(Debug, Clone)]
pub struct CoordSpec {
    pub idx: u32,
    pub family: Family,
    pub events: u64,
    pub peak: u64,
    pub scale: f64,
    pub max_line: u64,
    /// Stop once this many payload bytes are drawn (0: no limit).
    pub byte_limit: u64,
    pub coordinators: u32,
    /// The start's milliseconds past a whole second: the probe counts events per wall-clock second.
    pub origin_ms: u64,
}

pub struct Coord {
    pub spec: CoordSpec,
    pub table: KindTable,
    rng: Rng,
    timing: Timing,
    drawn: u64,
    pub bytes_drawn: u64,
    t: u64,
    burst_left: u64,
    peak_start: u64,
    peak_left: u64,
    /// The wall-clock second the last event fell in, and how many fell in it.
    sec: u64,
    in_sec: u64,
    p_attach: f64,
    subagent_mean: u64,
    attach_hist: RangeHist,
    receipt_hist: RangeHist,
    ix_user: Option<usize>,
    ix_subagent: Option<usize>,
    ix_compaction: Option<usize>,
    ix_receipt: Option<usize>,
    out: VecDeque<Step>,
}

fn kind_n(shape: &Shape, key: &str) -> u64 {
    shape.acpmux.kind_bytes.get(key).map_or(0, |h| h.n)
}

impl Coord {
    pub fn new(shape: &Shape, spec: CoordSpec, mut rng: Rng) -> Result<Coord, String> {
        let table = KindTable::new(shape, spec.family)?;
        let timing = Timing::new(shape);
        // A byte limit ends the chat early: the peak goes where the chat will still be.
        let mut reach = spec.events;
        if spec.byte_limit > 0 {
            let n: u64 = table.weights.iter().sum();
            let sum: u64 = shape
                .acpmux
                .kind_bytes
                .iter()
                .filter(|(k, _)| table.index(k).is_some())
                .map(|(_, h)| h.sum)
                .sum();
            let mean = (sum as f64 / n.max(1) as f64 * spec.scale).max(1.0);
            reach = reach.min((spec.byte_limit as f64 / mean * 0.9) as u64).max(1);
        }
        let peak = spec.peak.clamp(1, reach);
        let peak_start = if reach > peak { rng.below(reach - peak) } else { 0 };
        let turns = kind_n(shape, USER_TURN).max(1);
        let p_attach = (shape.attachment_bytes.n as f64 / turns as f64).min(1.0);
        let spawned = kind_n(shape, SUBAGENT).max(1);
        let sub_events: u64 = shape
            .acpmux
            .kind_bytes
            .iter()
            .filter(|(k, _)| {
                k.starts_with("in:subagent_progress") || k.starts_with("in:subagent_state_update")
            })
            .map(|(_, h)| h.n)
            .sum();
        let receipt_hist = shape.acpmux.kind_bytes.get(RECEIPT).map(size_hist).unwrap_or_default();
        Ok(Coord {
            ix_user: table.index(USER_TURN),
            ix_subagent: table.index(SUBAGENT),
            ix_compaction: table.index(COMPACTION),
            ix_receipt: if spec.coordinators > 1 { table.index(RECEIPT) } else { None },
            table,
            rng,
            timing,
            drawn: 0,
            bytes_drawn: 0,
            t: 0,
            burst_left: 0,
            peak_start,
            peak_left: 0,
            sec: 0,
            in_sec: 0,
            p_attach,
            subagent_mean: (sub_events / spawned).max(1),
            attach_hist: size_hist(&shape.attachment_bytes),
            receipt_hist,
            spec: CoordSpec { peak, ..spec },
            out: VecDeque::new(),
        })
    }

    fn exhausted(&self) -> bool {
        // A byte limit is the run's to hold, on the bytes it wrote (`generate`).
        self.drawn >= self.spec.events
    }

    /// The time of the next step, drawing it if none waits. None once the coordinator is done.
    pub fn peek(&mut self) -> Option<u64> {
        if self.out.is_empty() && !self.exhausted() {
            self.draw();
        }
        self.out.front().map(|s| s.at_ms)
    }

    pub fn pop(&mut self) -> Option<Step> {
        self.out.pop_front()
    }

    fn scaled(&self, v: u64) -> u64 {
        ((v as f64 * self.spec.scale).round() as u64).clamp(1, self.spec.max_line.max(1))
    }

    fn next_gap(&mut self) -> u64 {
        if self.drawn == self.peak_start && self.spec.peak > 1 {
            self.peak_left = self.spec.peak - 1;
            self.burst_left = 0;
            return if self.drawn == 0 {
                0
            } else {
                self.timing.gap_out.sample(&mut self.rng, 1000)
            };
        }
        if self.drawn == 0 {
            return 0;
        }
        if self.peak_left > 0 {
            self.peak_left -= 1;
            // The peak's events fit inside one second: a 1 ms step at most 900 times.
            let q = (900.0 / self.spec.peak as f64).min(0.5);
            return u64::from(self.rng.chance(q));
        }
        if self.burst_left > 0 {
            self.burst_left -= 1;
            return self.timing.gap_in.sample(&mut self.rng, 0);
        }
        if self.rng.chance(self.timing.p_burst) {
            let len = self.timing.burst.sample(&mut self.rng, 2).clamp(2, self.spec.peak.max(2));
            self.burst_left = len - 1;
        }
        self.timing.gap_out.sample(&mut self.rng, 1000)
    }

    fn draw(&mut self) {
        let peak_begins = self.drawn == self.peak_start && self.spec.peak > 1;
        let gap = self.next_gap();
        let origin = self.spec.origin_ms % 1000;
        let mut t = self.t.saturating_add(gap);
        if peak_begins && self.drawn > 0 {
            // The peak starts a second of its own, so all of it is counted in one.
            t = ((origin + t) / 1000 + 1) * 1000 - origin;
        }
        // No second holds more than the peak: an event past it waits for the next second.
        let mut sec = (origin + t) / 1000;
        if self.drawn > 0 && sec == self.sec && self.in_sec >= self.spec.peak {
            sec += 1;
            t = sec * 1000 - origin;
        }
        if self.drawn == 0 || sec != self.sec {
            self.sec = sec;
            self.in_sec = 0;
        }
        self.in_sec += 1;
        self.t = t;
        self.drawn += 1;
        let at_ms = self.t;
        let k = self.table.draw(&mut self.rng);
        let raw = match self.table.sizes.get(k) {
            Some(h) => h.sample(&mut self.rng, 1),
            None => 1,
        };
        let bytes = self.scaled(raw);
        self.bytes_drawn += bytes;
        let item = if Some(k) == self.ix_user {
            if self.rng.chance(self.p_attach) {
                let raw = self.attach_hist.sample(&mut self.rng, 1);
                let ab = ((raw as f64 * self.spec.scale).round() as u64).max(1);
                self.out.push_back(Step { at_ms, item: Item::Attachment, bytes: ab });
            }
            Item::UserTurn
        } else if Some(k) == self.ix_subagent {
            let mean = self.subagent_mean;
            Item::Subagent {
                events: (1 + self.rng.below(2 * mean)).min(u64::from(u32::MAX)) as u32,
            }
        } else if Some(k) == self.ix_compaction {
            Item::Compaction
        } else if Some(k) == self.ix_receipt {
            let others = u64::from(self.spec.coordinators.saturating_sub(1)).max(1);
            let mut from = self.rng.below(others) as u32;
            if from >= self.spec.idx {
                from += 1;
            }
            Item::Receipt { from }
        } else {
            Item::Event(k)
        };
        self.out.push_back(Step { at_ms, item, bytes });
    }

    /// The size of the message a `SendTo` from here carries.
    pub fn send_size(&mut self) -> u64 {
        let raw = self.receipt_hist.sample(&mut self.rng, 512);
        self.scaled(raw)
    }
}

#[cfg(test)]
#[path = "plan_tests.rs"]
mod tests;
