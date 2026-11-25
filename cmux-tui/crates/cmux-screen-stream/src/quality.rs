//! The viewer's choice of stream quality and the sender's encoding for it. `auto` leaves the
//! trade-offs to WebRTC (sharp text first); the fixed presets hold a resolution, frame rate and
//! bitrate even when the network cannot carry them, which shows as lag and stalls, not blur.

use serde::{Deserialize, Serialize};

/// The stream quality a viewer picks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[repr(u8)]
pub enum Quality {
    Auto = 0,
    Smooth = 1,
    Low = 2,
    Medium = 3,
    High = 4,
}

/// What the encoder gives up first when the network cannot carry the stream (WebRTC's
/// `RTCDegradationPreference`; the app maps it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[repr(u8)]
pub enum Degradation {
    MaintainResolution = 0,
    MaintainFramerate = 1,
    Disabled = 2,
}

/// The sender's encoding.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub degradation: Degradation,
    pub max_bitrate: i64,
    pub min_bitrate: Option<i64>,
    pub max_framerate: i64,
    pub scale_down: f64,
}

/// The rate a stream runs at unless both displays can show more, and the least Auto and Smooth
/// Motion ask for.
pub const BASELINE_FRAME_RATE: i64 = 60;
/// The most a stream asks for (ProMotion).
pub const MAXIMUM_FRAME_RATE: i64 = 120;
/// Auto and Smooth Motion's bitrate ceiling at 60 fps for a picture of unknown size: 200 kbit a
/// frame.
pub const ADAPTIVE_BITRATE_AT_BASELINE: i64 = 12_000_000;
/// Auto and Smooth Motion's ceiling for a known picture: 0.18 bits per encoded pixel per frame
/// (Petal, Apache-2.0, raised from 0.13 after small text read "readable, not crisp" at QP 26).
pub const ADAPTIVE_BITS_PER_PIXEL_FRAME: f64 = 0.18;
/// The least ceiling a known picture gets (Petal's 4 Mbps).
pub const ADAPTIVE_BITRATE_FLOOR: i64 = 4_000_000;
/// The most pixels a second Auto and Smooth Motion ask the hardware H.264 encoder for above 60
/// fps (2160x1396 at 120): VideoToolbox is bound by pixels a second.
pub const MAXIMUM_ENCODED_PIXEL_RATE: i64 = 360_000_000;

pub const ALL: [Quality; 5] =
    [Quality::Auto, Quality::Smooth, Quality::Low, Quality::Medium, Quality::High];

/// The most a known picture asks for: 16 Mbps, and never less than 200 kbit a frame.
pub fn adaptive_bitrate_ceiling(frame_rate: i64) -> i64 {
    16_000_000.max(ADAPTIVE_BITRATE_AT_BASELINE / BASELINE_FRAME_RATE * frame_rate)
}

/// Auto and Smooth Motion's ceiling for a `width`x`height` picture as encoded at `frame_rate`; a
/// picture of unknown size keeps 200 kbit a frame.
pub fn adaptive_bitrate(width: f64, height: f64, frame_rate: i64) -> i64 {
    if !(width > 0.0 && height > 0.0) {
        return ADAPTIVE_BITRATE_AT_BASELINE / BASELINE_FRAME_RATE * frame_rate;
    }
    let wanted =
        (ADAPTIVE_BITS_PER_PIXEL_FRAME * width * height * frame_rate as f64).round() as i64;
    wanted.max(ADAPTIVE_BITRATE_FLOOR).min(adaptive_bitrate_ceiling(frame_rate))
}

