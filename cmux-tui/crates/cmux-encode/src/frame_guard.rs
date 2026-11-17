//! A per-frame size guard any encoder can run: it picks each frame's QP floor so the frame fits
//! its byte budget. Hardware rate control treats a per-frame limit as a target over time: on a
//! fleet Mac, a noise change after a still screen came out at 11 to 31 frame budgets for three
//! frames running, on both VideoToolbox encoders. Raising a QP floor (unlike a QP ceiling, which
//! made the low-latency encoder drop frames) only ever makes a frame smaller.
//!
//! The model: a frame's size is about `changed pixels * k * 2^(-qp / 6)` (+6 QP halves it),
//! where `k` is the content's bytes per changed pixel at QP 0. The guard keeps a running `k`
//! from the frames it has seen, and before each frame sets the floor that predicts
//! [`FILL`] of the budget for that frame's damage. So the first changed frame after a still
//! screen is already sized from what the session last sent, and a floor falls as fast as it
//! rose once frames get cheap (text sharpens within a frame or two, not 4 QP a frame).

/// H.264 and HEVC both end their QP scale at 51.
pub const MAX_QP: i32 = 51;
/// Below this floor the guard sets none (0): the encoder's own choice is sharper.
pub const MIN_FLOOR: i32 = 12;
/// The share of the budget a frame is aimed at, leaving room for the model's error.
pub const FILL: f64 = 0.8;
/// `k` before the session has sent a changed frame: between dense text (about 0.15 on a
/// fleet Mac) and full-screen noise (about 11).
pub const PRIOR_K: f64 = 2.0;
/// The QP a frame is taken to have been coded at when no floor bound it (the hardware
/// encoders' usual pick on screen content at a generous rate).
const UNBOUND_QP: i32 = 24;
/// How much of `k` the newest frame sets (the rest is the running value).
const LEARN: f64 = 0.8;

#[derive(Debug, Clone)]
pub struct FrameGuard {
    /// Bytes per changed pixel at QP 0.
    k: f64,
    /// The floor set for the frame being encoded (0: none).
    floor: i32,
    /// The session has sent a changed frame (`k` is learned, not the prior).
    learned: bool,
}

impl Default for FrameGuard {
    fn default() -> Self {
        Self { k: PRIOR_K, floor: 0, learned: false }
    }
}

impl FrameGuard {
    /// The QP floor for the next frame: `changed` pixels of damage, `budget` bytes. 0 is none.
    pub fn before(&mut self, changed: u64, budget: usize) -> i32 {
        self.floor = floor_for(self.k, changed, budget);
        self.floor
    }

    /// Learns from the frame just sent: `bytes` for `changed` pixels of damage, coded with the
    /// floor [`Self::before`] set.
    pub fn after(&mut self, changed: u64, bytes: usize) {
        if changed == 0 || bytes == 0 {
            return;
        }
        let qp = if self.floor > 0 { self.floor } else { UNBOUND_QP };
        let observed = bytes as f64 / changed as f64 * 2f64.powf(f64::from(qp) / 6.0);
        self.k = if self.learned { LEARN * observed + (1.0 - LEARN) * self.k } else { observed };
        self.learned = true;
    }

    /// The floor set for the frame being encoded (0: none).
    pub fn floor(&self) -> i32 {
        self.floor
    }

    /// Bytes per changed pixel at QP 0, as learned so far.
    pub fn k(&self) -> f64 {
        self.k
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

    #[test]
    fn the_first_changed_frame_is_seeded_from_the_damage_and_the_budget() {
        let mut guard = FrameGuard::default();
        // 131k px of unknown content against 8.3 KB: the prior (2 B/px at QP 0) asks for QP 32.
        assert_eq!(guard.before(PX, 8_333), 32);
        // A tiny change needs no floor.
        assert_eq!(guard.before(64 * 64, 8_333), 0);
        assert_eq!(guard.before(0, 8_333), 0);
    }

    #[test]
    fn a_frame_over_budget_raises_the_next_floor_and_a_cheap_one_drops_it() {
        let mut guard = FrameGuard::default();
        let first = guard.before(PX, 8_333);
        // Noise came out 5x over at that floor: k is learned from it, the next floor rises
        // by about 6 * log2(5 / 0.8).
        guard.after(PX, 41_665);
        let second = guard.before(PX, 8_333);
        assert!(second >= first + 15, "{first} -> {second}");
        assert!(second <= MAX_QP);
        // Then text-like frames: a fraction of the budget at that floor. The floor falls in
        // one or two frames, not 2 QP at a time.
        guard.after(PX, 200);
        let third = guard.before(PX, 8_333);
        guard.after(PX, 200);
        let fourth = guard.before(PX, 8_333);
        assert!(third < second - 10, "{second} -> {third}");
        assert!(fourth <= third);
    }

    #[test]
    fn a_generous_budget_sets_at_most_a_near_lossless_floor() {
        let mut guard = FrameGuard::default();
        // 1080p at 150 Mbps and 120 fps: a 156 KB budget. Text measured at about 0.15 B/px at
        // QP 0 gets at most a near-lossless floor.
        guard.after(1920 * 1080, 36_000);
        assert_eq!(guard.floor(), 0);
        assert!(guard.k() < 0.3, "{}", guard.k());
        assert!(guard.before(1920 * 1080, 156_250) <= 16);
    }

    #[test]
    fn a_still_screen_keeps_what_the_session_last_sent() {
        let mut guard = FrameGuard::default();
        guard.before(PX, 8_333);
        guard.after(PX, 41_665);
        let k = guard.k();
        let next = guard.before(PX, 8_333);
        // A still screen's frames carry no damage: no floor, and nothing learned from them,
        // so the change after it is sized from the content the session last sent.
        for _ in 0..30 {
            assert_eq!(guard.before(0, 8_333), 0);
            guard.after(0, 20);
        }
        assert_eq!(guard.k(), k);
        assert_eq!(guard.before(PX, 8_333), next);
    }

    #[test]
    fn standards_scroll_budgets_get_a_floor_and_rich_rates_none() {
        const P1080: u64 = 1920 * 1080;
        // Standard's one-frame budgets at 1080p60 (the bench's 400-2000 kbps): 833 to 4166 B.
        // Scrolled text (about 0.15 B per changed pixel at QP 0) over the whole screen needs
        // a floor at either end of that range.
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
