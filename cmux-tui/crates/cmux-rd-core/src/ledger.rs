//! The per-frame stage ledger (screen-share-under-100ms.md decision D8): every
//! frame's timestamps, from the host's display time to the viewer's present,
//! joined by stream and frame number, and the per-stage p50/p95 of a run as
//! one JSON object, schema [`SCHEMA`] (documented in cmux-rd-host's README).
//!
//! The host's times arrive in a `FrameTimes` datagram (cap `ledger`) after
//! the frame's last shard; the viewer adds its own as the frame moves through
//! reassembly, decode and present. Viewer times are kept on the viewer's
//! clock and converted to the host's (`host = viewer + offset_us`, the
//! session clock of rd change C8) only when a summary is made, so a better
//! clock estimate later corrects every row. Bounded: the newest [`MAX_ROWS`]
//! frames. No I/O, no clock.

use std::collections::VecDeque;

use cmux_rd_proto::FrameTimes;

/// The summary's schema name.
pub const SCHEMA: &str = "cmux.rd-stage-ledger/1";

/// Frames kept (about a minute at 60 fps).
pub const MAX_ROWS: usize = 4096;

/// How far back from the newest frame a stamp looks for its frame.
const LOOKBACK: usize = 512;

/// Why Input and Screen are never filled here: they need the observer.
pub const HARNESS_ONLY: &str =
    "needs the fleet harness: the observer's input and presented-marker receipts";

/// One stage of the design's budget table.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StageDef {
    pub name: &'static str,
    pub from: &'static str,
    pub to: &'static str,
    /// The design's p50 budget on a 60 Hz LAN pair, in milliseconds.
    pub budget_ms: f64,
}

/// The ten rows of the budget table, in order, with Network also split into Transport and
/// Recovery (they add up to it) right after it.
pub const STAGES: [StageDef; 12] = [
    StageDef { name: "Input", from: "viewer key down", to: "host inject", budget_ms: 3.0 },
    StageDef { name: "Screen", from: "host inject", to: "display time", budget_ms: 12.0 },
    StageDef { name: "Capture", from: "display time", to: "encode start", budget_ms: 8.0 },
    StageDef { name: "Encode", from: "encode start", to: "bitstream ready", budget_ms: 8.0 },
    StageDef { name: "Send", from: "bitstream ready", to: "last datagram sent", budget_ms: 8.0 },
    StageDef {
        name: "Network",
        from: "last datagram sent",
        to: "last shard received",
        budget_ms: 2.0,
    },
    StageDef {
        name: "Transport",
        from: "first datagram sent",
        to: "first shard received",
        budget_ms: 2.0,
    },
    // Loss repair and jitter: how much later the frame finished arriving than it finished
    // leaving, beyond the transport delay (arrival spread minus send spread).
    StageDef { name: "Recovery", from: "send spread", to: "arrival spread", budget_ms: 0.0 },
    StageDef {
        name: "Reassembly",
        from: "last shard received",
        to: "frame released",
        budget_ms: 1.0,
    },
    StageDef { name: "Decode", from: "frame released", to: "decoded", budget_ms: 5.0 },
    StageDef { name: "Present", from: "decoded", to: "presented", budget_ms: 10.0 },
    StageDef { name: "Total", from: "display time", to: "presented", budget_ms: 57.0 },
];

/// The viewer's times of one frame, viewer clock, microseconds.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ViewerTimes {
    pub first_shard_us: Option<u64>,
    /// When the frame became decodable (its last needed shard arrived).
    pub last_shard_us: Option<u64>,
    /// When reassembly released it to the decoder.
    pub released_us: Option<u64>,
    pub decoded_us: Option<u64>,
    /// When its picture reached the glass (the drawable's presented time).
    pub presented_us: Option<u64>,
}

/// One frame's row.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FrameRow {
    pub stream: u16,
    pub frame: u32,
    /// The host's times (host clock), once its `FrameTimes` arrived.
    pub host: Option<FrameTimes>,
    pub viewer: ViewerTimes,
    /// Bytes of the frame's video and parity datagrams received.
    pub bytes: u64,
}

/// p50 and p95 of one stage over a run, in milliseconds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Percentiles {
    pub n: usize,
    pub p50_ms: f64,
    pub p95_ms: f64,
}

/// One row of a summary.
#[derive(Debug, Clone, PartialEq)]
pub struct StageRow {
    pub def: StageDef,
    pub value: Option<Percentiles>,
    /// Why `value` is `None`.
    pub reason: Option<String>,
}

