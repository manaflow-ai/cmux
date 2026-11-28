//! One viewer session's field numbers (goal screen-share-fast): connect to the
//! first frame on glass, and the whole session's display-to-glass and Present
//! p50/p95, as one JSON object, schema [`SCHEMA`].
//!
//! The stage ledger ([`crate::ledger`]) keeps only the newest frames (about a
//! minute); a session of an hour needs its whole run, so the presented frames
//! also go into two fixed histograms here (half-millisecond buckets to 2 s,
//! a count above). Constant memory per session, numbers only: nothing in a
//! report names a person, a Mac or what was on the screen. The app sends it at
//! the session's end through crash reporting, only while the person kept
//! anonymous telemetry on. No I/O, no clock.
//!
//! Reliability from real sessions (research note 2026-11-28-screen-share-10x,
//! idea 1): the report also counts the main surface's freezes (W3C
//! webrtc-stats `freezeCount` / `totalFreezesDuration`, attributed with the
//! host's display times so an idle, unchanging screen is not a freeze), the
//! link's stalls and the time from each resume to the next frame on glass,
//! keyframes and recovery frames, and whether the session ended stalled.

use crate::ledger::{FrameRow, Percentiles};

/// The report's schema name.
pub const SCHEMA: &str = "cmux.rd-session-report/1";

/// Bucket width, microseconds. Bucket `i` holds samples in
/// `((i - 1) * BUCKET_US, i * BUCKET_US]` and reads as its upper edge, so a
/// percentile rounds up by under half a millisecond, never down.
const BUCKET_US: u64 = 500;
/// Buckets kept: 0 to 2000 ms. Slower samples count in `over` (and `max_us`).
const BUCKETS: usize = 4001;

/// A gap between two frames on glass is a freeze candidate past this, or
/// past three times the usual frame interval when that is longer (W3C
/// webrtc-stats: `max(3 x mean interval, mean + 150 ms)`; a screen's frames
/// come at up to 60 fps, so the floor decides almost always).
pub const FREEZE_FLOOR_US: u64 = 200_000;
/// Weight of each new normal interval in the running mean (1/16).
const INTERVAL_EWMA: f64 = 1.0 / 16.0;

/// The main surface's freezes: gaps on glass longer than the threshold that
/// the host did not also leave (its display times were closer together).
#[derive(Debug, Default, Clone)]
struct Freezes {
    last_presented_us: Option<u64>,
    /// The last frame's host display time (host clock), when known.
    last_display_us: Option<u64>,
    mean_interval_us: Option<f64>,
    count: u32,
    frozen_us: u64,
    /// Gaps past the threshold with no host display time on one side: the
    /// screen may have been still, so they are not counted as freezes.
    unattributed: u32,
}

impl Freezes {
    fn threshold_us(&self) -> u64 {
        let mean = self.mean_interval_us.unwrap_or(0.0);
        FREEZE_FLOOR_US.max((3.0 * mean) as u64)
    }

    fn on_presented(&mut self, presented_us: u64, display_us: Option<u64>) {
        if let Some(prev) = self.last_presented_us {
            let gap = presented_us.saturating_sub(prev);
            let threshold = self.threshold_us();
            if gap > threshold {
                match (display_us, self.last_display_us) {
                    (Some(d), Some(prev_d)) => {
                        // The time a newer picture existed on the host but not on glass.
                        let late = gap.saturating_sub(d.saturating_sub(prev_d));
                        if late > threshold {
                            self.count = self.count.saturating_add(1);
                            self.frozen_us = self.frozen_us.saturating_add(late);
                        }
                    }
                    _ => self.unattributed = self.unattributed.saturating_add(1),
                }
            } else {
                let g = gap as f64;
                self.mean_interval_us =
                    Some(self.mean_interval_us.map_or(g, |m| m + INTERVAL_EWMA * (g - m)));
            }
        }
        self.last_presented_us = Some(presented_us);
        self.last_display_us = display_us;
    }
}

/// Nearest-rank percentiles over a fixed-bucket histogram.
#[derive(Debug, Default, Clone)]
struct Histogram {
    counts: Vec<u32>,
    over: u32,
    n: u32,
    max_us: u64,
}

impl Histogram {
    fn add(&mut self, us: u64) {
        if self.counts.is_empty() {
            self.counts = vec![0; BUCKETS];
        }
        let i = usize::try_from(us.div_ceil(BUCKET_US)).unwrap_or(usize::MAX);
        match self.counts.get_mut(i) {
            Some(c) => *c = c.saturating_add(1),
            None => self.over = self.over.saturating_add(1),
        }
        self.n = self.n.saturating_add(1);
        self.max_us = self.max_us.max(us);
    }