impl Quality {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Smooth => "smooth",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        ALL.into_iter().find(|q| q.as_str() == s)
    }

    pub fn from_raw(raw: u8) -> Option<Self> {
        ALL.get(usize::from(raw)).copied()
    }

    /// The English title (the app localizes its own).
    pub fn title(self) -> &'static str {
        match self {
            Self::Auto => "Auto",
            Self::Smooth => "Smooth Motion",
            Self::Low => "Fixed Low (720p)",
            Self::Medium => "Fixed Medium (1080p)",
            Self::High => "Fixed High (Full)",
        }
    }

    /// Whether this preset follows the network and the displays (not a fixed preset).
    pub fn is_adaptive(self) -> bool {
        matches!(self, Self::Auto | Self::Smooth)
    }

    /// The frames per second to capture and encode at. Auto and Smooth Motion follow both
    /// screens: the lower of the host's and the viewer's display maximum, within 60...120. A rate
    /// nobody reported (`None`, or 0 and below) counts as 60. The fixed presets keep their own.
    pub fn frame_rate(self, host_maximum: Option<i64>, viewer_maximum: Option<i64>) -> i64 {
        if !self.is_adaptive() {
            return self.settings(0, 0, BASELINE_FRAME_RATE).max_framerate;
        }
        let known = |rate: Option<i64>| rate.filter(|r| *r > 0).unwrap_or(BASELINE_FRAME_RATE);
        known(host_maximum)
            .min(known(viewer_maximum))
            .clamp(BASELINE_FRAME_RATE, MAXIMUM_FRAME_RATE)
    }

    /// The sender's encoding for a display `source_width`x`source_height` pixels (0: unknown) at
    /// `frame_rate`. Above 60 fps Auto and Smooth Motion scale the picture down just enough to
    /// stay within `MAXIMUM_ENCODED_PIXEL_RATE`.
    pub fn settings(self, source_width: i64, source_height: i64, frame_rate: i64) -> Settings {
        let scale = |height: i64| {
            if source_height > height { source_height as f64 / height as f64 } else { 1.0 }
        };
        let fps = frame_rate.clamp(BASELINE_FRAME_RATE, MAXIMUM_FRAME_RATE);
        let pixel_rate = source_width as f64 * source_height as f64 * fps as f64;
        let fit = if fps > BASELINE_FRAME_RATE && pixel_rate > MAXIMUM_ENCODED_PIXEL_RATE as f64 {
            (pixel_rate / MAXIMUM_ENCODED_PIXEL_RATE as f64).sqrt()
        } else {
            1.0
        };
        let adaptive = adaptive_bitrate(source_width as f64 / fit, source_height as f64 / fit, fps);
        let fixed = |bitrate: i64, max_framerate: i64, scale_down: f64| Settings {
            degradation: Degradation::Disabled,
            max_bitrate: bitrate,
            min_bitrate: Some(bitrate),
            max_framerate,
            scale_down,
        };
        match self {
            Self::Auto => Settings {
                degradation: Degradation::MaintainResolution,
                max_bitrate: adaptive,
                min_bitrate: None,
                max_framerate: fps,
                scale_down: fit,
            },
            Self::Smooth => Settings {
                degradation: Degradation::MaintainFramerate,
                max_bitrate: adaptive,
                min_bitrate: None,
                max_framerate: fps,
                scale_down: fit,
            },
            Self::Low => fixed(1_500_000, 30, scale(720)),
            Self::Medium => fixed(4_000_000, 30, scale(1080)),
            Self::High => fixed(10_000_000, 60, 1.0),
        }
    }

    /// The capture's long edge cap: the viewer's demand, for a preset that follows it on a
    /// backend that scales; `None` (full size) otherwise.
    pub fn capture_cap(self, demand: Option<i64>, backend_scales: bool) -> Option<i64> {
        if backend_scales && self.is_adaptive() { demand } else { None }
    }
}

/// A rectangle in points (a display's frame, top left or bottom left origin, as the caller has).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// A point as a fraction of `display`; `None` when either is missing, the display is empty, or
/// the point is outside it (the right and bottom edges are outside, as `CGRect.contains`).
pub fn fraction(point: Option<(f64, f64)>, display: Option<Rect>) -> Option<(f64, f64)> {
    let (x, y) = point?;
    let d = display?;
    if !(d.w > 0.0 && d.h > 0.0) {
        return None;
    }
    let inside = x >= d.x && x < d.x + d.w && y >= d.y && y < d.y + d.h;
    inside.then(|| ((x - d.x) / d.w, (y - d.y) / d.h))
}

/// A normalized coordinate on a display axis starting at `origin`, `length` long: a fraction
/// clamped to 0...1, truncated to a whole pixel; a missing or non-finite fraction goes to the
/// origin. A value no `Int` holds (non-finite, too large) is 0, never a trap.
pub fn pixel(fraction: Option<f64>, origin: f64, length: f64) -> i64 {
    let value = match fraction.filter(|f| f.is_finite()) {
        None => origin.floor(),
        Some(f) => (origin + f.clamp(0.0, 1.0) * length).trunc(),
    };
    exact_int(value).unwrap_or(0)
}

/// `Int(exactly:)` of a whole value: `None` when it is not finite or out of range.
fn exact_int(value: f64) -> Option<i64> {
    // -2^63 is exact; 2^63 is the first value above i64::MAX.
    (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0)
        .contains(&value)
        .then_some(value as i64)
}
