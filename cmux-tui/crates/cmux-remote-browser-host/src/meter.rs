//! Media numbers of one viewer for the host log (`serve: stats {json}`):
//! frames, keyframes and bytes sent per window, the time of each pump call
//! that encoded a frame on capture (VideoToolbox encode plus packetize;
//! frames the fps cap held and encoded later on a tick are counted but not
//! timed), and the time from viewer input that can draw (key down, button
//! down, wheel) to the next frame sent (page render, capture, encode and
//! packetize; the network, decode and present are the viewer's). Popup
//! surface streams count with the page.
//! The live check (scripts/cmux-next/remote-browser-local-live.py --stats)
//! reads these lines from the host log the app keeps. Every time is the
//! caller's monotonic clock in microseconds.

use serde::Serialize;

/// The shortest window between two stats lines.
pub const WINDOW_US: u64 = 1_000_000;
/// Input older than this when a frame goes out counts as input that drew
/// nothing (a hover over a still page), not as a latency sample.
pub const INPUT_STALE_US: u64 = 1_000_000;

/// One stats line (one window).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Window {
    /// Window length in milliseconds.
    pub ms: u64,
    pub frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
    /// Frames per second and kilobits per second over the window.
    pub fps: f64,
    pub kbps: f64,
    /// The encoder's target bitrate at the end of the window.
    pub target_kbps: u32,
    /// Pump call time of the frames encoded on capture, milliseconds.
    pub encode_ms: Summary,
    /// Viewer input to the next frame sent, milliseconds.
    pub input_to_frame_ms: Vec<f64>,
    /// Totals since the viewer joined.
    pub total_frames: u64,
    pub total_bytes: u64,
}

/// Count, median, 95th percentile and largest of some times (milliseconds).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Summary {
    pub n: usize,
    pub p50: Option<f64>,
    pub p95: Option<f64>,
    pub max: Option<f64>,
}

impl Summary {
    fn of(us: &[u64]) -> Self {
        let mut v = us.to_vec();
        v.sort_unstable();
        let at = |q: f64| {
            let last = v.len().checked_sub(1)?;
            v.get(((q * last as f64).round() as usize).min(last)).map(|&us| ms(us))
        };
        Self { n: v.len(), p50: at(0.5), p95: at(0.95), max: v.last().map(|&us| ms(us)) }
    }
}

/// Counters of one viewer since it joined.
#[derive(Debug, Default)]
pub struct Meter {
    start_us: Option<u64>,
    frames: u64,
    keyframes: u64,
    bytes: u64,
    encode_us: Vec<u64>,
    input_us: Vec<u64>,
    pending_input_us: Option<u64>,
    total_frames: u64,
    total_bytes: u64,
}

impl Meter {
    /// Bytes put on the stream carrier (datagram payloads).
    /// They open no window: feedback answers on a still page are no media.
    pub fn sent(&mut self, bytes: usize) {
        let bytes = bytes as u64;
        self.bytes += bytes;
        self.total_bytes += bytes;
    }

    /// Viewer input that can draw reached the page; the next frame answers
    /// it. A pending input older than [`INPUT_STALE_US`] drew nothing and
    /// gives way.
    pub fn input(&mut self, now_us: u64) {
        self.start_us.get_or_insert(now_us);
        match self.pending_input_us {
            Some(t) if now_us.saturating_sub(t) <= INPUT_STALE_US => {}
            _ => self.pending_input_us = Some(now_us),
        }
    }

    /// When the open window is full (a timer flushes it on a page that
    /// went still); `None` while nothing was counted.
    pub fn deadline_us(&self) -> Option<u64> {
        self.start_us.map(|t| t + WINDOW_US)
    }

    /// `frames` frames (`keyframes` of them IDR) were encoded by one pump
    /// call that took `call_us`.
    pub fn encoded(&mut self, frames: u64, keyframes: u64, call_us: Option<u64>, now_us: u64) {
        if frames == 0 {
            return;
        }
        self.start_us.get_or_insert(now_us);
        self.frames += frames;
        self.keyframes += keyframes;
        self.total_frames += frames;
        if let Some(call_us) = call_us {
            self.encode_us.push(call_us);
        }
        if let Some(t) = self.pending_input_us.take() {
            let waited = now_us.saturating_sub(t);
            if waited <= INPUT_STALE_US {
                self.input_us.push(waited);
            }
        }
    }

    /// The line for the window that ends now: once the window is
    /// [`WINDOW_US`] long (or at once with `flush`), and only when it sent
    /// a frame. Starts the next window.
    pub fn take(&mut self, target_kbps: u32, flush: bool, now_us: u64) -> Option<Window> {
        let start = self.start_us?;
        let elapsed = now_us.saturating_sub(start);
        if !flush && elapsed < WINDOW_US {
            return None;
        }
        // Input that waits for a frame stays pending into the next window.
        // A window that sent something is followed at once by the next
        // (steady streaming has no gap); after a silent one, the next starts
        // at its first activity.
        let pending = self.pending_input_us.filter(|&t| now_us.saturating_sub(t) <= INPUT_STALE_US);
        let busy = self.frames > 0;
        let line = busy.then(|| {
            let secs = (elapsed.max(1) as f64) / 1e6;
            Window {
                ms: elapsed / 1000,
                frames: self.frames,
                keyframes: self.keyframes,
                bytes: self.bytes,
                fps: round1(self.frames as f64 / secs),
                kbps: round1(self.bytes as f64 * 8.0 / 1000.0 / secs),
                target_kbps,
                encode_ms: Summary::of(&self.encode_us),
                input_to_frame_ms: self.input_us.iter().map(|&us| ms(us)).collect(),
                total_frames: self.total_frames,
                total_bytes: self.total_bytes,
            }
        });
        let (total_frames, total_bytes) = (self.total_frames, self.total_bytes);
        *self = Self {
            start_us: (busy || pending.is_some()).then_some(now_us),
            pending_input_us: pending,
            total_frames,
            total_bytes,
            ..Self::default()
        };
        line
    }
}

fn ms(us: u64) -> f64 {
    (us as f64 / 100.0).round() / 10.0
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}
