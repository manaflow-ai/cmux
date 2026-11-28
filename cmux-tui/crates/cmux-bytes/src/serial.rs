//! The zstd level for a serial copy: one core compresses a page, the page crosses the link, then
//! the next page. Session move's history pager (`acpmux` `cli/run/transfer_live.rs`) works this
//! way. There the two costs add, so the best level is the one with the least
//! `1/speed(l) + ratio(l)/link` seconds per raw byte. [`crate::policy::level_for`] is for a
//! pipelined fill, where the slower stage binds; this is its serial counterpart.
//!
//! A [`Curve`] is one kind of data's speed and ratio per level, measured. A [`Climb`] calibrates
//! it during the copy and picks each page's level from what the copy has seen so far:
//! - this machine's compressor against the curve: the measured speed at the level used, over the
//!   curve's speed at that level;
//! - the link: wire bytes over the seconds their writes took.
//!
//! Leo, 2026-11-27: "we have our own optimized for various cases/heuristics for compression. we
//! have our own optimized transport for various cases/heuristics. as fast as possible, as
//! syncable as possible, all that. and hill climbing there."

/// One kind of data's zstd curve: `(level, single-core bytes/s, compressed/raw)`, by level.
#[derive(Clone, Copy, Debug)]
pub struct Curve {
    pub name: &'static str,
    pub points: &'static [(i32, f64, f64)],
}

const MB: f64 = 1e6;

/// acpmux event logs (`events/NNNNNN.ndjson`) in 4 MiB pages, as a move sends them. Measured by
/// `scripts/measure/evlog-zstd-levels.py` on fs-agent-lane-34, 2026-11-27: the 40 largest logs,
/// 54 pages, 118 MB, one core, zstd 1.5 (the same library acpmux links).
pub const EVENT_LOG: Curve = Curve {
    name: "event-log",
    points: &[
        (1, 714.0 * MB, 0.1104),
        (3, 537.0 * MB, 0.0951),
        (5, 191.0 * MB, 0.0899),
        (7, 121.0 * MB, 0.0847),
        (9, 88.5 * MB, 0.0810),
        (12, 48.7 * MB, 0.0800),
        (15, 14.0 * MB, 0.0790),
        (19, 2.6 * MB, 0.0740),
    ],
};

impl Curve {
    fn point(&self, level: i32) -> (f64, f64) {
        // A level between two measured ones takes the slower (higher) point's numbers.
        let p = self.points.iter().find(|p| p.0 >= level).or(self.points.last());
        p.map_or((1.0, 1.0), |p| (p.1, p.2))
    }

    /// Seconds per raw byte at `level`: compressing on one core `cpu` times the curve's speed,
    /// then sending the compressed bytes at `link` bytes/s.
    pub fn serial_cost(&self, level: i32, cpu: f64, link: f64) -> f64 {
        let (speed, ratio) = self.point(level);
        1.0 / (speed * cpu).max(1.0) + ratio / link.max(1.0)
    }

    /// The level with the least serial cost.
    pub fn best(&self, cpu: f64, link: f64) -> i32 {
        let cost = |l: i32| self.serial_cost(l, cpu, link);
        self.points.iter().map(|p| p.0).min_by(|a, b| cost(*a).total_cmp(&cost(*b))).unwrap_or(3)
    }
}

/// How much one page's measurement moves the running estimate (the rest is what came before).
const KEEP: f64 = 0.7;
/// A write smaller than this says more about the round trip than the link: not counted.
const MIN_LINK_SAMPLE: u64 = 64 << 10;
/// A compression shorter than this is timer noise: not counted.
const MIN_CPU_SECS: f64 = 0.000_5;

/// The level for each page of a serial copy, from what the copy has measured.
#[derive(Clone, Debug)]
pub struct Climb {
    curve: Curve,
    level: i32,
    /// This machine's single-core speed over the curve's.
    cpu: f64,
    /// Decayed sums of wire bytes and the seconds their writes took.
    wire: f64,
    secs: f64,
    /// Pages measured, and the level each new estimate chose (for the receipt).
    pages: u32,
}

impl Climb {
    /// Starts at `start` until a page is measured (the level the copy used before: no guess).
    pub fn new(curve: Curve, start: i32) -> Self {
        Self { curve, level: start, cpu: 1.0, wire: 0.0, secs: 0.0, pages: 0 }
    }

    /// The level the next page goes at.
    pub fn level(&self) -> i32 {
        self.level
    }

    /// The link's rate as measured so far, bytes/s.
    pub fn link(&self) -> Option<f64> {
        (self.secs > 0.0).then(|| self.wire / self.secs)
    }

    pub fn curve(&self) -> &'static str {
        self.curve.name
    }

    /// One page: `raw` bytes became `wire` bytes in `compress_secs` at [`Self::level`], and the
    /// write took `send_secs`. Picks the next page's level.
    pub fn observe(&mut self, raw: u64, wire: u64, compress_secs: f64, send_secs: f64) {
        if compress_secs >= MIN_CPU_SECS && raw > 0 {
            let (speed, _) = self.curve.point(self.level);
            let measured = (raw as f64 / compress_secs) / speed;
            self.cpu =
                if self.pages == 0 { measured } else { KEEP * self.cpu + (1.0 - KEEP) * measured };
        }
        if wire >= MIN_LINK_SAMPLE && send_secs > 0.0 {
            self.wire = KEEP * self.wire + wire as f64;
            self.secs = KEEP * self.secs + send_secs;
        }
        self.pages += 1;
        if let Some(link) = self.link() {
            self.level = self.curve.best(self.cpu, link);
        }
    }
}

#[cfg(test)]
#[path = "serial_tests.rs"]
mod tests;
