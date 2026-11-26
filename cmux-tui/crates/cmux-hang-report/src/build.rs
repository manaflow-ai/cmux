//! Builds the day's report from the watchdog's aggregate and MetricKit's deliveries: hangs
//! longest first, CPU exceptions heaviest first, histograms merged, signposts limited to the
//! known intervals, every envelope string reduced to a safe shape.

use std::collections::HashMap;

use serde::Deserialize;

use crate::aggregate::StallAggregate;
use crate::classify::{Classifier, LoadedImage};
use crate::report::{
    App, CoarseCounts, CpuExceptionSample, Frame, HangReport, HangSample, HardwareClass,
    HistogramBucket, IntervalHistogram, Kind, MAX_BODY_BYTES, MAX_CPU_EXCEPTIONS, MAX_FRAMES,
    MAX_HANGS, MAX_INTERVALS, Metrics, Os, Source,
};
use crate::tree;

pub const SIGNPOST_CATEGORIES: [&str; 7] =
    ["action", "motion", "key", "switch", "create", "cef", "launch"];
pub const CHANNELS: [&str; 4] = ["nightly", "dev", "rc", "release"];
pub const MEMORY_SIZES_GB: [i64; 14] = [4, 8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512];

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Context {
    pub report_id: String,
    pub install_id: String,
    pub day: String,
    pub app: App,
    pub os: Os,
    pub hardware: HardwareClass,
    pub counts: CoarseCounts,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetricKitHang {
    pub duration_ms: i64,
    /// MetricKit's `callStackTree.jsonRepresentation()`, as text.
    pub call_stack_tree: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetricKitCpuException {
    pub cpu_ms: i64,
    pub sampled_ms: i64,
    pub call_stack_tree: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Signpost {
    pub category: String,
    pub name: String,
    pub count: i64,
    #[serde(default)]
    pub buckets: Vec<HistogramBucket>,
    #[serde(default)]
    pub hitch_ms_per_s: Option<f64>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MetricKitInput {
    pub hangs: Vec<MetricKitHang>,
    pub cpu_exceptions: Vec<MetricKitCpuException>,
    pub metrics: Metrics,
    pub signposts: Vec<Signpost>,
}

impl MetricKitInput {
    pub fn is_empty(&self) -> bool {
        self.hangs.is_empty()
            && self.cpu_exceptions.is_empty()
            && self.metrics.is_empty()
            && self.signposts.is_empty()
    }
}

/// The classifier plus the loaded images the app found for the stacks' uuids.
pub struct Builder {
    pub classifier: Classifier,
    loaded: HashMap<String, LoadedImage>,
}

impl Builder {
    pub fn new(classifier: Classifier, loaded_images: Vec<LoadedImage>) -> Self {
        let mut loaded = HashMap::new();
        for image in loaded_images {
            let image = LoadedImage::new(&image.path, &image.uuid, image.base, image.size);
            loaded.entry(image.uuid.clone()).or_insert(image);
        }
        Self { classifier, loaded }
    }

    pub fn build(
        &self,
        context: &Context,
        watchdog: &StallAggregate,
        metric_kit: &[MetricKitInput],
    ) -> HangReport {
        let mut report = HangReport::new(
            context.report_id.clone(),
            context.install_id.clone(),
            safe_day(&context.day),
            safe_app(&context.app),
            Os { version: safe_version(&context.os.version) },
            context.hardware.clone(),
            context.counts.clone(),
        );
        let mut hangs: Vec<HangSample> = metric_kit
            .iter()
            .flat_map(|input| &input.hangs)
            .map(|hang| {
                HangSample::new(
                    Source::Metrickit,
                    Kind::Hang,
                    hang.duration_ms,
                    None,
                    self.frames(&hang.call_stack_tree),
                )
            })
            .chain(watchdog.hangs.iter().cloned())
            .chain(watchdog.stalls.iter().cloned())
            .collect();
        hangs.sort_by_key(|hang| std::cmp::Reverse(hang.duration_ms));
        hangs.truncate(MAX_HANGS);
        report.hangs = hangs;
        let mut cpu: Vec<&MetricKitCpuException> =
            metric_kit.iter().flat_map(|input| &input.cpu_exceptions).collect();
        cpu.sort_by_key(|cpu| std::cmp::Reverse(cpu.cpu_ms));
        report.cpu_exceptions = cpu
            .into_iter()
            .take(MAX_CPU_EXCEPTIONS)
            .map(|cpu| {
                CpuExceptionSample::new(
                    cpu.cpu_ms,
                    cpu.sampled_ms,
                    self.frames(&cpu.call_stack_tree),
                )
            })
            .collect();
        report.stall_histogram = watchdog.histogram();
        report.metrics = merged_metrics(metric_kit.iter().map(|input| &input.metrics));
        report.intervals = intervals(metric_kit.iter().flat_map(|input| &input.signposts));
        report
    }

    /// A MetricKit tree's frames, each judged by its loaded image when the app found one.
    pub fn frames(&self, call_stack_tree: &str) -> Vec<Frame> {
        tree::stack(call_stack_tree.as_bytes())
            .into_iter()
            .map(|raw| {
                let uuid = raw.binary_uuid.map(|uuid| uuid.to_uppercase());
                let loaded = uuid.as_ref().and_then(|uuid| self.loaded.get(uuid));
                self.classifier.frame_metric_kit(
                    raw.binary_name.as_deref(),
                    uuid.as_deref(),
                    raw.offset,
                    loaded,
                )
            })
            .collect()
    }
}

/// One watchdog return address and the image the app found it in.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Address {
    pub address: u64,
    #[serde(default)]
    pub image: Option<LoadedImage>,
}

/// A watchdog stack's frames (at most `MAX_FRAMES`).
pub fn address_frames(classifier: &Classifier, addresses: &[Address]) -> Vec<Frame> {
    addresses
        .iter()
        .take(MAX_FRAMES)
        .map(|entry| {
            let image = entry
                .image
                .as_ref()
                .map(|image| LoadedImage::new(&image.path, &image.uuid, image.base, image.size));
            classifier.frame_at(image.as_ref(), entry.address)
        })
        .collect()
}

pub fn merged_metrics<'a, I: Iterator<Item = &'a Metrics> + Clone>(all: I) -> Metrics {
    let gather = |pick: fn(&Metrics) -> &Vec<HistogramBucket>| -> Vec<HistogramBucket> {
        HistogramBucket::normalized(
            &all.clone().flat_map(|metrics| pick(metrics).iter().copied()).collect::<Vec<_>>(),
        )
    };
    Metrics {
        hang_time: gather(|metrics| &metrics.hang_time),
        hitch_ms_per_s: all
            .clone()
            .filter_map(|metrics| metrics.hitch_ms_per_s)
            .last()
            .and_then(safe_ratio),
        launch_extended: gather(|metrics| &metrics.launch_extended),
        launch_first_draw: gather(|metrics| &metrics.launch_first_draw),
        launch_optimized_first_draw: gather(|metrics| &metrics.launch_optimized_first_draw),
        launch_resume: gather(|metrics| &metrics.launch_resume),
        scroll_hitch_ms_per_s: all
            .clone()
            .filter_map(|metrics| metrics.scroll_hitch_ms_per_s)
            .last()
            .and_then(safe_ratio),
    }
}

/// The known intervals, merged by category and name in first-seen order.
pub fn intervals<'a, I: IntoIterator<Item = &'a Signpost>>(signposts: I) -> Vec<IntervalHistogram> {
    let mut merged: Vec<IntervalHistogram> = Vec::new();
    let mut index: HashMap<(String, String), usize> = HashMap::new();
    for signpost in signposts
        .into_iter()
        .filter(|signpost| signpost_allowed(&signpost.category, &signpost.name))
    {
        let key = (signpost.category.clone(), signpost.name.clone());
        if let Some(existing) = index.get(&key).and_then(|at| merged.get_mut(*at)) {
            existing.count = existing.count.saturating_add(signpost.count.max(0));
            let mut buckets = existing.buckets.clone();
            buckets.extend_from_slice(&signpost.buckets);
            existing.buckets = HistogramBucket::normalized(&buckets);
            if let Some(hitch) = signpost.hitch_ms_per_s.and_then(safe_ratio) {
                existing.hitch_ms_per_s = Some(hitch);
            }
        } else {
            index.insert(key, merged.len());
            merged.push(IntervalHistogram::new(
                signpost.category.clone(),
                signpost.name.clone(),
                signpost.count,
                &signpost.buckets,
                signpost.hitch_ms_per_s.and_then(safe_ratio),
            ));
        }
    }
    merged.truncate(MAX_INTERVALS);
    merged
}

/// A known category and a name of 1-48 of `a-z 0-9 _ . -`.
pub fn signpost_allowed(category: &str, name: &str) -> bool {
    SIGNPOST_CATEGORIES.contains(&category)
        && (1..=48).contains(&name.len())
        && name.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_.-".contains(&byte)
        })
}

pub fn safe_ratio(value: f64) -> Option<f64> {
    (value.is_finite() && (0.0..=1_000.0).contains(&value)).then_some(value)
}

fn digits(text: &str, min: usize, max: usize) -> bool {
    (min..=max).contains(&text.len()) && text.bytes().all(|byte| byte.is_ascii_digit())
}

/// `yyyy-MM-dd`, else the epoch's day.
pub fn safe_day(day: &str) -> String {
    let ok = matches!(
        day.split('-').collect::<Vec<&str>>().as_slice(),
        [year, month, date] if digits(year, 4, 4) && digits(month, 2, 2) && digits(date, 2, 2)
    );
    if ok { day.to_owned() } else { "1970-01-01".to_owned() }
}

/// One to four dot-separated groups of 1-6 digits, else `0`.
pub fn safe_version(version: &str) -> String {
    let parts: Vec<&str> = version.split('.').collect();
    let ok = parts.len() <= 4 && parts.iter().all(|part| digits(part, 1, 6));
    if ok { version.to_owned() } else { "0".to_owned() }
}

pub fn safe_build(build: &str) -> String {
    if digits(build, 1, 20) { build.to_owned() } else { safe_version(build) }
}

pub fn safe_app(app: &App) -> App {
    let channel = if CHANNELS.contains(&app.channel.as_str()) {
        app.channel.clone()
    } else {
        "dev".to_owned()
    };
    App { build: safe_build(&app.build), channel, version: safe_version(&app.version) }
}

/// The Mac's class from sysctl's raw strings: the chip family only, memory rounded to a size
/// Apple sells.
pub fn hardware(
    raw_arch: Option<&str>,
    raw_chip: Option<&str>,
    cores: i64,
    memory_bytes: u64,
) -> HardwareClass {
    let arch = raw_arch.map(trim_spaces).unwrap_or("");
    let arch = match arch {
        "arm64" | "arm64e" => "arm64",
        "x86_64" => "x86_64",
        _ => "other",
    };
    let gigabytes = memory_bytes as f64 / 1_073_741_824.0;
    let mut memory_gb = MEMORY_SIZES_GB[0];
    for size in MEMORY_SIZES_GB {
        if (size as f64 - gigabytes).abs() < (memory_gb as f64 - gigabytes).abs() {
            memory_gb = size;
        }
    }
    HardwareClass {
        arch: arch.to_owned(),
        chip: chip_family(raw_chip),
        cores: cores.clamp(1, 1_024),
        memory_gb,
    }
}

/// Foundation's `.whitespaces`: tab and the space separators, not line breaks.
fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|c: char| {
        c == '\t' || (c.is_whitespace() && !"\n\r\u{0B}\u{0C}\u{85}\u{2028}\u{2029}".contains(c))
    })
}

pub fn chip_family(raw: Option<&str>) -> String {
    let Some(raw) = raw.map(trim_spaces).filter(|raw| !raw.is_empty()) else {
        return "other".to_owned();
    };
    if is_apple_chip(raw) {
        return raw.to_owned();
    }
    if raw.to_lowercase().contains("intel") { "Intel".to_owned() } else { "other".to_owned() }
}

/// `Apple M<1-2 digits>`, optionally ` Pro`, ` Max` or ` Ultra`.
fn is_apple_chip(raw: &str) -> bool {
    let Some(rest) = raw.strip_prefix("Apple M") else { return false };
    let number_len = rest.bytes().take_while(u8::is_ascii_digit).count();
    if !(1..=2).contains(&number_len) {
        return false;
    }
    matches!(rest.get(number_len..), Some("" | " Pro" | " Max" | " Ultra"))
}

/// Drops the last hang, then CPU exception, then interval until the wire bytes fit.
pub fn fitted(mut report: HangReport) -> HangReport {
    while report.wire().len() > MAX_BODY_BYTES {
        if report.hangs.pop().is_none()
            && report.cpu_exceptions.pop().is_none()
            && report.intervals.pop().is_none()
        {
            break;
        }
    }
    report
}
