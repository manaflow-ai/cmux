//! The quality ladder: bitrate first; then, for text keep resolution and lower
//! the frame rate, for motion keep the frame rate and lower the resolution.

use crate::cc::PathKind;

/// What the last second of damage looked like.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContentClass {
    /// Small or scrolling damage.
    Text,
    /// Large damage on most frames.
    Motion,
    Mixed,
}

impl ContentClass {
    /// Classifies by the mean damaged share of the screen (0.0 to 1.0) and the
    /// share of frames with damage over half of the screen.
    pub fn classify(mean_damage: f64, large_frames: f64) -> Self {
        if large_frames > 0.6 {
            Self::Motion
        } else if mean_damage < 0.25 && large_frames < 0.2 {
            Self::Text
        } else {
            Self::Mixed
        }
    }
}

/// Inputs of one ladder decision.
#[derive(Debug, Clone, Copy)]
pub struct LadderInput {
    pub target_bps: u64,
    pub content: ContentClass,
    pub path: PathKind,
    pub display_fps: u32,
    /// Relay frame rate cap (`remoteDesktop.relay.maxFps`).
    pub relay_max_fps: u32,
    /// Median encode time per frame in microseconds (0 = unknown).
    pub encode_us: u64,
    /// Bits per pixel per frame below which quality visibly suffers.
    pub min_bits_per_pixel: f64,
    pub pixels: u64,
}

/// One ladder decision.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rung {
    pub fps: u32,
    /// Share of the client-sized virtual display, 1.0 = full size.
    pub scale: f64,
}

/// Picks frame rate and scale for the given inputs.
pub fn choose(input: LadderInput) -> Rung {
    let mut fps = input.display_fps.max(1);
    if input.path == PathKind::DoRelay {
        fps = fps.min(input.relay_max_fps.max(1));
    }
    if input.encode_us > 0 {
        // Keep encode time under the frame interval.
        let encode_fps = (1_000_000 / input.encode_us.max(1)) as u32;
        fps = fps.min(encode_fps.max(1));
    }
    let bits_needed = |fps: u32, scale: f64| {
        input.min_bits_per_pixel * input.pixels as f64 * scale * scale * f64::from(fps)
    };
    let budget = input.target_bps as f64;
    let mut scale = 1.0;
    match input.content {
        ContentClass::Text | ContentClass::Mixed => {
            for candidate in [fps, 30, 15, 10, 5] {
                let candidate = candidate.min(fps);
                if bits_needed(candidate, 1.0) <= budget || candidate == 5 {
                    fps = candidate;
                    break;
                }
            }
        }
        ContentClass::Motion => {
            for candidate in [1.0, 0.75, 0.5] {
                scale = candidate;
                if bits_needed(fps, candidate) <= budget {
                    break;
                }
            }
            if bits_needed(fps, scale) > budget {
                fps = fps.min(30);
            }
        }
    }
    Rung { fps: fps.max(1), scale }
}

/// The bits per pixel per frame below which a motion frame smears even at the encoder's QP
/// ceiling (design D5, screen-share-under-100ms.md): under it the stream gets smaller, not
/// blurrier.
pub const MIN_MOTION_BITS_PER_PIXEL: f64 = 0.05;
/// The sizes a stream steps through, as a share of each side (0.5 is a quarter of the pixels).
pub const SCALES: [f64; 3] = [1.0, 0.75, 0.5];
/// A frame whose damage covers at least this share of the screen is motion; the floor
/// applies only to such frames (a small change is cheap at any rate).
pub const MOTION_DAMAGE_SHARE: f64 = 0.25;
/// How long the next larger size must clear the floor (with [`UP_MARGIN`]) before the
/// stream steps back up, so one good second does not flap the size.
pub const UP_HOLD_US: u64 = 2_000_000;
/// The next larger size must clear the floor by this factor to count toward the hold.
pub const UP_MARGIN: f64 = 1.25;
/// A gap with no frame this long means motion stopped: the next frame goes back to full
/// size, so a still screen refines at full resolution.
pub const STILL_US: u64 = 500_000;

/// Picks the stream's size frame by frame from the bits each frame gets: steps down at once
/// when a motion frame would fall under [`MIN_MOTION_BITS_PER_PIXEL`], steps up one size
/// after [`UP_HOLD_US`] of room, and returns to full size when motion stops.
#[derive(Debug, Clone)]
pub struct ScaleGovernor {
    /// Index into [`SCALES`].
    index: usize,
    last_frame_us: Option<u64>,
    /// Since when the next larger size has cleared the floor with margin.
    room_since_us: Option<u64>,
}

impl Default for ScaleGovernor {
    fn default() -> Self {
        Self::new()
    }
}

impl ScaleGovernor {
    pub fn new() -> Self {
        Self { index: 0, last_frame_us: None, room_since_us: None }
    }

    /// The current share of each side.
    pub fn scale(&self) -> f64 {
        SCALES.get(self.index).copied().unwrap_or(1.0)
    }

    /// Bits per pixel one frame gets at `scale`.
    pub fn bits_per_pixel(target_bps: u64, fps: u32, full_pixels: u64, scale: f64) -> f64 {
        let pixels = (full_pixels as f64 * scale * scale).max(1.0);
        target_bps as f64 / f64::from(fps.max(1)) / pixels
    }

    /// The size for the frame about to be encoded at `now_us`: `target_bps` and `fps` are
    /// the encoder's, `full_pixels` the full-size stream's, and `damage_share` the share of
    /// the screen this frame changed (0.0 to 1.0).
    pub fn on_frame(
        &mut self,
        now_us: u64,
        target_bps: u64,
        fps: u32,
        full_pixels: u64,
        damage_share: f64,
    ) -> f64 {
        let still = self.last_frame_us.is_none_or(|t| now_us.saturating_sub(t) >= STILL_US);
        self.last_frame_us = Some(now_us);
        let bpp = |scale| Self::bits_per_pixel(target_bps, fps, full_pixels, scale);
        let motion = damage_share >= MOTION_DAMAGE_SHARE;
        if still && !motion {
            self.index = 0;
            self.room_since_us = None;
            return self.scale();
        }
        if motion && bpp(self.scale()) < MIN_MOTION_BITS_PER_PIXEL {
            // Down at once, to the largest size that clears the floor (or the smallest).
            self.index = SCALES
                .iter()
                .enumerate()
                .skip(self.index)
                .find(|&(_, &scale)| bpp(scale) >= MIN_MOTION_BITS_PER_PIXEL)
                .map_or(SCALES.len().saturating_sub(1), |(i, _)| i);
            self.room_since_us = None;
            return self.scale();
        }
        let larger = self.index.checked_sub(1).and_then(|i| Some((i, *SCALES.get(i)?)));
        if let Some((larger_index, larger)) = larger {
            if bpp(larger) >= MIN_MOTION_BITS_PER_PIXEL * UP_MARGIN {
                let since = *self.room_since_us.get_or_insert(now_us);
                if now_us.saturating_sub(since) >= UP_HOLD_US {
                    self.index = larger_index;
                    self.room_since_us = None;
                }
            } else {
                self.room_since_us = None;
            }
        }
        self.scale()
    }
}
