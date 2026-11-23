//! Measured, held wire-rate policy. Only a standing queue, or loss over what FEC covers
//! lasting over a second, reduces the wire rate;
//! parity and recovery policy are owned by their respective transport lanes.

use crate::profile::ULTRA_MAX_KBPS;

/// Limits for the explicitly selected ultra profile, in wire bits per second.
#[derive(Debug, Clone, Copy)]
pub struct UltraConfig {
    /// The strict pacer's total wire ceiling for an explicitly selected session.
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
    base_delay_us: Option<i64>,
    last_delay_us: Option<i64>,
    last_send_us: Option<u64>,
    jitter_us: f64,
    queue_since_us: Option<u64>,
    pub standing_queue: bool,
    pub queue_clear: bool,
    /// When the current run of loss samples over [`LOSS_CUT_FRACTION`] began, and when
    /// the newest of them came.
    loss_since_us: Option<u64>,
    last_high_loss_us: Option<u64>,
    /// Loss over what FEC covers has lasted [`SUSTAINED_LOSS_US`]: a cut signal.
    pub sustained_loss: bool,
}

/// Loss above what FEC covers (D10 amendment 2026-11-17: about 5%) ...
const LOSS_CUT_FRACTION: f64 = 0.05;
/// ... lasting more than a second is a cut signal in ultra too.
const SUSTAINED_LOSS_US: u64 = 1_000_000;
/// Loss samples come about every 500 ms (the engine's loss meter); feedback between
/// them carries none (0.0). A run of high samples ends when none came for this long.
const LOSS_SAMPLE_GAP_US: u64 = 750_000;

impl UltraState {
    pub fn held_wire_bps(&self, path_ceiling: u64) -> Option<u64> {
        self.capacity_bps.map(|capacity| {
            // Probe capacity is already the delivered goodput sample. Hold the
            // smaller of that sample and the profile/path ceilings.
            capacity.min(self.config.max_wire_bps).min(path_ceiling).max(1)
        })
    }

    /// One feedback's loss (a loss sample, or 0.0 when the feedback carries none). Loss
    /// at or under [`LOSS_CUT_FRACTION`] never cuts: FEC covers it. Over it in samples
    /// spanning [`SUSTAINED_LOSS_US`], it is a cut signal until a sample at or under it
    /// comes, or none over it for [`LOSS_SAMPLE_GAP_US`].
    pub fn observe_loss(&mut self, loss: f64, now_us: u64) {
        let run_ended =
            self.last_high_loss_us.is_none_or(|t| now_us.saturating_sub(t) > LOSS_SAMPLE_GAP_US);
        if loss > LOSS_CUT_FRACTION {
            if run_ended {
                self.loss_since_us = None;
            }
            let since = *self.loss_since_us.get_or_insert(now_us);
            self.last_high_loss_us = Some(now_us);
            self.sustained_loss = now_us.saturating_sub(since) >= SUSTAINED_LOSS_US;
        } else if loss > 0.0 || run_ended {
            self.loss_since_us = None;
            self.last_high_loss_us = None;
            self.sustained_loss = false;
        }
    }

    /// A cut signal holds: a standing queue, or loss over what FEC covers for over a
    /// second. While one holds the rate is cut once per response window and never
    /// restored.
    pub fn cutting(&self) -> bool {
        self.standing_queue || self.sustained_loss
    }

    pub fn reset_path(&mut self) {
        *self = Self { config: self.config, ..Self::default() };
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