/// A run's table.
#[derive(Debug, Clone, PartialEq)]
pub struct Summary {
    pub frames: usize,
    pub frames_with_host_times: usize,
    pub offset_us: Option<i64>,
    pub received_mbps: Option<f64>,
    pub stages: Vec<StageRow>,
    /// Display time to decoded, for viewers that do not present.
    pub display_to_decoded: Option<Percentiles>,
}

#[derive(Debug, Default)]
pub struct StageLedger {
    rows: VecDeque<FrameRow>,
}

impl StageLedger {
    pub fn new() -> Self {
        Self::default()
    }

    /// Rows kept, oldest first.
    pub fn rows(&self) -> impl Iterator<Item = &FrameRow> {
        self.rows.iter()
    }

    /// The row of `(stream, frame)`, made if `create` and it is new.
    fn row(&mut self, stream: u16, frame: u32, create: bool) -> Option<&mut FrameRow> {
        let len = self.rows.len();
        let found = self
            .rows
            .iter()
            .rev()
            .take(LOOKBACK)
            .position(|r| r.stream == stream && r.frame == frame)
            .map(|back| len - 1 - back);
        match found {
            Some(i) => self.rows.get_mut(i),
            None if create => {
                if self.rows.len() >= MAX_ROWS {
                    self.rows.pop_front();
                }
                self.rows.push_back(FrameRow { stream, frame, ..FrameRow::default() });
                self.rows.back_mut()
            }
            None => None,
        }
    }

    /// A video or parity datagram of `bytes` bytes arrived at `now_us`.
    pub fn on_shard(&mut self, stream: u16, frame: u32, bytes: usize, now_us: u64) {
        if let Some(row) = self.row(stream, frame, true) {
            row.viewer.first_shard_us.get_or_insert(now_us);
            row.bytes = row.bytes.saturating_add(bytes as u64);
        }
    }

    /// The host's times of a frame.
    pub fn on_host(&mut self, stream: u16, frame: u32, times: FrameTimes) {
        if let Some(row) = self.row(stream, frame, true) {
            row.host = Some(times);
        }
    }

    /// Reassembly released the frame: complete at `last_shard_us`, released at `released_us`.
    pub fn on_released(&mut self, stream: u16, frame: u32, last_shard_us: u64, released_us: u64) {
        if let Some(row) = self.row(stream, frame, true) {
            row.viewer.last_shard_us = Some(last_shard_us);
            row.viewer.released_us = Some(released_us);
        }
    }

    pub fn on_decoded(&mut self, stream: u16, frame: u32, decoded_us: u64) {
        if let Some(row) = self.row(stream, frame, false) {
            row.viewer.decoded_us = Some(decoded_us);
        }
    }

    /// The frame reached the glass; its row after the note, when the ledger still has it.
    pub fn on_presented(&mut self, stream: u16, frame: u32, presented_us: u64) -> Option<FrameRow> {
        let row = self.row(stream, frame, false)?;
        row.viewer.presented_us = Some(presented_us);
        Some(*row)
    }

