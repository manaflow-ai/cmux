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

use crate::ledger::{FrameRow, Percentiles};

/// The report's schema name.
pub const SCHEMA: &str = "cmux.rd-session-report/1";

/// Bucket width, microseconds. Bucket `i` holds samples in
/// `((i - 1) * BUCKET_US, i * BUCKET_US]` and reads as its upper edge, so a
/// percentile rounds up by under half a millisecond, never down.
const BUCKET_US: u64 = 500;
/// Buckets kept: 0 to 2000 ms. Slower samples count in `over` (and `max_us`).
const BUCKETS: usize = 4001;

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
            "{{\"schema\":\"{SCHEMA}\",\"first_frame_ms\":{},\"total\":{},\"present\":{},\"frames_presented\":{},\"presenting_s\":{}}}",
            num(self.first_frame_ms),
            pct(self.total),
            pct(self.present),
            self.frames_presented,
            num(Some(self.presenting_s)),
        )
    }
}
