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
use crate::hybrid::{Delta, Overlay, grid_row_hashes};

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
    /// `shown`'s row hashes, and the newest real screen's: a frame diffs only the rows they
    /// differ in.
    shown_hashes: Vec<u64>,
    real_hashes: Vec<u64>,
    /// A candidate delta's bytes while [`Overlay::delta_over_blank`] picks one.
    scratch: Vec<u8>,
}

impl HybridStream {
    pub fn new(cols: u16, rows: u16) -> HybridStream {
        let shown = Overlay::new(cols, rows);
        let mut shown_hashes = Vec::new();
        shown.row_hashes_over_blank(&mut shown_hashes);
        HybridStream {
            cols,
            rows,
            blank: Grid::blank(cols, rows),
            shown,
            frame: 0,
            base: Overlay::new(cols, rows),
            base_frame: 0,
            sent: VecDeque::new(),
            sent_bytes: 0,
            shown_hashes,
            real_hashes: Vec::new(),
            scratch: Vec::new(),
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
    ///
    /// Only the rows whose hash changed are diffed, and only the shifts that line up the most
    /// rows are tried ([`Overlay::delta_over_blank`]): no full-screen diff or clone per frame.
    pub fn update(&mut self, real: &Grid, at_ms: u64) -> Option<Frame> {
        grid_row_hashes(real, self.cols, self.rows, &mut self.real_hashes);
        let delta = self.shown.delta_over_blank(
            real,
            &self.shown_hashes,
            &self.real_hashes,
            0,
            at_ms,
            &mut self.scratch,
        )?;
        self.shown.apply_delta_over_blank(&delta);
        // The shown screen now looks like `real`, row for row.
        std::mem::swap(&mut self.shown_hashes, &mut self.real_hashes);
        let data = delta.encode();
        let base = self.frame;
        self.frame += 1;
        self.sent_bytes += data.len();
        self.sent.push_back(data.clone());
        while self.sent.len() > RESUME_FRAMES || self.sent_bytes > RESUME_BYTES {
            let Some(oldest) = self.sent.pop_front() else { break };
            self.sent_bytes -= oldest.len();
            if let Some(delta) = Delta::decode(&oldest) {
                self.base.apply_delta_over_blank(&delta);
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
mod tests {
    use super::*;
    use crate::{Line, Style};

    fn screen(lines: &[&str]) -> Grid {
        let mut grid = Grid::blank(20, 4);
        for (slot, text) in grid.cells.iter_mut().zip(lines) {
            let mut line = Line::new();
            line.push(text, Style::fg(174));
            *slot = line.into_row(20);
        }
        grid
    }

    /// What a viewer shows after applying `frames` in order.
    fn viewer(frames: &[&Frame]) -> Grid {
        let blank = Grid::blank(20, 4);
        let mut shown = Overlay::new(20, 4);
        for frame in frames {
            if frame.base.is_none() {
                shown = Overlay::new(20, 4);
            }
            shown.apply_delta(&Delta::decode(&frame.data).unwrap(), &blank);
        }
        shown.compose(&blank)
    }

    #[test]
    fn frames_turn_the_viewer_into_the_real_screen() {
        let mut stream = HybridStream::new(20, 4);
        let a = stream.update(&screen(&["> hi"]), 0).unwrap();
        assert_eq!((a.base, a.frame), (Some(0), 1));
        assert!(stream.update(&screen(&["> hi"]), 5).is_none(), "nothing changed");
        let b = stream.update(&screen(&["> hi", "✻ Misting…"]), 10).unwrap();
        assert_eq!((b.base, b.frame), (Some(1), 2));
        assert_eq!(viewer(&[&a, &b]).parity(&screen(&["> hi", "✻ Misting…"])), (80, 80));
        let key = stream.keyframe(20);
        assert_eq!((key.base, key.frame), (None, 2));
        assert_eq!(viewer(&[&key]).parity(&screen(&["> hi", "✻ Misting…"])), (80, 80));
    }

    #[test]
    fn a_resume_sends_only_what_changed_since_the_viewers_frame() {
        let mut stream = HybridStream::new(20, 4);
        let a = stream.update(&screen(&["one", "two", "three"]), 0).unwrap();
        // The viewer drops after frame 1; two frames go out without it.
        stream.update(&screen(&["one", "two", "three", "four"]), 10).unwrap();
        stream.update(&screen(&["one", "two!", "three", "four"]), 20).unwrap();
        let resumed = stream.resume(1, 30).unwrap();
        assert_eq!((resumed.base, resumed.frame), (Some(1), 3));
        assert!(resumed.data.len() < stream.keyframe(30).data.len());
        let want = screen(&["one", "two!", "three", "four"]);
        assert_eq!(viewer(&[&a, &resumed]).parity(&want), (80, 80));
        // Up to date: an empty delta.
        let again = stream.resume(3, 40).unwrap();
        assert_eq!(viewer(&[&a, &resumed, &again]).parity(&stream.shown()), (80, 80));
        // A frame the stream never sent.
        assert!(stream.resume(9, 40).is_none());
    }

    #[test]
    fn a_resume_from_a_frame_past_the_kept_ones_needs_a_keyframe() {
        let mut stream = HybridStream::new(20, 4);
        for n in 0..(RESUME_FRAMES as u64 + 10) {
            stream.update(&screen(&[&format!("line {n}")]), n);
        }
        assert!(stream.resume(1, 0).is_none());
        let kept = stream.frame() - 5;
        assert!(stream.resume(kept, 0).is_some());
    }

    #[test]
    fn a_scrolling_screen_reaches_the_viewer_frame_by_frame() {
        // A document scrolled both ways under a status row that changes every frame, with
        // inverse and styled blanks: every frame leaves the viewer showing the real screen.
        let (cols, rows) = (24u16, 8u16);
        let blank = Grid::blank(cols, rows);
        let doc: Vec<String> = (0..60).map(|n| format!("line {n} {}", "x".repeat(n % 7))).collect();
        let at = |top: usize, tick: usize| {
            let mut grid = Grid::blank(cols, rows);
            for (y, slot) in grid.cells.iter_mut().enumerate() {
                let mut line = Line::new();
                if y + 1 == usize::from(rows) {
                    line.push(&format!("status {tick}"), Style::fg(174).with(crate::INVERSE));
                } else if let Some(text) = doc.get(top + y) {
                    line.push(text, Style::fg((top + y) as u8));
                }
                *slot = line.into_row(usize::from(cols));
            }
            grid
        };
        let mut stream = HybridStream::new(cols, rows);
        let mut shown = Overlay::new(cols, rows);
        let mut top = 0usize;
        let path = [3i32, 3, 3, -3, -3, 1, 1, 0, 7, -2, -9, 2, 2, 2, 0, 5];
        for (tick, step) in path.iter().cycle().take(64).enumerate() {
            top = top.saturating_add_signed(*step as isize).min(50);
            let real = at(top, tick / 2);
            if let Some(frame) = stream.update(&real, tick as u64) {
                shown.apply_delta(&Delta::decode(&frame.data).unwrap(), &blank);
            }
            let cells = usize::from(cols) * usize::from(rows);
            assert_eq!(shown.compose(&blank).parity(&real), (cells, cells), "tick {tick}");
            assert_eq!(stream.shown().parity(&real), (cells, cells), "tick {tick}");
        }
        // On a plain scroll the ranked shifts find the frame the full search finds.
        let mut a = HybridStream::new(cols, rows);
        a.update(&at(10, 0), 0).unwrap();
        let fast = a.update(&at(13, 0), 1).unwrap();
        let mut over = Overlay::new(cols, rows);
        over.apply_delta(&over.delta(&blank, &at(10, 0), 0, 0), &blank);
        let slow = over.delta(&blank, &at(13, 0), 0, 1).encode();
        assert_eq!(Delta::decode(&fast.data).unwrap().shift, 3);
        assert_eq!(fast.data, slow);
    }

    #[test]
    fn a_resize_starts_over() {
        let mut stream = HybridStream::new(20, 4);
        stream.update(&screen(&["one"]), 0).unwrap();
        stream.resize(30, 6);
        assert_eq!(stream.size(), (30, 6));
        assert_eq!(stream.frame(), 2);
        assert!(stream.resume(1, 0).is_none());
        assert!(stream.resume(2, 0).is_some());
    }

    #[test]
    fn the_pacer_holds_a_burst_and_keeps_an_interval() {
        let start = Instant::now();
        let ms = |n| start + Duration::from_millis(n);
        let mut pacer = FramePacer::default();
        assert_eq!(pacer.due(), None);
        pacer.wrote(ms(0));
        pacer.wrote(ms(3));
        assert_eq!(pacer.due(), Some(ms(8)));
        pacer.sent(ms(8));
        assert_eq!(pacer.due(), None);
        pacer.wrote(ms(20));
        assert_eq!(pacer.due(), Some(ms(108)));
        pacer.sent(ms(108));
        // Idle for longer than an interval: only the settle.
        pacer.wrote(ms(500));
        assert_eq!(pacer.due(), Some(ms(508)));
    }
}
