//! The fake desktop's encoder: access units with the structure of H.264
//! (parameter sets, a keyframe slice, then plain slices) and a payload that
//! says what the frame held, so the engine's tests and the worker's e2e can
//! record, write and read back a file on any machine. It is not video a
//! player can show; real pictures come from a platform encoder (VideoToolbox
//! on macOS).

use std::time::Duration;

use super::FrameEncoder;
use crate::desktop::RawFrame;

/// What one synthetic frame says about the picture it was made from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stats {
    pub index: u32,
    pub width: u32,
    pub height: u32,
    /// Pixels in the colour a denied window is painted out with
    /// ([`crate::frame::redact`]).
    pub painted: u32,
    /// The top-left pixel.
    pub first: [u8; 3],
}

pub struct SyntheticEncoder {
    width: u32,
    height: u32,
    index: u32,
}

impl SyntheticEncoder {
    pub fn new(width: u32, height: u32) -> Self {
        Self { width, height, index: 0 }
    }
}

/// The colour [`crate::frame::redact`] paints a denied window with.
const PAINT: [u8; 3] = [24, 24, 28];
const START: [u8; 4] = [0, 0, 0, 1];
/// Baseline profile, level 3.1, in the three bytes a file's header copies.
const SPS: [u8; 6] = [0x67, 0x42, 0xc0, 0x1f, 0x95, 0xa8];
const PPS: [u8; 4] = [0x68, 0xce, 0x3c, 0x80];

/// Two bytes per byte, none of them zero, so a payload never looks like a
/// start code.
fn put(out: &mut Vec<u8>, bytes: &[u8]) {
    for b in bytes {
        out.push(0x40 | (b >> 4));
        out.push(0x40 | (b & 0x0f));
    }
}

impl FrameEncoder for SyntheticEncoder {
    fn encode(
        &mut self,
        frame: &RawFrame,
        force_key: bool,
        _at: Duration,
    ) -> Result<Vec<u8>, String> {
        if (frame.width, frame.height) != (self.width, self.height) {
            return Err(format!(
                "a {}x{} frame for a {}x{} encoder",
                frame.width, frame.height, self.width, self.height
            ));
        }
        let painted = frame.rgba.chunks_exact(4).filter(|p| p.starts_with(&PAINT)).count();
        let first = frame.rgba.get(..3).unwrap_or(&[0, 0, 0]);
        let mut unit = Vec::with_capacity(64);
        let key = force_key || self.index == 0;
        if key {
            unit.extend_from_slice(&START);
            unit.extend_from_slice(&SPS);
            unit.extend_from_slice(&START);
            unit.extend_from_slice(&PPS);
        }
        unit.extend_from_slice(&START);
        unit.push(if key { 0x65 } else { 0x41 });
        put(&mut unit, &self.index.to_be_bytes());
        put(&mut unit, &frame.width.to_be_bytes());
        put(&mut unit, &frame.height.to_be_bytes());
        put(&mut unit, &(painted as u32).to_be_bytes());
        put(&mut unit, first);
        self.index += 1;
        Ok(unit)
    }

    fn name(&self) -> String {
        "synthetic".to_string()
    }
}

/// Reads a synthetic frame back from a file's sample (NAL units after
/// four-byte lengths).
pub fn stats(sample: &[u8]) -> Option<Stats> {
    let len = u32::from_be_bytes(sample.get(..4)?.try_into().ok()?) as usize;
    let nal = sample.get(4..4 + len)?;
    let body = nal.get(1..)?;
    let bytes: Vec<u8> = body
        .chunks_exact(2)
        .filter_map(|pair| match *pair {
            [hi, lo] => Some(((hi & 0x0f) << 4) | (lo & 0x0f)),
            _ => None,
        })
        .collect();
    let word = |at: usize| -> Option<u32> {
        Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
    };
    Some(Stats {
        index: word(0)?,
        width: word(4)?,
        height: word(8)?,
        painted: word(12)?,
        first: bytes.get(16..19)?.try_into().ok()?,
    })
}
