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
