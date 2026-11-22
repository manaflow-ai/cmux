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
    /// A frame with no damage marks the screen still.
    pub fn before(&mut self, changed: u64, budget: usize) -> i32 {
        if changed == 0 {
            self.still = true;
            self.floor = 0;
            return 0;
        }
        let k = self.sizing_k();
        self.still = false;
        self.floor = floor_for(k, changed, budget);
        self.floor
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
mod tests {
    use super::*;

    #[test]
    fn a_keyframe_floor_follows_the_last_keyframes_size() {
        let max = keyframe_max_bytes(1920 * 1080);
        assert_eq!(max, 972_000);
        // The sweep's 1.44 MB noise keyframe at QP 30: up by ceil(6 * log2(1.48)) = 4.
        assert_eq!(next_keyframe_floor(30, 1_435_625, max, 30), 34);
        // Within the bound: hold; well under it: back down, never under the minimum.
        assert_eq!(next_keyframe_floor(34, 600_000, max, 30), 34);
        assert_eq!(next_keyframe_floor(34, 100_000, max, 30), 30);
        assert_eq!(next_keyframe_floor(48, 100_000_000, max, 30), MAX_QP);
    }

    const PX: u64 = 512 * 256;
    /// One frame interval's share of 2 Mbps at 30 fps.
    const BUDGET: usize = 8_333;
    const TEXT_K: f64 = 2.0;
    const NOISE_K: f64 = 11.0;

    /// Sends one changed frame of content `k` (bytes per changed pixel at QP 0) through the
    /// guard as the model sizes it, and returns its bytes.
    fn send(guard: &mut FrameGuard, changed: u64, budget: usize, k: f64) -> usize {
        let floor = guard.before(changed, budget);
        let qp = if floor > 0 { floor } else { UNBOUND_QP };
        let bytes = (changed as f64 * k * 2f64.powf(-f64::from(qp) / 6.0)).round() as usize;
        guard.after(changed, bytes.max(1));
        bytes
    }

    /// A screen still for a while: frames with no damage.
    fn still(guard: &mut FrameGuard) {
        for _ in 0..30 {
            assert_eq!(guard.before(0, BUDGET), 0);
            guard.after(0, 20);
        }
    }

    #[test]
    fn the_sessions_first_changed_frame_starts_from_the_noise_figure() {
        let mut guard = FrameGuard::default();
        // 131k px of unknown content against 8.3 KB: 11 B/px at QP 0 asks for QP 47.
        assert_eq!(guard.before(PX, BUDGET), 47);
        // Full-screen noise at that floor fits the budget.
        let mut guard = FrameGuard::default();
        assert!(send(&mut guard, PX, BUDGET, NOISE_K) <= BUDGET);
        // A tiny change needs no floor.
        let mut guard = FrameGuard::default();
        assert_eq!(guard.before(16 * 16, BUDGET), 0);
        assert_eq!(guard.before(0, BUDGET), 0);
    }

    #[test]
    fn text_frames_learn_a_text_k_and_noise_frames_a_noise_k() {
        for k in [TEXT_K, NOISE_K] {
            let mut guard = FrameGuard::default();
            for _ in 0..3 {
                send(&mut guard, PX, BUDGET, k);
            }
            assert!((guard.k() - k).abs() < 0.05 * k, "{k}: k {}", guard.k());
            assert!((guard.peak() - k).abs() < 0.05 * k, "{k}: peak {}", guard.peak());
        }
    }

    #[test]
    fn the_high_side_decays_per_changed_frame() {
        let mut guard = FrameGuard::default();
        for _ in 0..3 {
            send(&mut guard, PX, BUDGET, NOISE_K);
        }
        // One text frame: the running k follows it at once, the high side keeps 0.7 of noise.
        send(&mut guard, PX, BUDGET, TEXT_K);
        assert!(guard.k() < 4.0, "{}", guard.k());
        assert!((guard.peak() - NOISE_K * PEAK_DECAY).abs() < 0.2, "{}", guard.peak());
        // Within five text frames the high side is text's again.
        for _ in 0..4 {
            send(&mut guard, PX, BUDGET, TEXT_K);
        }
        assert!((guard.peak() - TEXT_K).abs() < 0.1, "{}", guard.peak());
        // A noise frame raises it at once.
        send(&mut guard, PX, BUDGET, NOISE_K);
        assert!(guard.peak() >= NOISE_K * 0.95, "{}", guard.peak());
    }

    #[test]
    fn a_still_screen_teaches_nothing() {
        let mut guard = FrameGuard::default();
        for _ in 0..3 {
            send(&mut guard, PX, BUDGET, NOISE_K);
        }
        let (k, peak) = (guard.k(), guard.peak());
        still(&mut guard);
        assert_eq!((guard.k(), guard.peak()), (k, peak));
    }

    #[test]
    fn after_a_still_screen_a_change_is_sized_from_what_the_session_sent() {
        let mut floors = Vec::new();
        for k in [0.15, TEXT_K, NOISE_K] {
            let mut guard = FrameGuard::default();
            // The session's first transition (its first changed frame is the exemption).
            still(&mut guard);
            for _ in 0..3 {
                send(&mut guard, PX, BUDGET, k);
            }
            // The second: frame 1 under 2 budgets, frames 2-3 under 1.5.
            still(&mut guard);
            floors.push(guard.clone().before(PX, BUDGET));
            let sizes: Vec<usize> = (0..3).map(|_| send(&mut guard, PX, BUDGET, k)).collect();
            assert!(sizes[0] <= BUDGET * 2, "{k}: {sizes:?}");
            assert!(sizes[1..].iter().all(|&s| s <= BUDGET * 3 / 2), "{k}: {sizes:?}");
        }
        // Text stays sharp: its floor after a still screen is far under noise's.
        assert!(floors[1] + 10 <= floors[2], "{floors:?}");
        assert!(floors[0] < floors[1], "{floors:?}");
    }

    #[test]
    fn noise_in_motion_raises_the_next_floor_and_text_drops_it_within_two_frames() {
        let mut guard = FrameGuard::default();
        for _ in 0..3 {
            send(&mut guard, PX, BUDGET, TEXT_K);
        }
        let text = guard.before(PX, BUDGET);
        // A noise frame at text's floor comes out about 5x over: the next floor rises.
        send(&mut guard, PX, BUDGET, NOISE_K);
        let second = guard.before(PX, BUDGET);
        assert!(second >= text + 10, "{text} -> {second}");
        assert!(second <= MAX_QP);
        // Then text again: the running k falls in one or two frames, not 2 QP at a time.
        send(&mut guard, PX, BUDGET, TEXT_K);
        let third = guard.before(PX, BUDGET);
        send(&mut guard, PX, BUDGET, TEXT_K);
        let fourth = guard.before(PX, BUDGET);
        assert!(third < second - 5, "{second} -> {third}");
        assert!(fourth <= third && fourth <= text + 2, "{text}: {third} -> {fourth}");
    }

    #[test]
    fn a_generous_budget_sets_at_most_a_near_lossless_floor() {
        let mut guard = FrameGuard::default();
        // 1080p at 150 Mbps and 120 fps: a 156 KB budget. Text measured at about 0.28 B/px at
        // QP 0 gets at most a near-lossless floor.
        guard.after(1920 * 1080, 36_000);
        assert_eq!(guard.floor(), 0);
        assert!(guard.k() < 0.3, "{}", guard.k());
        assert!(guard.before(1920 * 1080, 156_250) <= 16);
    }

    #[test]
    fn standards_scroll_budgets_get_a_floor_and_a_small_change_none() {
        const P1080: u64 = 1920 * 1080;
        // Standard's one-frame budgets at 1080p60 (the bench's 400-2000 kbps): 833 to 4166 B.
        // Scrolled text over the whole screen needs a floor at either end of that range.
        let mut guard = FrameGuard::default();
        guard.after(P1080, 36_000);
        let low = guard.before(P1080, 833);
        let high = guard.before(P1080, 4_166);
        assert!(high >= MIN_FLOOR && high < low && low <= MAX_QP, "{low} {high}");
        // The predicted frame at that floor fits the budget.
        let predicted = |qp: i32| P1080 as f64 * guard.k() * 2f64.powf(-f64::from(qp) / 6.0);
        assert!(predicted(high) <= 4_166.0, "{}", predicted(high));
        // A small change (a cursor line) at the same rate needs none.
        assert_eq!(guard.before(64 * 16, 4_166), 0);
    }

    #[test]
    fn the_floor_never_passes_51() {
        let mut guard = FrameGuard::default();
        guard.after(PX, 10_000_000);
        assert_eq!(guard.before(PX, 1), MAX_QP);
    }
}
