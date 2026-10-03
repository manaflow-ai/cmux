//! Delay-based congestion control for real-time video. The sender records
//! when each transport sequence number left; feedback reports when it
//! arrived. A rising one-way delay trend means a queue is building, so the
//! target bitrate drops before packets are lost; a flat trend lets the target
//! grow. Loss caps the target further. The target drives the encoder per frame;
//! nothing is ever queued to "catch up".

use std::collections::BTreeMap;

use cmux_rd_proto::Arrival;

/// The network path class reported by the link (transport.md section 4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathKind {
    DirectLan,
    DirectWan,
    ViaCloudRegion,
    DoRelay,
}

/// Congestion controller limits.
#[derive(Debug, Clone, Copy)]
pub struct CcConfig {
    pub min_bps: u64,
    pub max_bps: u64,
    pub start_bps: u64,
    /// Cap applied on [`PathKind::DoRelay`] (`remoteDesktop.relay.maxBitrateMbps`).
    pub relay_max_bps: u64,
    /// Delay growth over one feedback that counts as overuse, in microseconds.
    pub overuse_threshold_us: f64,
}

impl Default for CcConfig {
    fn default() -> Self {
        Self {
            min_bps: 200_000,
            max_bps: 80_000_000,
            start_bps: 8_000_000,
            relay_max_bps: 4_000_000,
            overuse_threshold_us: 2_000.0,
        }
    }
}

/// The controller's view of the path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Usage {
    Normal,
    Overuse,
    Underuse,
}

/// Delay-gradient bandwidth estimator.
#[derive(Debug)]
pub struct CongestionController {
    config: CcConfig,
    target_bps: u64,
    path: PathKind,
    sent_us: BTreeMap<u16, u64>,
    /// Smoothed one-way delay change per feedback (microseconds).
    trend_us: f64,
    last_delay_us: Option<i64>,
    usage: Usage,
}

impl CongestionController {
    pub fn new(config: CcConfig, path: PathKind) -> Self {
        let mut cc = Self {
            config,
            target_bps: config.start_bps,
            path,
            sent_us: BTreeMap::new(),
            trend_us: 0.0,
            last_delay_us: None,
            usage: Usage::Normal,
        };
        cc.clamp();
        cc
    }

    /// The bitrate the encoder should aim for now.
    pub fn target_bps(&self) -> u64 {
        self.target_bps
    }

    pub fn usage(&self) -> Usage {
        self.usage
    }

    pub fn path(&self) -> PathKind {
        self.path
    }

    /// Records the send time of a datagram.
    pub fn on_sent(&mut self, transport_seq: u16, now_us: u64) {
        self.sent_us.insert(transport_seq, now_us);
        while self.sent_us.len() > 4096 {
            self.sent_us.pop_first();
        }
    }

    /// A path change resets the delay baseline (RTT and capacity change at
    /// once) and applies the relay cap immediately.
    pub fn on_path_changed(&mut self, path: PathKind) {
        self.path = path;
        self.last_delay_us = None;
        self.trend_us = 0.0;
        self.usage = Usage::Normal;
        self.clamp();
    }

    /// Processes one feedback: arrivals and the fraction of shards lost since
    /// the previous feedback (0.0 to 1.0).
    pub fn on_feedback(&mut self, arrivals: &[Arrival], loss: f64) {
        let mut deltas = Vec::new();
        for a in arrivals {
            let Some(sent) = self.sent_us.remove(&a.transport_seq) else { continue };
            // Arrival clock wraps at u32; only differences between samples matter.
            let delay = i64::from(a.arrival_us) - (sent & 0xffff_ffff) as i64;
            if let Some(prev) = self.last_delay_us {
                let mut d = delay - prev;
                if d > i64::from(u32::MAX / 2) {
                    d -= i64::from(u32::MAX) + 1;
                } else if d < -i64::from(u32::MAX / 2) {
                    d += i64::from(u32::MAX) + 1;
                }
                deltas.push(d as f64);
            }
            self.last_delay_us = Some(delay);
        }
        if !deltas.is_empty() {
            let growth: f64 = deltas.iter().sum();
            self.trend_us = 0.7 * self.trend_us + 0.3 * growth;
        }
        self.usage = if self.trend_us > self.config.overuse_threshold_us {
            Usage::Overuse
        } else if self.trend_us < -self.config.overuse_threshold_us {
            Usage::Underuse
        } else {
            Usage::Normal
        };
        let mut target = self.target_bps as f64;
        match self.usage {
            Usage::Overuse => target *= 0.85,
            Usage::Normal => target *= 1.05,
            Usage::Underuse => {}
        }
        if loss > 0.10 {
            target *= 1.0 - 0.5 * loss.min(1.0);
        }
        self.target_bps = target as u64;
        self.clamp();
    }

    fn clamp(&mut self) {
        let max = if self.path == PathKind::DoRelay {
            self.config.max_bps.min(self.config.relay_max_bps)
        } else {
            self.config.max_bps
        };
        self.target_bps = self.target_bps.clamp(self.config.min_bps, max.max(self.config.min_bps));
    }
}