    /// The bucket's upper edge at nearest rank `p` (0 to 1), in ms; the
    /// largest sample when the rank falls above 2 s.
    fn rank_ms(&self, p: f64) -> f64 {
        let rank = ((p * f64::from(self.n)).ceil() as u64).max(1);
        let mut seen = 0u64;
        for (i, c) in self.counts.iter().enumerate() {
            seen += u64::from(*c);
            if seen >= rank {
                let edge = i as u64 * BUCKET_US;
                return edge.min(self.max_us) as f64 / 1000.0;
            }
        }
        self.max_us as f64 / 1000.0
    }

    fn percentiles(&self) -> Option<Percentiles> {
        (self.n > 0).then(|| Percentiles {
            n: self.n as usize,
            p50_ms: self.rank_ms(0.5),
            p95_ms: self.rank_ms(0.95),
        })
    }
}

/// A session's report so far. Viewer times are the session's clock (as passed
/// to `push_*`); the host's display time is converted with the clock offset
/// known when the frame was presented.
#[derive(Debug, Default, Clone)]
pub struct SessionReport {
    connect_started_us: Option<u64>,
    first_presented_us: Option<u64>,
    last_presented_us: Option<u64>,
    frames_presented: u64,
    /// Host display time to on glass (the ledger's Total).
    total: Histogram,
    /// Decoded to on glass (the ledger's Present).
    present: Histogram,
    freezes: Freezes,
    stalls: u32,
    stalled_us: u64,
    /// When the host went silent, while the link is stalled.
    stalled_since_us: Option<u64>,
    /// When the last stall ended, until the next main-surface frame on glass.
    resumed_us: Option<u64>,
    /// A resume to the next main-surface frame on glass.
    resume_first_frame: Histogram,
    keyframes: u64,
    recovery_frames: u64,
}

/// The numbers of one session.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionSummary {
    /// Connect start to the first frame on glass, ms; `None` before both.
    pub first_frame_ms: Option<f64>,
    /// Host display time to on glass over every presented frame with host
    /// times and a clock offset.
    pub total: Option<Percentiles>,
    /// Decoded to on glass over every presented frame with a decode time.
    pub present: Option<Percentiles>,
    pub frames_presented: u64,
    /// First to last frame on glass, seconds.
    pub presenting_s: f64,
    /// Main-surface freezes (gaps on glass past [`FREEZE_FLOOR_US`] or 3x the
    /// usual interval that the host's display times did not share).
    pub freezes: u32,
    /// Their total time a newer picture existed but was not on glass, ms.
    pub frozen_ms: f64,
    /// Long gaps that could not be attributed (no host display time).
    pub freeze_unattributed: u32,
    /// Link stalls (a heartbeating host went silent) and their silent time, ms
    /// (a stall still open at the report counts in `stalls` only).
    pub stalls: u32,
    pub stalled_ms: f64,
    /// Each resume to the next main-surface frame on glass.
    pub resume_first_frame: Option<Percentiles>,
    /// Main-surface keyframes and recovery frames released to the decoder.
    pub keyframes: u64,
    pub recovery_frames: u64,
    /// Whether the session ended (or was read) stalled: silence, not a
    /// clean end.
    pub ended_stalled: bool,
}

impl SessionReport {
    pub fn new() -> Self {
        Self::default()
    }

    /// The viewer began connecting at `at_us`. The first call counts (a
    /// reconnect is its own session).
    pub fn note_connect_started(&mut self, at_us: u64) {
        self.connect_started_us.get_or_insert(at_us);
    }

    /// The link stalled: a heartbeating host has been silent since
    /// `silent_since_us`. Repeated calls during one stall count once.
    pub fn on_stalled(&mut self, silent_since_us: u64) {
        if self.stalled_since_us.is_none() {
            self.stalled_since_us = Some(silent_since_us);
            self.stalls = self.stalls.saturating_add(1);
        }
    }

    /// The host was heard again at `at_us`; ends a stall, if one was open.
    pub fn on_heard(&mut self, at_us: u64) {
        if let Some(since) = self.stalled_since_us.take() {
            self.stalled_us = self.stalled_us.saturating_add(at_us.saturating_sub(since));
            self.resumed_us = Some(at_us);
        }
    }

    /// A main-surface frame with header `flags` was released to the decoder.
    pub fn on_released(&mut self, flags: u8) {
        if flags & cmux_rd_proto::flags::KEYFRAME != 0 {
            self.keyframes = self.keyframes.saturating_add(1);
        }
        if flags & cmux_rd_proto::flags::RECOVERY != 0 {
            self.recovery_frames = self.recovery_frames.saturating_add(1);
        }
    }

