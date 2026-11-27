//! Recording as you go: every access unit the viewer releases, copied into a
//! fragmented MP4 without re-encoding. The file starts at the first
//! keyframe that carries its parameter sets (the caller asks the host for
//! one when it starts); each later frame is one `moof` + `mdat`, timed by
//! the host's capture clock. A frame is written once the next one arrives
//! (its duration is the gap), so a crash loses at most the newest frame and
//! the file stays playable. H.264 only. Parameter sets stay in the samples
//! too, so a decoder follows a mid-recording resolution change.

use std::io::{self, Write};

use crate::h264::{NAL_AUD, NAL_IDR, NAL_PPS, NAL_SPS, nal_type, nal_units, parse_sps};
use crate::mp4;

/// The duration of the last frame when nothing follows it (30 fps).
const LAST_FRAME_US: u32 = 33_333;

/// A frame waiting for the next one, which fixes its duration.
#[derive(Debug)]
struct Held {
    t_us: u64,
    sample: Vec<u8>,
    sync: bool,
}

/// Writes one recording to `out`.
#[derive(Debug)]
pub struct Recorder<W: Write> {
    out: W,
    started: bool,
    held: Option<Held>,
    /// Decode time of the held frame (media time, from 0).
    dts: u64,
    seq: u32,
    last_duration: u32,
    frames: u64,
    error: Option<io::Error>,
}

impl<W: Write> Recorder<W> {
    pub fn new(out: W) -> Self {
        Self {
            out,
            started: false,
            held: None,
            dts: 0,
            seq: 0,
            last_duration: LAST_FRAME_US,
            frames: 0,
            error: None,
        }
    }

    /// True until a keyframe with its SPS and PPS started the file.
    #[cfg(test)]
    pub fn waiting_for_keyframe(&self) -> bool {
        !self.started
    }

    /// Adds one access unit (Annex-B) captured at `t_capture_us`. Frames
    /// before the first usable keyframe are skipped; after a write error
    /// every frame is (the error is reported by [`Recorder::finish`]).
    pub fn push(&mut self, t_capture_us: u64, access_unit: &[u8]) {
        if self.error.is_some() {
            return;
        }
        if let Err(e) = self.try_push(t_capture_us, access_unit) {
            self.error = Some(e);
        }
    }

    fn try_push(&mut self, t_us: u64, au: &[u8]) -> io::Result<()> {
        let nals = nal_units(au);
        let sync = nals.iter().any(|n| nal_type(n) == NAL_IDR);
        if !self.started {
            let sps = nals.iter().find(|n| nal_type(n) == NAL_SPS);
            let pps = nals.iter().find(|n| nal_type(n) == NAL_PPS);
            let (Some(sps), Some(pps)) = (sps, pps) else { return Ok(()) };
            let Some(info) = parse_sps(sps).filter(|_| sync) else { return Ok(()) };
            self.out.write_all(&mp4::init_segment(&info, sps, pps))?;
            self.started = true;
        }
        let mut sample = Vec::with_capacity(au.len() + 4 * nals.len());
        for nal in nals.iter().filter(|n| nal_type(n) != NAL_AUD) {
            sample.extend_from_slice(&u32::try_from(nal.len()).unwrap_or(u32::MAX).to_be_bytes());
            sample.extend_from_slice(nal);
        }
        if let Some(prev) = self.held.take() {
            // A clock that steps back still gives a positive duration.
            let gap = t_us.saturating_sub(prev.t_us).clamp(1, u64::from(u32::MAX));
            self.write(prev, u32::try_from(gap).unwrap_or(u32::MAX))?;
        }
        self.held = Some(Held { t_us, sample, sync });
        Ok(())
    }

    fn write(&mut self, frame: Held, duration: u32) -> io::Result<()> {
        self.seq += 1;
        self.out.write_all(&mp4::fragment(
            self.seq,
            self.dts,
            duration,
            &frame.sample,
            frame.sync,
        ))?;
        self.out.flush()?;
        self.dts += u64::from(duration);
        self.last_duration = duration;
        self.frames += 1;
        Ok(())
    }

    /// Writes the held frame and returns the frame count and the output,
    /// or the first write error.
    pub fn finish(mut self) -> io::Result<(u64, W)> {
        if let Some(e) = self.error.take() {
            return Err(e);
        }
        if let Some(last) = self.held.take() {
            let duration = self.last_duration;
            self.write(last, duration)?;
        }
        Ok((self.frames, self.out))
    }
}
