//! A per-frame size guard any encoder can run: it picks each frame's QP floor so the frame fits
//! its byte budget. Hardware rate control treats a per-frame limit as a target over time: on a
//! fleet Mac, a noise change after a still screen came out at 11 to 31 frame budgets for three
//! frames running, on both VideoToolbox encoders. Raising a QP floor (unlike a QP ceiling, which
//! made the low-latency encoder drop frames) only ever makes a frame smaller.
//!
//! The model: a frame's size is about `changed pixels * k * 2^(-qp / 6)` (+6 QP halves it),
//! where `k` is the content's bytes per changed pixel at QP 0. Before each frame the guard sets
//! the floor that predicts [`FILL`] of the budget for that frame's damage. It learns `k` from
//! the frames it has encoded this session, two ways:
//!
//! - In motion, a running `k` that follows the newest frames, so a floor falls as fast as it
//!   rose once frames get cheap (text sharpens within a frame or two, not 4 QP a frame).
//! - For the first changed frame after a still screen, the high side: the most `k` of the
//!   last few changed frames, decayed per changed frame ([`PEAK_DECAY`]). A session of text
//!   learns a text `k` and stays sharp; a session of noise learns a noise `k` and fits.
//!
//! Only the session's very first changed frame has nothing learned and starts from
//! [`FIRST_K`], the noise case.

/// H.264 and HEVC both end their QP scale at 51.
pub const MAX_QP: i32 = 51;
/// Below this floor the guard sets none (0): the encoder's own choice is sharper.
pub const MIN_FLOOR: i32 = 12;
/// A floor at or under this stays when the next frame wants a lower one (or none): it is near
/// lossless, and changing VideoToolbox's MinAllowedFrameQP costs the next encode about 3 ms
/// (fleet M6, 4K, the same with or without an idle gap). A screen-share click flapped the floor
/// between 0 and about 13 and put a quarter of the presses on the slow side.
pub const HOLD_FLOOR_MAX: i32 = MIN_FLOOR + 6;
/// The share of the budget a frame is aimed at, leaving room for the model's error.
pub const FILL: f64 = 0.8;
/// `k` for the session's first changed frame, before anything is learned: full-screen noise
/// (about 11 B per changed pixel at QP 0 on a fleet Mac), so that frame fits whatever it is.
pub const FIRST_K: f64 = 11.0;
/// How much of the high-side `k` one changed frame keeps: a noise frame's `k` stops sizing the
/// frame after a still screen within about five text frames (0.7^5 = 0.17).
pub const PEAK_DECAY: f64 = 0.7;
/// The QP a frame is taken to have been coded at when no floor bound it (the hardware
/// encoders' usual pick on screen content at a generous rate).
const UNBOUND_QP: i32 = 24;
/// How much of the running `k` the newest frame sets (the rest is the running value).
const LEARN: f64 = 0.8;

#[derive(Debug, Clone)]
pub struct FrameGuard {
    /// Bytes per changed pixel at QP 0, following the newest frames (sizes frames in motion).
    k: f64,
    /// The high side of `k`: the most of the last few changed frames, decayed per changed
    /// frame (sizes the first changed frame after a still screen).
    peak: f64,
    /// The floor set for the frame being encoded (0: none).
    floor: i32,
    /// The session has sent a changed frame (`k` and `peak` are learned).
    learned: bool,
    /// The screen was still before the next changed frame (none came yet, a frame with no
    /// damage, or [`Self::still`]).
    still: bool,
}

impl Default for FrameGuard {
    fn default() -> Self {
        Self { k: FIRST_K, peak: FIRST_K, floor: 0, learned: false, still: true }
    }
}

impl FrameGuard {
    /// The QP floor for the next frame: `changed` pixels of damage, `budget` bytes. 0 is none.
    /// A frame with no damage marks the screen still. A floor rises at once; one at or under
    /// [`HOLD_FLOOR_MAX`] holds rather than falling (a floor only makes a frame smaller).
    pub fn before(&mut self, changed: u64, budget: usize) -> i32 {
        if changed == 0 {
            self.still = true;
            self.floor = self.held(0);
            return self.floor;
        }
        let k = self.sizing_k();
        self.still = false;
        self.floor = self.held(floor_for(k, changed, budget));
        self.floor
    }

