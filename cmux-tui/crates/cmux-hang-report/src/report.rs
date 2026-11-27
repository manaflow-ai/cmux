//! The report schema (version 2) and its wire bytes. Field order is the sorted key order the
//! server's fixture uses (web/tests/fixtures/hang-report-schema2.json): every struct declares its
//! fields sorted, absent optionals are left out, and a whole-number ratio is written as an integer.

use serde::{Deserialize, Serialize, Serializer};

pub const SCHEMA_VERSION: i64 = 2;
pub const MAX_HANGS: usize = 20;
pub const MAX_CPU_EXCEPTIONS: usize = 5;
pub const MAX_INTERVALS: usize = 64;
pub const MAX_BODY_BYTES: usize = 64 * 1024;
pub const MAX_FRAMES: usize = 64;
pub const OTHER_IMAGE: &str = "other";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct App {
    pub build: String,
    pub channel: String,
    pub version: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Os {
    pub version: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HardwareClass {
    pub arch: String,
    pub chip: String,
    pub cores: i64,
    #[serde(rename = "memoryGB")]
    pub memory_gb: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoarseCounts {
    pub panes: String,
    pub tabs: String,
    pub windows: String,
    pub workspaces: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Frame {
    pub image: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub offset: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uuid: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Metrickit,
    Watchdog,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Hang,
    Stall,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HangSample {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_ms: Option<i64>,
    pub duration_ms: i64,
    pub frames: Vec<Frame>,
    pub kind: Kind,
    pub source: Source,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CpuExceptionSample {
    pub cpu_ms: i64,
    pub frames: Vec<Frame>,
    pub sampled_ms: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistogramBucket {
    pub count: i64,
    pub high_ms: i64,
    pub low_ms: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IntervalHistogram {
    pub buckets: Vec<HistogramBucket>,
    pub category: String,
    pub count: i64,
    #[serde(skip_serializing_if = "Option::is_none", serialize_with = "ratio")]
    pub hitch_ms_per_s: Option<f64>,
    pub name: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub hang_time: Vec<HistogramBucket>,
    #[serde(skip_serializing_if = "Option::is_none", serialize_with = "ratio")]
    pub hitch_ms_per_s: Option<f64>,
    pub launch_extended: Vec<HistogramBucket>,
    pub launch_first_draw: Vec<HistogramBucket>,
    pub launch_optimized_first_draw: Vec<HistogramBucket>,
    pub launch_resume: Vec<HistogramBucket>,
    #[serde(skip_serializing_if = "Option::is_none", serialize_with = "ratio")]
    pub scroll_hitch_ms_per_s: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HangReport {
    pub app: App,
    pub counts: CoarseCounts,
    pub cpu_exceptions: Vec<CpuExceptionSample>,
    pub day: String,
    pub hangs: Vec<HangSample>,
    pub hardware: HardwareClass,
    pub install_id: String,
    pub intervals: Vec<IntervalHistogram>,
    pub metrics: Metrics,
    pub os: Os,
    pub report_id: String,
    pub schema: i64,
    pub stall_histogram: Vec<HistogramBucket>,
}

impl Frame {
    pub fn other() -> Self {
        Self { image: OTHER_IMAGE.to_owned(), offset: None, uuid: None }
    }

    pub fn is_other(&self) -> bool {
        self.image == OTHER_IMAGE
    }
}

impl HangSample {
    /// Durations clamp at zero and only the innermost `MAX_FRAMES` frames are kept.
    pub fn new(
        source: Source,
        kind: Kind,
        duration_ms: i64,
        cpu_ms: Option<i64>,
        mut frames: Vec<Frame>,
    ) -> Self {
        frames.truncate(MAX_FRAMES);
        Self {
            cpu_ms: cpu_ms.map(|ms| ms.max(0)),
            duration_ms: duration_ms.max(0),
            frames,
            kind,
            source,
        }
    }
}

impl CpuExceptionSample {
    pub fn new(cpu_ms: i64, sampled_ms: i64, mut frames: Vec<Frame>) -> Self {
        frames.truncate(MAX_FRAMES);
        Self { cpu_ms: cpu_ms.max(0), frames, sampled_ms: sampled_ms.max(0) }
    }
}

impl CoarseCounts {
    pub fn new(windows: i64, workspaces: i64, panes: i64, tabs: i64) -> Self {
        Self {
            panes: bucket(panes).to_owned(),
            tabs: bucket(tabs).to_owned(),
            windows: bucket(windows).to_owned(),
            workspaces: bucket(workspaces).to_owned(),
        }
    }

    pub fn unknown() -> Self {
        Self::new(0, 0, 0, 0)
    }
}

/// A count as the coarse label sent instead of the number.
pub fn bucket(count: i64) -> &'static str {
    match count {
        ..1 => "0",
        1 => "1",
        2..=5 => "2-5",
        6..=10 => "6-10",
        11..=30 => "11-30",
        31..=100 => "31-100",
        _ => "101+",
    }
}

pub const MAX_BUCKETS: usize = 32;
pub const MAX_MS: i64 = 86_400_000;

impl HistogramBucket {
    pub fn new(low_ms: i64, high_ms: i64, count: i64) -> Self {
        let low_ms = low_ms.clamp(0, MAX_MS);
        Self { count: count.max(0), high_ms: high_ms.max(low_ms).min(MAX_MS), low_ms }
    }

    /// Zero counts dropped, equal edges summed, sorted by edges, at most `MAX_BUCKETS`.
    pub fn normalized(buckets: &[HistogramBucket]) -> Vec<HistogramBucket> {
        let mut sums: std::collections::BTreeMap<(i64, i64), i64> =
            std::collections::BTreeMap::new();
        for bucket in buckets.iter().filter(|bucket| bucket.count > 0) {
            let sum = sums.entry((bucket.low_ms, bucket.high_ms)).or_default();
            *sum = sum.saturating_add(bucket.count);
        }
        sums.into_iter()
            .take(MAX_BUCKETS)
            .map(|((low, high), count)| HistogramBucket::new(low, high, count))
            .collect()
    }
}

impl IntervalHistogram {
    pub fn new(
        category: String,
        name: String,
        count: i64,
        buckets: &[HistogramBucket],
        hitch_ms_per_s: Option<f64>,
    ) -> Self {
        Self {
            buckets: HistogramBucket::normalized(buckets),
            category,
            count: count.max(0),
            hitch_ms_per_s,
            name,
        }
    }
}

impl Metrics {
    pub fn is_empty(&self) -> bool {
        self.hang_time.is_empty()
            && self.launch_first_draw.is_empty()
            && self.launch_resume.is_empty()
            && self.launch_optimized_first_draw.is_empty()
            && self.launch_extended.is_empty()
            && self.scroll_hitch_ms_per_s.is_none()
            && self.hitch_ms_per_s.is_none()
    }
}

impl HangReport {
    pub fn new(
        report_id: String,
        install_id: String,
        day: String,
        app: App,
        os: Os,
        hardware: HardwareClass,
        counts: CoarseCounts,
    ) -> Self {
        Self {
            app,
            counts,
            cpu_exceptions: Vec::new(),
            day,
            hangs: Vec::new(),
            hardware,
            install_id,
            intervals: Vec::new(),
            metrics: Metrics::default(),
            os,
            report_id,
            schema: SCHEMA_VERSION,
            stall_histogram: Vec::new(),
        }
    }

    pub fn has_no_findings(&self) -> bool {
        self.hangs.is_empty()
            && self.cpu_exceptions.is_empty()
            && self.stall_histogram.iter().all(|bucket| bucket.count == 0)
            && self.metrics.is_empty()
            && self.intervals.is_empty()
    }

    /// The wire bytes: compact, sorted keys, slashes unescaped.
    pub fn wire(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    /// The readable copy (View Hang Report): the wire bytes pretty-printed, `" : "` between key
    /// and value as Foundation writes them.
    pub fn readable(&self) -> Vec<u8> {
        let mut out = Vec::new();
        let mut serializer = serde_json::Serializer::with_formatter(&mut out, Readable::default());
        if self.serialize(&mut serializer).is_err() {
            return Vec::new();
        }
        out
    }
}

/// A ratio as Foundation's encoder writes a `Double`: a whole number without `.0`.
fn ratio<S: Serializer>(value: &Option<f64>, serializer: S) -> Result<S::Ok, S::Error> {
    match value {
        Some(number) if number.fract() == 0.0 && number.abs() < 1e15 => {
            serializer.serialize_i64(*number as i64)
        }
        Some(number) => serializer.serialize_f64(*number),
        None => serializer.serialize_none(),
    }
}

#[derive(Default)]
struct Readable<'a> {
    inner: serde_json::ser::PrettyFormatter<'a>,
}

impl serde_json::ser::Formatter for Readable<'_> {
    fn begin_array<W: ?Sized + std::io::Write>(&mut self, writer: &mut W) -> std::io::Result<()> {
        self.inner.begin_array(writer)
    }
    fn end_array<W: ?Sized + std::io::Write>(&mut self, writer: &mut W) -> std::io::Result<()> {
        self.inner.end_array(writer)
    }
    fn begin_array_value<W: ?Sized + std::io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> std::io::Result<()> {
        self.inner.begin_array_value(writer, first)
    }
    fn end_array_value<W: ?Sized + std::io::Write>(
        &mut self,
        writer: &mut W,
    ) -> std::io::Result<()> {
        self.inner.end_array_value(writer)
    }
    fn begin_object<W: ?Sized + std::io::Write>(&mut self, writer: &mut W) -> std::io::Result<()> {
        self.inner.begin_object(writer)
    }
    fn end_object<W: ?Sized + std::io::Write>(&mut self, writer: &mut W) -> std::io::Result<()> {
        self.inner.end_object(writer)
    }
    fn begin_object_key<W: ?Sized + std::io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> std::io::Result<()> {
        self.inner.begin_object_key(writer, first)
    }
    fn begin_object_value<W: ?Sized + std::io::Write>(
        &mut self,
        writer: &mut W,
    ) -> std::io::Result<()> {
        writer.write_all(b" : ")
    }
    fn end_object_value<W: ?Sized + std::io::Write>(
        &mut self,
        writer: &mut W,
    ) -> std::io::Result<()> {
        self.inner.end_object_value(writer)
    }
}
