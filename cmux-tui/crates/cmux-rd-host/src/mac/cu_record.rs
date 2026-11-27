//! The encoder of cmux Computer Use's `record` tool on macOS: the engine's
//! [`FrameEncoder`] over the VideoToolbox H.264 encoder screen sharing uses
//! (`cmux_encode::videotoolbox`). The engine captures each frame under its
//! policy (the frames of `screenshot`), hands them here as RGBA, and writes
//! the access units into an MP4 itself; nothing here touches the screen.

use cmux_computer_use::desktop::RawFrame;
use cmux_computer_use::record::FrameEncoder;
use cmux_encode::videotoolbox::VideoToolbox;
use cmux_encode::{bgrx_rect_to_i420, convert_threads, H264Encoder, I420};
use std::time::Duration;

/// Bits per pixel per frame the recording asks for: text on a screen at 10
/// frames a second stays readable, and a minute of a 1920x1200 display is
/// about 26 MB at most (still frames cost far less).
const BITS_PER_PIXEL: f64 = 0.15;
const MIN_KBPS: u32 = 1_000;
const MAX_KBPS: u32 = 20_000;

/// The bitrate for a `width`x`height` recording at `fps`.
pub(crate) fn kbps_for(width: u32, height: u32, fps: u32) -> u32 {
    let bits = f64::from(width) * f64::from(height) * f64::from(fps.max(1)) * BITS_PER_PIXEL;
    ((bits / 1000.0) as u32).clamp(MIN_KBPS, MAX_KBPS)
}

pub(crate) struct VideoToolboxFrames {
    encoder: VideoToolbox,
    width: u32,
    height: u32,
    picture: I420,
    /// The frame with red and blue swapped (the converter reads BGRX).
    bgrx: Vec<u8>,
}

impl VideoToolboxFrames {
    /// `width` and `height` even (the engine's frames are).
    pub(crate) fn new(width: u32, height: u32, fps: u32) -> Result<Self, String> {
        if width == 0 || height == 0 || !width.is_multiple_of(2) || !height.is_multiple_of(2) {
            return Err(format!("a {width}x{height} recording: both sides must be even"));
        }
        // High profile: what every player and browser decodes.
        let encoder =
            VideoToolbox::new(width, height, fps.max(1), kbps_for(width, height, fps), false)
                .map_err(|e| format!("the H.264 encoder: {e}"))?;
        Ok(Self {
            encoder,
            width,
            height,
            picture: I420::new(width as usize, height as usize),
            bgrx: Vec::new(),
        })
    }
}

impl FrameEncoder for VideoToolboxFrames {
    fn encode(
        &mut self,
        frame: &RawFrame,
        force_key: bool,
        at: Duration,
    ) -> Result<Vec<u8>, String> {
        let (w, h) = (self.width as usize, self.height as usize);
        if (frame.width, frame.height) != (self.width, self.height) || frame.rgba.len() != w * h * 4
        {
            return Err(format!(
                "a {}x{} frame for a {}x{} recording",
                frame.width, frame.height, self.width, self.height
            ));
        }
        self.bgrx.clear();
        self.bgrx.extend_from_slice(&frame.rgba);
        for pixel in self.bgrx.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        bgrx_rect_to_i420(&self.bgrx, &mut self.picture, 0, 0, w, h, convert_threads());
        let mut out = Vec::new();
        let pts = i64::try_from(at.as_micros()).unwrap_or(i64::MAX);
        self.encoder
            .encode(&self.picture, force_key, pts, &mut out)
            .map_err(|e| format!("the H.264 encoder: {e}"))?;
        Ok(out)
    }

    fn name(&self) -> String {
        self.encoder.name()
    }
}

#[cfg(all(test, feature = "bench"))]
#[path = "cu_record_tests.rs"]
mod tests;
