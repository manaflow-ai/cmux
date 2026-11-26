//! Counters of one peer link's paths (`peer_paths.rs`), kept for the daemon's life so the
//! share of links that run direct, on ssh or on the hub relay, and what the relayed ones
//! cost, are measured rather than guessed (`linkStats` in `_acpmux/peers`).
//!
//! - Each cold connect: how long until the winning path's WebSocket opened (first byte), which
//!   path won, and whether a direct path was dialed ahead of it and lost (the link waited on
//!   a direct path before it ran on another one).
//! - The path the live link runs on: how often it moved to another path, and the time spent
//!   on each path and each carrier.
//! - Each path's round trips: the last [`RTT_SAMPLES`] pongs in a ring, read as p50 and p95.
//! - Direct upgrades: while the link runs on ssh or the hub, every probe of a direct path that
//!   was not answering is an attempt; one that fails is a failure, one that answers an upgrade.
//!
//! Memory is constant: one entry per path (at most one per [`Via`]) and a fixed ring each.
//! Times are milliseconds the caller passes in, so tests drive them without clocks.

use crate::peer_paths::{Carrier, Via};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, VecDeque};

/// Round trips kept per path for its percentiles.
pub const RTT_SAMPLES: usize = 64;

/// The last [`RTT_SAMPLES`] round trips, in microseconds, oldest first: a bounded queue whose
/// capacity is reserved once, so a long-lived link never grows it.
#[derive(Debug, Clone)]
struct RttRing {
    samples: VecDeque<u32>,
}

impl Default for RttRing {
    fn default() -> Self {
        Self { samples: VecDeque::with_capacity(RTT_SAMPLES) }
    }
}

impl RttRing {
    fn push(&mut self, rtt_us: u64) {
        if self.samples.len() >= RTT_SAMPLES {
            self.samples.pop_front();
        }
        self.samples.push_back(u32::try_from(rtt_us).unwrap_or(u32::MAX));
    }

    fn len(&self) -> usize {
        self.samples.len()
    }

    /// The `p`th percentile (nearest rank) in milliseconds, once a sample came.
    fn percentile_ms(&self, p: usize) -> Option<f64> {
        let mut sorted: Vec<u32> = self.samples.iter().copied().collect();
        sorted.sort_unstable();
        let rank = p.saturating_mul(sorted.len()).div_ceil(100).max(1);
        sorted.get(rank.saturating_sub(1)).map(|us| f64::from(*us) / 1000.0)
    }
}

/// Connect attempts kept per link for comparing transports (`attempts` in `linkStats`).
pub const ATTEMPT_SAMPLES: usize = 32;

/// One connect attempt on one transport: a cold connect that opened on `via`, or a path that
/// failed to open or ended. Recorded for every attempt so ssh and WireGuard are scored by the
/// same rows (cmuxterm-hq RFD 0060, Weft move 2).
#[derive(Debug, Clone)]
struct Attempt {
    /// When it settled, ms.
    at: u64,
    via: Via,
    opened: bool,
    /// Time from the cold connect's start to the first byte; None for a failure.
    ms: Option<u64>,
}

/// The counters of one peer link.
#[derive(Debug, Clone, Default)]
pub struct LinkStats {
    /// When counting began (the first cold connect started), ms.
    since: u64,
    /// Cold connects that opened a path.
    opens: u64,
    /// The last one's time to its first byte, ms.
    first_byte_ms: Option<u64>,
    /// The path the last cold connect opened on.
    winner: Option<Via>,
    /// Cold connects won by another path after a direct path was dialed ahead of it.
    waited_on_direct: u64,
    /// The path the live link runs on now, and since when.
    serving: Option<(Via, u64)>,
    /// The path the link ran on before (kept across an outage, so a link that comes back on
    /// another path counts as a switch).
    last_serving: Option<Via>,
    switches: u64,
    on_path_ms: BTreeMap<Via, u64>,
    rtt: BTreeMap<Via, RttRing>,
    upgrade_attempts: u64,
    upgrade_failures: u64,
    upgrades: u64,
    /// The last [`ATTEMPT_SAMPLES`] attempts, oldest first (capacity reserved on first use).
    attempts: VecDeque<Attempt>,
}

impl LinkStats {
    pub fn new(since: u64) -> Self {
        Self { since, ..Self::default() }
    }

    /// A cold connect that started at `started` dialed `order` and opened on `winner` at `now`.
    pub fn opened(&mut self, order: &[Via], winner: Via, started: u64, now: u64) {
        if self.opens == 0 && self.since == 0 {
            self.since = started;
        }
        self.opens = self.opens.saturating_add(1);
        self.first_byte_ms = Some(now.saturating_sub(started));
        self.winner = Some(winner);
        self.attempt(Attempt {
            at: now,
            via: winner,
            opened: true,
            ms: Some(now.saturating_sub(started)),
        });
        let mut ahead = order.iter().take_while(|via| **via != winner);
        if winner.carrier() != Carrier::Direct && ahead.any(|via| via.carrier() == Carrier::Direct)
        {
            self.waited_on_direct = self.waited_on_direct.saturating_add(1);
        }
    }

