//! The resolution ladder (screen-share design D5): when the rate is too low for the
//! picture, the picture gets smaller, not blurrier.
//!
//! The encoded picture is the stream's size scaled by one rung of [`RUNGS`]. A rung is
//! picked so the target gives at least [`MIN_BITS_PER_PIXEL`] per pixel per frame at the
//! frame-rate cap; when even the smallest rung cannot, the frame rate comes down instead,
//! so the floor holds at every rate. Stepping down is immediate. Stepping up waits until
//! the larger rung would clear the floor by [`UP_MARGIN`] for [`UP_HOLD_US`] without a
//! break, so a target that wobbles around a rung's edge does not resize the stream (each
//! resize costs a keyframe).
//!
//! Above the floor a QP ceiling keeps text readable. The ceiling is only asked for at a
//! rung that clears the floor, where the encoder can meet it; a frame the encoder drops
//! anyway says the picture is still too large for the rate, so the ladder steps down one
//! rung (and at the smallest rung lifts the ceiling) instead of cutting the rate or asking
//! for a keyframe. A hard per-frame size limit is not part of this: with a QP ceiling it
//! made the encoder drop most motion frames (design D3, correction of 2026-11-16).

/// Bits per pixel per frame below which a moving screen visibly smears.
pub const MIN_BITS_PER_PIXEL: f64 = 0.05;

/// The rungs as a share of the stream's size, in eighths: 1, 3/4, 1/2, 3/8, 1/4.
pub const RUNGS: [u32; 5] = [8, 6, 4, 3, 2];

/// How much a larger rung must clear the floor by before the ladder steps up to it.
pub const UP_MARGIN: f64 = 1.25;

/// How long a larger rung must stay clear before the ladder steps up.
pub const UP_HOLD_US: u64 = 2_000_000;

/// The least frame rate the ladder keeps when even the smallest rung is under the floor.
pub const MIN_FPS: u32 = 5;

/// The QP ceiling the ladder asks for unless the session names one.
pub const DEFAULT_MAX_QP: u8 = 40;

/// The smallest encoded side the ladder makes, in pixels.
const MIN_SIDE: u32 = 64;

/// What the ladder starts from.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LadderConfig {
    /// The QP ceiling at a rung that clears the floor (`None`: no ceiling).
    pub max_qp: Option<u8>,
    /// The floor in bits per pixel per frame.
    pub min_bits_per_pixel: f64,
}

impl Default for LadderConfig {
    fn default() -> Self {
        Self { max_qp: Some(DEFAULT_MAX_QP), min_bits_per_pixel: MIN_BITS_PER_PIXEL }
    }
}

/// The picture the source encodes for one frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Picture {
    /// The encoded size (even), at most the stream's size.
    pub width: u32,
    pub height: u32,
    /// The rung, in eighths of the stream's size (8 = full size).
    pub eighths: u32,
    /// The frame-rate cap for this picture.
    pub fps: u32,
    /// The encoder's QP ceiling for this picture.
    pub max_qp: Option<u8>,
}

/// The resolution ladder of one display stream.
#[derive(Debug, Clone)]
pub struct ResolutionLadder {
    cfg: LadderConfig,
    width: u32,
    height: u32,
    max_fps: u32,
    /// Index into [`RUNGS`].
    rung: usize,
    fps: u32,
    /// Since when the next larger rung has cleared the floor by [`UP_MARGIN`].
    clear_since_us: Option<u64>,
    /// No step up before this time (set by an encoder drop).
    hold_until_us: u64,
    /// The encoder dropped a frame at the smallest rung: no ceiling until a step up.
    ceiling_lifted: bool,
}

impl ResolutionLadder {
    /// A ladder for a `width` x `height` stream capped at `max_fps`, starting at full size.
    pub fn new(cfg: LadderConfig, width: u32, height: u32, max_fps: u32) -> Self {
        let max_fps = max_fps.max(1);
        Self {
            cfg,
            width,
            height,
            max_fps,
            rung: 0,
            fps: max_fps,
            clear_since_us: None,
            hold_until_us: 0,
            ceiling_lifted: false,
        }
    }

    /// The picture to encode now.
    pub fn picture(&self) -> Picture {
        let (width, height) = self.size_at(self.rung);
        Picture {
            width,
            height,
            eighths: rung_eighths(self.rung),
            fps: self.fps,
            max_qp: if self.ceiling_lifted { None } else { self.cfg.max_qp },
        }
    }

