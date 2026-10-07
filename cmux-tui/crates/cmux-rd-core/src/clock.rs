//! Placeholder (red commit).

use cmux_rd_proto::{ClockEstimate, ClockPing, ClockPong};

pub const PING_BURST: u32 = 4;
pub const BURST_INTERVAL_US: u64 = 50_000;
pub const PING_INTERVAL_US: u64 = 1_000_000;

#[derive(Debug, Default)]
pub struct ClockEstimator;

impl ClockEstimator {
    pub fn new() -> Self {
        Self
    }
    pub fn ping(&mut self, _now_us: u64) -> Option<ClockPing> {
        None
    }
    pub fn next_ping_us(&self) -> u64 {
        u64::MAX
    }
    pub fn on_pong(&mut self, _pong: &ClockPong, _now_us: u64) -> bool {
        false
    }
    pub fn estimate(&self) -> Option<ClockEstimate> {
        None
    }
}