    fn attempt(&mut self, attempt: Attempt) {
        if self.attempts.capacity() == 0 {
            self.attempts.reserve_exact(ATTEMPT_SAMPLES);
        }
        if self.attempts.len() >= ATTEMPT_SAMPLES {
            self.attempts.pop_front();
        }
        self.attempts.push_back(attempt);
    }

    /// A dial of `via` did not open, or its connection ended, at `now`.
    pub fn attempt_failed(&mut self, via: Via, now: u64) {
        self.attempt(Attempt { at: now, via, opened: false, ms: None });
    }

    /// The live link runs on `via` from `now` (None: it ended).
    pub fn serving(&mut self, via: Option<Via>, now: u64) {
        if self.serving.map(|(on, _)| on) == via {
            return;
        }
        if let Some((on, at)) = self.serving.take() {
            let spent = self.on_path_ms.entry(on).or_default();
            *spent = spent.saturating_add(now.saturating_sub(at));
        }
        if let Some(via) = via {
            if self.last_serving.is_some_and(|last| last != via) {
                self.switches = self.switches.saturating_add(1);
            }
            self.last_serving = Some(via);
            self.serving = Some((via, now));
        }
    }

    /// A pong on `via` after `rtt_us`; `was_answering` whether it answered before this.
    pub fn pong(&mut self, via: Via, rtt_us: u64, was_answering: bool) {
        self.rtt.entry(via).or_default().push(rtt_us);
        if self.upgrade_probe(via, was_answering) {
            self.upgrade_attempts = self.upgrade_attempts.saturating_add(1);
            self.upgrades = self.upgrades.saturating_add(1);
        }
    }

    /// `via` failed; `was_answering` whether it answered before this.
    pub fn failed(&mut self, via: Via, was_answering: bool) {
        if self.upgrade_probe(via, was_answering) {
            self.upgrade_attempts = self.upgrade_attempts.saturating_add(1);
            self.upgrade_failures = self.upgrade_failures.saturating_add(1);
        }
    }

    /// Whether an outcome on `via` is a direct upgrade attempt: a direct path that was not
    /// answering, probed while the live link runs on another carrier.
    fn upgrade_probe(&self, via: Via, was_answering: bool) -> bool {
        !was_answering
            && via.carrier() == Carrier::Direct
            && self.serving.is_some_and(|(on, _)| on.carrier() != Carrier::Direct)
    }

    /// `linkStats` in `_acpmux/peers`, with the time on the current path counted up to `now`.
    pub fn view(&self, now: u64) -> Value {
        let mut on_path = self.on_path_ms.clone();
        if let Some((on, at)) = self.serving {
            let spent = on_path.entry(on).or_default();
            *spent = spent.saturating_add(now.saturating_sub(at));
        }
        let mut on_carrier: BTreeMap<&str, u64> = BTreeMap::new();
        for (via, ms) in &on_path {
            let spent = on_carrier.entry(via.carrier().as_str()).or_default();
            *spent = spent.saturating_add(*ms);
        }
        let on_path: Map<String, Value> =
            on_path.iter().map(|(via, ms)| (via.as_str().to_owned(), json!(ms))).collect();
        let rtt: Map<String, Value> = self
            .rtt
            .iter()
            .map(|(via, ring)| {
                let row = json!({
                    "p50Ms": ring.percentile_ms(50),
                    "p95Ms": ring.percentile_ms(95),
                    "samples": ring.len(),
                });
                (via.as_str().to_owned(), row)
            })
            .collect();
        json!({
            "since": self.since,
            "opens": self.opens,
            "firstByteMs": self.first_byte_ms,
            "winner": self.winner.map(Via::as_str),
            "winnerCarrier": self.winner.map(|via| via.carrier().as_str()),
            "waitedOnDirect": self.waited_on_direct,
            "serving": self.serving.map(|(via, _)| via.as_str()),
            "switches": self.switches,
            "onPathMs": on_path,
            "onCarrierMs": on_carrier,
            "rtt": rtt,
            "attempts": self.attempts.iter().map(|a| json!({
                "atMs": a.at,
                "transport": a.via.as_str(),
                "carrier": a.via.carrier().as_str(),
                "outcome": if a.opened { "opened" } else { "failed" },
                "firstByteMs": a.ms,
            })).collect::<Vec<_>>(),
            "directUpgrade": {
                "attempts": self.upgrade_attempts,
                "failures": self.upgrade_failures,
                "upgrades": self.upgrades,
            },
        })
    }

    /// The last cold connect's time to its first byte, ms.
    pub fn first_byte_ms(&self) -> Option<u64> {
        self.first_byte_ms
    }

    /// Each path's round-trip p95, ms (`peer-paths.json`).
    pub fn rtt_p95_ms(&self) -> BTreeMap<String, f64> {
        self.rtt
            .iter()
            .filter_map(|(via, ring)| Some((via.as_str().to_owned(), ring.percentile_ms(95)?)))
            .collect()
    }
}

#[cfg(test)]
#[path = "peer_path_stats_tests.rs"]
mod tests;