    /// Bits per pixel per frame that `target_bps` gives at the current picture.
    pub fn bits_per_pixel(&self, target_bps: u64) -> f64 {
        self.bpp_at(self.rung, self.fps, target_bps)
    }

    /// Follows the target. Returns the new picture when it changed.
    pub fn update(&mut self, target_bps: u64, now_us: u64) -> Option<Picture> {
        let before = self.picture();
        let floor = self.cfg.min_bits_per_pixel;
        // The largest rung that clears the floor at the cap, never above the current one.
        let fits = (0..RUNGS.len()).find(|&r| self.bpp_at(r, self.max_fps, target_bps) >= floor);
        match fits {
            Some(r) if r > self.rung => {
                self.rung = r;
                self.clear_since_us = None;
            }
            None => {
                self.rung = RUNGS.len() - 1;
                self.clear_since_us = None;
            }
            Some(_) => self.maybe_step_up(target_bps, now_us),
        }
        self.fps = self.fps_at(self.rung, target_bps);
        let after = self.picture();
        (after != before).then_some(after)
    }

    /// The encoder dropped a frame of the current picture. Returns the new picture when it
    /// changed: one rung smaller, or at the smallest rung, the same size with no ceiling.
    pub fn encoder_dropped(&mut self, target_bps: u64, now_us: u64) -> Option<Picture> {
        let before = self.picture();
        if self.rung + 1 < RUNGS.len() {
            self.rung += 1;
        } else {
            self.ceiling_lifted = true;
        }
        self.clear_since_us = None;
        self.hold_until_us = now_us.saturating_add(UP_HOLD_US);
        self.fps = self.fps_at(self.rung, target_bps);
        let after = self.picture();
        (after != before).then_some(after)
    }

    fn maybe_step_up(&mut self, target_bps: u64, now_us: u64) {
        let Some(up) = self.rung.checked_sub(1) else {
            self.clear_since_us = None;
            return;
        };
        let clear = self.bpp_at(up, self.max_fps, target_bps)
            >= self.cfg.min_bits_per_pixel * UP_MARGIN
            && now_us >= self.hold_until_us;
        if !clear {
            self.clear_since_us = None;
            return;
        }
        let since = *self.clear_since_us.get_or_insert(now_us);
        if now_us.saturating_sub(since) >= UP_HOLD_US {
            self.rung = up;
            self.ceiling_lifted = false;
            // The next step up waits for its own hold.
            self.clear_since_us = None;
        }
    }

    /// The frame rate at `rung`: the cap, or less when even the cap is under the floor.
    fn fps_at(&self, rung: usize, target_bps: u64) -> u32 {
        let (w, h) = self.size_at(rung);
        let per_frame = self.cfg.min_bits_per_pixel * f64::from(w) * f64::from(h);
        if per_frame <= 0.0 {
            return self.max_fps;
        }
        let fps = (target_bps as f64 / per_frame).floor();
        if fps >= f64::from(self.max_fps) {
            self.max_fps
        } else {
            (fps as u32).clamp(MIN_FPS.min(self.max_fps), self.max_fps)
        }
    }

    fn bpp_at(&self, rung: usize, fps: u32, target_bps: u64) -> f64 {
        let (w, h) = self.size_at(rung);
        let pixels = f64::from(w) * f64::from(h) * f64::from(fps.max(1));
        if pixels <= 0.0 { 0.0 } else { target_bps as f64 / pixels }
    }

    fn size_at(&self, rung: usize) -> (u32, u32) {
        let eighths = rung_eighths(rung);
        (scaled(self.width, eighths), scaled(self.height, eighths))
    }
}

/// The eighths of `rung`, clamped to the last rung.
fn rung_eighths(rung: usize) -> u32 {
    RUNGS.get(rung).or(RUNGS.last()).copied().unwrap_or(8)
}

/// `side` scaled to `eighths` / 8, even, at least [`MIN_SIDE`] (or `side` if smaller).
fn scaled(side: u32, eighths: u32) -> u32 {
    if eighths >= 8 {
        return side;
    }
    let s = (u64::from(side) * u64::from(eighths) / 8) as u32 & !1;
    s.max(MIN_SIDE.min(side))
}

#[cfg(test)]
#[path = "resolution_tests.rs"]
mod tests;
