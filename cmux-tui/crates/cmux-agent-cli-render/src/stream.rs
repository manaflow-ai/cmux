//! The hybrid stream one viewer gets: numbered frames of [`Delta`]s, paced, and resumable
//! after a drop without resending the screen.
//!
//! The Mac keeps one [`HybridStream`] per viewer stream. Each frame is the delta that turns
//! what the viewer shows into the real screen. The stream keeps the frames it sent lately, so
//! a viewer that drops and comes back naming the last frame it applied gets one delta from that
//! frame to the screen now ([`HybridStream::resume`]), not the whole screen again. A viewer the
//! stream cannot place (a frame it no longer holds, another size) gets a keyframe
//! ([`HybridStream::keyframe`]): the screen as one delta over a blank one.
//!
//! This stage draws nothing from records: the drawn screen under the overlay is blank, so the
//! deltas carry every cell (the "deltas only" rows of `tests/parity.rs`), at the same parity as
//! the PTY. Records-drawn screens need the same renderer on the viewer and are the next stage;
//! [`Delta::seq`] stays 0 until then.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use crate::Grid;
use crate::hybrid::{Delta, Overlay};

/// How many sent frames a stream keeps for a resume.
pub const RESUME_FRAMES: usize = 512;
/// How many bytes of sent frames a stream keeps for a resume.
pub const RESUME_BYTES: usize = 512 * 1024;

/// One frame on the wire: `data` (a [`Delta::encode`]) turns the viewer's screen at `base`
/// into the screen at `frame`; `base` `None` means over a blank screen (a keyframe).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub frame: u64,
    pub base: Option<u64>,
    pub data: Vec<u8>,
}

/// The Mac's side of one viewer stream.
#[derive(Debug, Clone)]
pub struct HybridStream {
    cols: u16,
    rows: u16,
    blank: Grid,
    /// What the viewer shows after the newest frame.
    shown: Overlay,
    frame: u64,
    /// What the viewer showed after frame `base_frame`, the one before `sent`'s first.
    base: Overlay,
    base_frame: u64,
    /// Frames `base_frame + 1 ..= frame`, encoded.
    sent: VecDeque<Vec<u8>>,
    sent_bytes: usize,
}

impl HybridStream {
    pub fn new(cols: u16, rows: u16) -> HybridStream {
        HybridStream {
            cols,
            rows,
            blank: Grid::blank(cols, rows),
            shown: Overlay::new(cols, rows),
            frame: 0,
            base: Overlay::new(cols, rows),
            base_frame: 0,
            sent: VecDeque::new(),
            sent_bytes: 0,
        }
    }

    pub fn size(&self) -> (u16, u16) {
        (self.cols, self.rows)
    }

    /// The newest frame's number.
    pub fn frame(&self) -> u64 {
        self.frame
    }

    /// What the viewer shows after the newest frame.
    pub fn shown(&self) -> Grid {
        self.shown.compose(&self.blank)
    }

    /// The frame that turns the viewer's screen into `real`, or `None` when it shows `real`
    /// already. `at_ms` is the time the delta carries.
    pub fn update(&mut self, real: &Grid, at_ms: u64) -> Option<Frame> {
        let delta = self.shown.delta(&self.blank, real, 0, at_ms);
        if delta.shift == 0 && delta.spans.is_empty() {
            return None;
        }
        self.shown.apply_delta(&delta, &self.blank);
        let data = delta.encode();
        let base = self.frame;
        self.frame += 1;
        self.sent_bytes += data.len();
        self.sent.push_back(data.clone());
        while self.sent.len() > RESUME_FRAMES || self.sent_bytes > RESUME_BYTES {
            let Some(oldest) = self.sent.pop_front() else { break };
            self.sent_bytes -= oldest.len();
            if let Some(delta) = Delta::decode(&oldest) {
                self.base.apply_delta(&delta, &self.blank);
            }
            self.base_frame += 1;
        }
        Some(Frame { frame: self.frame, base: Some(base), data })
    }

    /// The newest screen as one delta over a blank screen.
    pub fn keyframe(&self, at_ms: u64) -> Frame {
        let delta = Overlay::new(self.cols, self.rows).delta(&self.blank, &self.shown(), 0, at_ms);
        Frame { frame: self.frame, base: None, data: delta.encode() }
    }

    /// One delta from what the viewer showed after frame `from` to the newest screen, when
    /// the stream still holds `from`; `None` otherwise (send a keyframe).
    pub fn resume(&self, from: u64, at_ms: u64) -> Option<Frame> {
        if from < self.base_frame || from > self.frame {
            return None;
        }
        let mut then = self.base.clone();
        let steps = usize::try_from(from - self.base_frame).ok()?;
        for data in self.sent.iter().take(steps) {
            then.apply_delta(&Delta::decode(data)?, &self.blank);
        }
        let delta = then.delta(&self.blank, &self.shown(), 0, at_ms);
        Some(Frame { frame: self.frame, base: Some(from), data: delta.encode() }).filter(|frame| {
            // A resume never costs more than the keyframe it saves.
            frame.data.len() <= self.keyframe(at_ms).data.len()
        })
    }

    /// The terminal changed size: the viewer starts over from a keyframe at the new size, and
    /// no frame before this one can be resumed from.
    pub fn resize(&mut self, cols: u16, rows: u16) {
        let frame = self.frame + 1;
        *self = HybridStream::new(cols, rows);
        self.frame = frame;
        self.base_frame = frame;
    }
}

/// When the next frame goes out: once `settle` passed after the first write it holds, so a
/// burst of writes goes as one frame and a typed key's echo is not held, and at most one
/// frame per `interval`.
#[derive(Debug, Clone)]
pub struct FramePacer {
    interval: Duration,
    settle: Duration,
    first_write: Option<Instant>,
    last_frame: Option<Instant>,
}

/// One frame per 100 ms: the interval `tests/parity.rs` measured at 100% parity.
pub const FRAME_INTERVAL: Duration = Duration::from_millis(100);
/// How long a frame waits after the first write it holds.
pub const FRAME_SETTLE: Duration = Duration::from_millis(8);

impl Default for FramePacer {
    fn default() -> FramePacer {
        FramePacer::new(FRAME_INTERVAL, FRAME_SETTLE)
    }
}

impl FramePacer {
    pub fn new(interval: Duration, settle: Duration) -> FramePacer {
        FramePacer { interval, settle, first_write: None, last_frame: None }
    }

    /// The terminal wrote at `now`.
    pub fn wrote(&mut self, now: Instant) {
        self.first_write.get_or_insert(now);
    }

    /// When the held writes are due; `None` when nothing is held.
    pub fn due(&self) -> Option<Instant> {
        let first = self.first_write?;
        let settled = first + self.settle;
        Some(self.last_frame.map_or(settled, |last| settled.max(last + self.interval)))
    }

    /// A frame went out at `now`.
    pub fn sent(&mut self, now: Instant) {
        self.first_write = None;
        self.last_frame = Some(now);
    }
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
