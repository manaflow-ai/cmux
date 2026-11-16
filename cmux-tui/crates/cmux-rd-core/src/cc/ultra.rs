//! Measured, held wire-rate policy. Random loss buys parity within the budget;
//! only a standing queue reduces the wire rate.

use crate::profile::ULTRA_MAX_KBPS;

/// Limits for the explicitly selected ultra profile, in wire bits per second.
#[derive(Debug, Clone, Copy)]
pub struct UltraConfig {
    /// Includes media, parity, repairs and probes, rather than just encoder bytes.
    pub max_wire_bps: u64,
    /// A queue must exceed both this floor and twice the observed jitter.
    pub queue_floor_us: u64,
    /// Continuous elevated delay required before a reduction.
    pub standing_queue_us: u64,
}

impl Default for UltraConfig {
    fn default() -> Self {
        Self {
            max_wire_bps: u64::from(ULTRA_MAX_KBPS) * 1_000,
            queue_floor_us: 10_000,
            standing_queue_us: 200_000,
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct UltraState {
    pub config: UltraConfig,
    pub capacity_bps: Option<u64>,
    pub wire_bps: u64,
    pub loss: f64,
    base_delay_us: Option<i64>,
    last_delay_us: Option<i64>,
    last_send_us: Option<u64>,
    jitter_us: f64,
    queue_since_us: Option<u64>,
    pub standing_queue: bool,
    pub queue_clear: bool,
}

impl UltraState {
    pub fn held_wire_bps(&self, path_ceiling: u64) -> Option<u64> {
        self.capacity_bps.map(|capacity| {
            // Integer division first is safe even for a malformed u64::MAX sample.
            let usable = (u128::from(capacity) * 4 / 5) as u64;
            usable.min(self.config.max_wire_bps).min(path_ceiling).max(1)
        })
    }

    pub fn fec_ratio(&self) -> f64 {
        // A full loss report can request two parity bytes per source byte. The
        // packetizer still enforces the maximum total shards in a FEC block.
        (2.0 * self.loss).clamp(0.1, 2.0)
    }

    pub fn media_bps(&self) -> u64 {
        (self.wire_bps as f64 / (1.0 + self.fec_ratio())) as u64
    }

    pub fn reset_path(&mut self) {
        *self = Self { config: self.config, ..Self::default() };
    }

    /// Discard delay evidence from the burst that ends a radio outage while
    /// preserving the measured capacity and held wire rate.
    pub fn resume_after_outage(&mut self) {
        self.base_delay_us = None;
        self.last_delay_us = None;
        self.last_send_us = None;
        self.jitter_us = 0.0;
        self.queue_since_us = None;
        self.standing_queue = false;
        self.queue_clear = false;
    }

    pub fn observe_delay(&mut self, sent_us: u64, arrival_us: i64) {
        if self.last_send_us.is_some_and(|last| sent_us <= last) {
            return; // Repeated/reordered reports cannot extend a queue's duration.
        }
        let delay = arrival_us.saturating_sub(sent_us.min(i64::MAX as u64) as i64);
        let baseline = self.base_delay_us.map_or(delay, |base| base.min(delay));
        self.base_delay_us = Some(baseline);
        let threshold = (self.config.queue_floor_us.max(1) as f64).max(2.0 * self.jitter_us);
        let elevated = delay.saturating_sub(baseline) as f64 > threshold;
        // An idle interval is not evidence of a queue persisting through it.
        if self
            .last_send_us
            .is_some_and(|last| sent_us.saturating_sub(last) > self.config.standing_queue_us.max(1))
        {
            self.queue_since_us = None;
        }
        if elevated {
            let since = *self.queue_since_us.get_or_insert(sent_us);
            self.standing_queue = sent_us.saturating_sub(since) >= self.config.standing_queue_us;
            self.queue_clear = false;
        } else {
            // Do not learn a standing queue as the path's normal jitter.
            if let Some(last) = self.last_delay_us {
                let variation = delay.abs_diff(last) as f64;
                self.jitter_us = 0.9 * self.jitter_us + 0.1 * variation;
            }
            self.queue_since_us = None;
            self.standing_queue = false;
            self.queue_clear = true;
        }
        self.last_delay_us = Some(delay);
        self.last_send_us = Some(sent_us);
    }
}