    /// `wanted`, or the current floor when that is lower and near lossless.
    fn held(&self, wanted: i32) -> i32 {
        if wanted < self.floor && self.floor <= HOLD_FLOOR_MAX { self.floor } else { wanted }
    }

    /// The screen went still (the encoder saw a gap in changed frames): the next changed frame
    /// is sized from the high side of what the session has sent.
    pub fn still(&mut self) {
        self.still = true;
    }

    /// Learns from the frame just sent: `bytes` for `changed` pixels of damage, coded with the
    /// floor [`Self::before`] set. A frame with no damage, or none sent, teaches nothing.
    pub fn after(&mut self, changed: u64, bytes: usize) {
        if changed == 0 || bytes == 0 {
            return;
        }
        let qp = if self.floor > 0 { self.floor } else { UNBOUND_QP };
        let observed = bytes as f64 / changed as f64 * 2f64.powf(f64::from(qp) / 6.0);
        if self.learned {
            self.k = LEARN * observed + (1.0 - LEARN) * self.k;
            self.peak = observed.max(self.peak * PEAK_DECAY);
        } else {
            self.k = observed;
            self.peak = observed;
        }
        self.learned = true;
    }

    /// The `k` the next changed frame is sized from: [`FIRST_K`] before anything is learned,
    /// the high side after a still screen, else the running value.
    fn sizing_k(&self) -> f64 {
        if !self.learned {
            FIRST_K
        } else if self.still {
            self.peak.max(self.k)
        } else {
            self.k
        }
    }

    /// The floor set for the frame being encoded (0: none).
    pub fn floor(&self) -> i32 {
        self.floor
    }

    /// Bytes per changed pixel at QP 0, following the newest frames.
    pub fn k(&self) -> f64 {
        self.k
    }

    /// The high side of `k` the first changed frame after a still screen is sized from.
    pub fn peak(&self) -> f64 {
        self.peak
    }
}

/// The lowest QP at which `changed` pixels of content `k` fit [`FILL`] of `budget`, 0 when that
/// is under [`MIN_FLOOR`].
fn floor_for(k: f64, changed: u64, budget: usize) -> i32 {
    if changed == 0 {
        return 0;
    }
    let target = (budget.max(1) as f64) * FILL;
    let at_zero = changed as f64 * k;
    if at_zero <= target {
        return 0;
    }
    let qp = (6.0 * (at_zero / target).log2()).ceil() as i32;
    if qp < MIN_FLOOR { 0 } else { qp.min(MAX_QP) }
}

/// The most bytes a keyframe of `pixels` should take: 15/32 of a byte per pixel, 972 KB at
/// 1080p (under the 1 MB bound) and 3.9 MB at 4K.
pub fn keyframe_max_bytes(pixels: usize) -> usize {
    pixels.saturating_mul(15) / 32
}

/// The QP floor for the next keyframe after one of `bytes` coded at `floor`, against `max`
/// bytes. A keyframe codes the whole picture with nothing to predict from, so the P-frame
/// model above does not size it; the last keyframe does: over `max`, the floor rises by
/// `6 * log2(bytes / max)`; under a quarter of it, it falls by 6, never under `min_floor`.
/// The first keyframe of a session has nothing to go on and keeps `min_floor`.
pub fn next_keyframe_floor(floor: i32, bytes: usize, max: usize, min_floor: i32) -> i32 {
    let max = max.max(1);
    if bytes > max {
        let raise = (6.0 * (bytes as f64 / max as f64).log2()).ceil() as i32;
        (floor + raise).min(MAX_QP)
    } else if bytes < max / 4 {
        (floor - 6).max(min_floor)
    } else {
        floor
    }
}

#[cfg(test)]
#[path = "frame_guard_tests.rs"]
mod tests;
