//! The host's encoding for a quality preset (ScreenQuality in ScreenStream.swift): the frame rate
//! both displays agree on and the sender parameters the host sets on libwebrtc's screen sender
//! (degradation preference, bitrate bounds, frame rate cap, scale-down). WebRTC's congestion
//! control still sets the rate from the network; these are its bounds.

use serde::Serialize;

use crate::demand::Quality;

/// The rate a stream runs at unless both displays can show more, and the least Auto and Smooth
/// Motion ask for.
pub const BASELINE_FRAME_RATE: i64 = 60;
/// The most a stream asks for (ProMotion).
pub const MAXIMUM_FRAME_RATE: i64 = 120;
/// Auto and Smooth Motion's bitrate ceiling at 60 fps for a picture of unknown size: 200 kbit a
/// frame.
pub const ADAPTIVE_BITRATE_AT_BASELINE: i64 = 12_000_000;
/// Auto and Smooth Motion's bitrate ceiling for a known picture: 0.18 bits per encoded pixel per
/// frame, from Petal (<https://github.com/kiruna-labs/petal>, Apache-2.0,
/// `apps/desktop/src-tauri/src/transport/publisher.rs`), which raised it from 0.13 after small
/// text read "readable, not crisp" at QP 26: the ceiling is the lever on QP. Clamped to
/// [`ADAPTIVE_BITRATE_FLOOR`]..=[`adaptive_bitrate_ceiling`].
pub const ADAPTIVE_BITS_PER_PIXEL_FRAME: f64 = 0.18;
/// The least ceiling a known picture gets (Petal's 4 Mbps).
pub const ADAPTIVE_BITRATE_FLOOR: i64 = 4_000_000;
/// The most pixels a second Auto and Smooth Motion ask the hardware H.264 encoder for above
/// 60 fps (2160×1396 at 120). VideoToolbox's H.264 encoder is bound by pixels a second, not by
/// its level or settings: an M1 Max sustains about 400 Mpixel/s (3456×2234 at 55 fps, 2160×1396
/// at 120 with 28 ms latency), an M4 Pro about 500. One value for every Mac (not measured per
/// chip): ProMotion Macs are M1 Pro or later.
pub const MAXIMUM_ENCODED_PIXEL_RATE: i64 = 360_000_000;

/// libwebrtc's `RTCDegradationPreference`, by its Swift case name.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Degradation {
    /// Auto: lower the frame rate under load, keep the resolution (text stays sharp).
    MaintainResolution,
    /// Smooth Motion: lower the resolution under load, keep the frame rate.
    MaintainFramerate,
    /// The fixed presets: neither.
    Disabled,
}

/// The screen sender's parameters for one quality, display size and frame rate.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Encoding {
    pub degradation: Degradation,
    pub max_bitrate: i64,
    pub min_bitrate: Option<i64>,
    pub max_framerate: i64,
    /// The factor the picture is scaled down by before encoding (1: full size).
    pub scale_down: f64,
}

/// The most a known picture asks for: Petal's 16 Mbps, and never less than 200 kbit a frame
/// (24 Mbps at 120 fps), so a high-rate stream keeps its per-frame budget.
pub fn adaptive_bitrate_ceiling(frame_rate: i64) -> i64 {
    16_000_000.max(ADAPTIVE_BITRATE_AT_BASELINE / BASELINE_FRAME_RATE * frame_rate)
}

/// Auto and Smooth Motion's bitrate ceiling for a `width`×`height` picture as encoded (after
/// [`Encoding::scale_down`]) at `frame_rate`. A picture of unknown size keeps 200 kbit a frame.
pub fn adaptive_bitrate(width: f64, height: f64, frame_rate: i64) -> i64 {
    if width <= 0.0 || height <= 0.0 {
        return ADAPTIVE_BITRATE_AT_BASELINE / BASELINE_FRAME_RATE * frame_rate;
    }
    let wanted =
        (ADAPTIVE_BITS_PER_PIXEL_FRAME * width * height * frame_rate as f64).round() as i64;
    wanted.max(ADAPTIVE_BITRATE_FLOOR).min(adaptive_bitrate_ceiling(frame_rate))
}

