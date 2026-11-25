//! The engine's thresholds. Time is a [`Duration`] since an origin the host
//! picks (a monotonic clock), so the engine holds no clock and tests state
//! exact instants instead of sleeping.

use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PredictionConfiguration {
    /// Below this measured echo latency, predicting is not worth the risk: a
    /// nearby shell already paints faster than a person can notice.
    pub engage_above_echo_latency: Duration,
    /// A speculative glyph the remote never echoes is withdrawn after this.
    pub speculative_lifetime: Duration,
    /// How long a confirmed glyph keeps drawing while waiting for the frame
    /// that contains the real character, if the host never reports one.
    pub confirmation_hold: Duration,
    /// Withdrawals of glyphs the user actually saw, within
    /// `misprediction_window`, that suspend prediction.
    pub mispredictions_before_suspending: usize,
    pub misprediction_window: Duration,
    pub suspension: Duration,
    /// Predicting further than this ahead of the remote stops being a latency
    /// hint and starts being a second, wrong terminal.
    pub maximum_speculative_glyphs: usize,
}

impl Default for PredictionConfiguration {
    fn default() -> Self {
        Self {
            engage_above_echo_latency: Duration::from_millis(25),
            speculative_lifetime: Duration::from_millis(1500),
            confirmation_hold: Duration::from_millis(120),
            mispredictions_before_suspending: 4,
            misprediction_window: Duration::from_secs(10),
            suspension: Duration::from_secs(30),
            maximum_speculative_glyphs: 40,
        }
    }
}