    /// A main-surface (stream 0) frame reached the glass: [`Self::on_presented`]
    /// plus the freeze and resume counts, which only the main surface feeds
    /// (popups and tiles have their own cadence).
    pub fn on_main_presented(
        &mut self,
        row: Option<&FrameRow>,
        offset_us: Option<i64>,
        presented_us: u64,
    ) {
        let display = row.and_then(|r| r.host).map(|h| h.display_us).filter(|t| *t != 0);
        self.freezes.on_presented(presented_us, display);
        if let Some(resumed) = self.resumed_us.take() {
            self.resume_first_frame.add(presented_us.saturating_sub(resumed));
        }
        self.on_presented(row, offset_us, presented_us);
    }

    /// A frame reached the glass at `presented_us`; `row` is its ledger row
    /// when the ledger still had it.
    pub fn on_presented(
        &mut self,
        row: Option<&FrameRow>,
        offset_us: Option<i64>,
        presented_us: u64,
    ) {
        self.first_presented_us.get_or_insert(presented_us);
        self.last_presented_us =
            Some(self.last_presented_us.map_or(presented_us, |t| t.max(presented_us)));
        self.frames_presented = self.frames_presented.saturating_add(1);
        let Some(row) = row else { return };
        if let Some(us) = row.viewer.decoded_us.and_then(|d| presented_us.checked_sub(d)) {
            self.present.add(us);
        }
        let display = row.host.map(|h| h.display_us).filter(|t| *t != 0);
        if let (Some(display), Some(offset)) = (display, offset_us) {
            let on_host = i128::from(presented_us) + i128::from(offset);
            if let Ok(us) = u64::try_from(on_host - i128::from(display)) {
                self.total.add(us);
            }
        }
    }

    pub fn summary(&self) -> SessionSummary {
        let first_frame_ms = match (self.connect_started_us, self.first_presented_us) {
            (Some(a), Some(b)) => b.checked_sub(a).map(|us| us as f64 / 1000.0),
            _ => None,
        };
        let presenting_s = match (self.first_presented_us, self.last_presented_us) {
            (Some(a), Some(b)) => b.saturating_sub(a) as f64 / 1e6,
            _ => 0.0,
        };
        SessionSummary {
            first_frame_ms,
            total: self.total.percentiles(),
            present: self.present.percentiles(),
            frames_presented: self.frames_presented,
            presenting_s,
            freezes: self.freezes.count,
            frozen_ms: self.freezes.frozen_us as f64 / 1000.0,
            freeze_unattributed: self.freezes.unattributed,
            stalls: self.stalls,
            stalled_ms: self.stalled_us as f64 / 1000.0,
            resume_first_frame: self.resume_first_frame.percentiles(),
            keyframes: self.keyframes,
            recovery_frames: self.recovery_frames,
            ended_stalled: self.stalled_since_us.is_some(),
        }
    }
}

fn num(x: Option<f64>) -> String {
    match x {
        Some(x) if x.is_finite() => format!("{x:.1}"),
        _ => "null".to_owned(),
    }
}

fn pct(p: Option<Percentiles>) -> String {
    match p {
        Some(p) => format!(
            "{{\"n\":{},\"p50_ms\":{},\"p95_ms\":{}}}",
            p.n,
            num(Some(p.p50_ms)),
            num(Some(p.p95_ms))
        ),
        None => "null".to_owned(),
    }
}

impl SessionSummary {
    /// The summary as one JSON object (schema [`SCHEMA`]).
    pub fn to_json(&self) -> String {
        format!(
            "{{\"schema\":\"{SCHEMA}\",\"first_frame_ms\":{},\"total\":{},\"present\":{},\"frames_presented\":{},\"presenting_s\":{},\"freezes\":{},\"frozen_ms\":{},\"freeze_unattributed\":{},\"stalls\":{},\"stalled_ms\":{},\"resume_first_frame\":{},\"keyframes\":{},\"recovery_frames\":{},\"end\":\"{}\"}}",
            num(self.first_frame_ms),
            pct(self.total),
            pct(self.present),
            self.frames_presented,
            num(Some(self.presenting_s)),
            self.freezes,
            num(Some(self.frozen_ms)),
            self.freeze_unattributed,
            self.stalls,
            num(Some(self.stalled_ms)),
            pct(self.resume_first_frame),
            self.keyframes,
            self.recovery_frames,
            if self.ended_stalled { "stalled" } else { "live" },
        )
    }
}