/// The frames per second to capture and encode at. Auto and Smooth Motion follow both screens:
/// the lower of the most the host's captured display and the viewer's display show, at most 120
/// and never below 60. A rate nobody reported (an older peer, a source that does not know it, a
/// display that says 0) counts as 60, so the stream stays where it was. The fixed presets keep
/// their own rate.
pub fn frame_rate(quality: Quality, host_maximum: Option<i64>, viewer_maximum: Option<i64>) -> i64 {
    match quality {
        Quality::Low | Quality::Medium | Quality::High => {
            encoding(quality, 0, 0, BASELINE_FRAME_RATE).max_framerate
        }
        Quality::Auto | Quality::Smooth => {
            let known = |rate: Option<i64>| rate.filter(|r| *r > 0).unwrap_or(BASELINE_FRAME_RATE);
            known(host_maximum)
                .min(known(viewer_maximum))
                .clamp(BASELINE_FRAME_RATE, MAXIMUM_FRAME_RATE)
        }
    }
}

/// The sender's encoding for a display `source_width`×`source_height` pixels (0: unknown) at
/// `frame_rate` (from [`frame_rate`]). Auto and Smooth Motion's bitrate ceiling follows the
/// encoded pixels and the frame rate ([`adaptive_bitrate`]): a full Retina display gets 16 Mbps
/// at 60 fps and 24 at 120, a small picture less (1280×800 at 60: about 11 Mbps). At a fixed
/// ceiling a faster stream would give every frame fewer bits and text would blur in motion. It is
/// a ceiling, not a target: a still screen sends next to nothing. Above 60 fps they also scale
/// the picture down just enough to stay within [`MAXIMUM_ENCODED_PIXEL_RATE`]: a 16" MacBook
/// Pro's 3456×2234 goes out at about 2154×1392 at 120 fps (60 fps keeps the full size).
pub fn encoding(
    quality: Quality,
    source_width: i64,
    source_height: i64,
    frame_rate: i64,
) -> Encoding {
    let scale_to = |height: i64| {
        if source_height > height { source_height as f64 / height as f64 } else { 1.0 }
    };
    let fps = frame_rate.clamp(BASELINE_FRAME_RATE, MAXIMUM_FRAME_RATE);
    let pixel_rate = source_width as f64 * source_height as f64 * fps as f64;
    let fit_encoder = if fps > BASELINE_FRAME_RATE && pixel_rate > MAXIMUM_ENCODED_PIXEL_RATE as f64
    {
        (pixel_rate / MAXIMUM_ENCODED_PIXEL_RATE as f64).sqrt()
    } else {
        1.0
    };
    let adaptive = adaptive_bitrate(
        source_width as f64 / fit_encoder,
        source_height as f64 / fit_encoder,
        fps,
    );
    let fixed = |max_bitrate: i64, max_framerate: i64, scale_down: f64| Encoding {
        degradation: Degradation::Disabled,
        max_bitrate,
        min_bitrate: Some(max_bitrate),
        max_framerate,
        scale_down,
    };
    match quality {
        Quality::Auto | Quality::Smooth => Encoding {
            degradation: if quality == Quality::Auto {
                Degradation::MaintainResolution
            } else {
                Degradation::MaintainFramerate
            },
            max_bitrate: adaptive,
            min_bitrate: None,
            max_framerate: fps,
            scale_down: fit_encoder,
        },
        Quality::Low => fixed(1_500_000, 30, scale_to(720)),
        Quality::Medium => fixed(4_000_000, 30, scale_to(1080)),
        Quality::High => fixed(10_000_000, 60, 1.0),
    }
}

#[cfg(test)]
#[path = "quality_tests.rs"]
mod tests;