    /// The run's table. `offset_us`: the host clock's offset from the
    /// viewer's (`None`: unknown, so stages that cross the two clocks are not
    /// reported). `reasons`: why a stage this viewer cannot fill is empty
    /// (`("Present", "...")`), used when it has no samples.
    pub fn summary(&self, offset_us: Option<i64>, reasons: &[(&str, &str)]) -> Summary {
        let to_host =
            |v: Option<u64>| -> Option<i128> { Some(i128::from(v?) + i128::from(offset_us?)) };
        let host = |t: u64| (t != 0).then_some(i128::from(t));
        let mut samples: Vec<Vec<f64>> = vec![Vec::new(); STAGES.len()];
        let mut to_decoded = Vec::new();
        let span = |a: Option<i128>, b: Option<i128>| Some((b? - a?) as f64 / 1000.0);
        for row in &self.rows {
            let v = row.viewer;
            let h = row.host.unwrap_or_default();
            let display = host(h.display_us);
            let local = |t: Option<u64>| t.map(i128::from);
            let values = [
                None,
                None,
                span(display, host(h.encode_start_us)),
                span(host(h.encode_start_us), host(h.encoded_us)),
                span(host(h.encoded_us), host(h.last_sent_us)),
                span(host(h.last_sent_us), to_host(v.last_shard_us)),
                span(host(h.first_sent_us), to_host(v.first_shard_us)),
                span(local(v.first_shard_us), local(v.last_shard_us))
                    .zip(span(host(h.first_sent_us), host(h.last_sent_us)))
                    .map(|(arrival, send)| arrival - send),
                span(local(v.last_shard_us), local(v.released_us)),
                span(local(v.released_us), local(v.decoded_us)),
                span(local(v.decoded_us), local(v.presented_us)),
                span(display, to_host(v.presented_us)),
            ];
            for (bucket, value) in samples.iter_mut().zip(values) {
                if let Some(ms) = value {
                    bucket.push(ms);
                }
            }
            if let Some(ms) = span(display, to_host(v.decoded_us)) {
                to_decoded.push(ms);
            }
        }
        let crosses = |name: &str| matches!(name, "Network" | "Transport" | "Total");
        let stages = STAGES
            .iter()
            .zip(samples.iter_mut())
            .map(|(def, xs)| {
                let value = percentiles(xs);
                let reason = value.is_none().then(|| {
                    if matches!(def.name, "Input" | "Screen") {
                        HARNESS_ONLY.to_owned()
                    } else if let Some((_, why)) = reasons.iter().find(|(n, _)| *n == def.name) {
                        (*why).to_owned()
                    } else if crosses(def.name) && offset_us.is_none() {
                        "no clock offset yet (cap clock)".to_owned()
                    } else {
                        "no frame had both times".to_owned()
                    }
                });
                StageRow { def: *def, value, reason }
            })
            .collect();
        let first = self.rows.iter().filter_map(|r| r.viewer.first_shard_us).min();
        let last = self.rows.iter().filter_map(|r| r.viewer.last_shard_us).max();
        let bytes: u64 = self.rows.iter().map(|r| r.bytes).sum();
        let received_mbps = match (first, last) {
            (Some(a), Some(b)) if b > a => Some(bytes as f64 * 8.0 / (b - a) as f64),
            _ => None,
        };
        Summary {
            frames: self.rows.len(),
            frames_with_host_times: self.rows.iter().filter(|r| r.host.is_some()).count(),
            offset_us,
            received_mbps,
            stages,
            display_to_decoded: percentiles(&mut to_decoded),
        }
    }
}

/// Nearest-rank p50 and p95; `None` with no samples.
pub fn percentiles(xs: &mut [f64]) -> Option<Percentiles> {
    if xs.is_empty() {
        return None;
    }
    xs.sort_by(f64::total_cmp);
    let rank = |p: f64| {
        let i = ((p * xs.len() as f64).ceil() as usize).saturating_sub(1);
        xs.get(i).or(xs.last()).copied().unwrap_or(f64::NAN)
    };
    Some(Percentiles { n: xs.len(), p50_ms: rank(0.5), p95_ms: rank(0.95) })
}

fn num(x: f64) -> String {
    if x.is_finite() { format!("{x:.3}") } else { "null".to_owned() }
}

fn string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn pct_json(p: Option<Percentiles>) -> String {
    match p {
        Some(p) => {
            format!("{{\"n\":{},\"p50_ms\":{},\"p95_ms\":{}}}", p.n, num(p.p50_ms), num(p.p95_ms))
        }
        None => "null".to_owned(),
    }
}

impl Summary {
    /// The summary as one JSON object (schema [`SCHEMA`]).
    pub fn to_json(&self) -> String {
        let stages: Vec<String> = self
            .stages
            .iter()
            .map(|s| {
                let (n, p50, p95) = match s.value {
                    Some(p) => (p.n.to_string(), num(p.p50_ms), num(p.p95_ms)),
                    None => ("0".to_owned(), "null".to_owned(), "null".to_owned()),
                };
                format!(
                    "{{\"stage\":{},\"from\":{},\"to\":{},\"budget_ms\":{},\"n\":{n},\"p50_ms\":{p50},\"p95_ms\":{p95},\"reason\":{}}}",
                    string(s.def.name),
                    string(s.def.from),
                    string(s.def.to),
                    num(s.def.budget_ms),
                    s.reason.as_deref().map_or("null".to_owned(), string),
                )
            })
            .collect();
        format!(
            "{{\"schema\":{},\"clock\":\"host monotonic\",\"frames\":{},\"frames_with_host_times\":{},\"offset_us\":{},\"received_mbps\":{},\"stages\":[{}],\"display_to_decoded\":{}}}",
            string(SCHEMA),
            self.frames,
            self.frames_with_host_times,
            self.offset_us.map_or("null".to_owned(), |o| o.to_string()),
            self.received_mbps.map_or("null".to_owned(), num),
            stages.join(","),
            pct_json(self.display_to_decoded),
        )
    }
}
