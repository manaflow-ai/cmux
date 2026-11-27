//! The disk bar of a Cloud machine (RFD 0068 "What to build next" 3): used over
//! allocated, "13.2 / 20 GB", as a bar of system, project and caches with the
//! free rest. Sans-I/O: the guest's report in, the view out. The machine card
//! (the Cloud page, through the Cloud app server's relay) draws [`DiskView`] as it is; `cmux cloud machine-status`
//! and `cmux cloud list-machines` print its [`DiskView::label`].
//!
//! A guest too old to report its use has only its allocation: the view is
//! [`DiskState::Allocated`] with no segments, and the label is the allocation
//! alone ("20 GB"), as the card and the CLI showed before.
//!
//! Units: bytes in, GB out, where a GB is 1024³ bytes (the unit the machine
//! sizes and `formatMegabytes` already show as "GB"), rounded to one place,
//! with a trailing ".0" dropped ("20 GB", "13.2 GB").

use serde::{Deserialize, Serialize};

const GIB: u64 = 1024 * 1024 * 1024;
const MIB: u64 = 1024 * 1024;

/// Under this much free, or under [`ALMOST_FULL_FREE_SHARE`] of the disk free when that is more,
/// the disk is almost full: the budget cmux Cloud grows the disk at (cmux-platform `DISK_GROW`,
/// RFD 0068 "What to build next" 2) and the guest evicts caches at (acpmux `disk_evict.rs`).
pub const ALMOST_FULL_FREE_BYTES: u64 = 4 * GIB;

/// The share of the disk under which free space is almost full, on a disk where it is more than
/// [`ALMOST_FULL_FREE_BYTES`] (a disk over 26.7 GiB).
pub const ALMOST_FULL_FREE_SHARE: f64 = 0.15;

/// The free bytes under which a disk of `total` bytes is almost full.
pub fn almost_full_under(total: u64) -> u64 {
    ALMOST_FULL_FREE_BYTES.max((total as f64 * ALMOST_FULL_FREE_SHARE) as u64)
}

/// One chat's share of the disk: `~/chats/<id>` and the worktrees inside it (acpmux's disk walk).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatDisk {
    pub id: String,
    pub bytes: u64,
}

/// What the guest cleared the last time its disk ran low: re-creatable caches and idle build
/// output, never a user's files. The event a machine card can show.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiskEviction {
    /// When, milliseconds since the epoch.
    pub at: u64,
    #[serde(alias = "freedBytes")]
    pub freed_bytes: u64,
    pub paths: Vec<String>,
}

/// The bar's width in parts; the segments' `width` sum to it.
pub const BAR_PARTS: u32 = 1000;

/// The fewest parts a segment with any bytes is drawn with, so a small cache
/// still shows as a sliver (1%).
pub const MIN_SEGMENT_PARTS: u32 = 10;

/// What the guest reports about its root disk, every field optional: an older
/// guest reports none of them, one between reports totals but no split.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiskReport {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub free_bytes: Option<u64>,
    /// Everything used outside the project and the caches: the OS, the tools
    /// in the image, logs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_bytes: Option<u64>,
    /// The checkouts and their build output.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_bytes: Option<u64>,
    /// Package and compiler caches: safe to wipe.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caches_bytes: Option<u64>,
}

impl DiskReport {
    /// A report from MiB values (the Cloud records' `*_mb` unit).
    pub fn from_mib(total: Option<f64>, used: Option<f64>, free: Option<f64>) -> Self {
        Self {
            total_bytes: mib(total),
            used_bytes: mib(used),
            free_bytes: mib(free),
            ..Self::default()
        }
    }

    /// The same report with its system, project and caches split, in MiB.
    pub fn with_split_mib(
        self,
        system: Option<f64>,
        project: Option<f64>,
        caches: Option<f64>,
    ) -> Self {
        Self {
            system_bytes: mib(system),
            project_bytes: mib(project),
            caches_bytes: mib(caches),
            ..self
        }
    }
}

impl DiskReport {
    /// A machine record's `disk_health` (cmux-platform's last guest sample, `publicMachine`) as a
    /// report: each field in bytes (the guest's own `rootTotalBytes` and `diskSplit.systemBytes`
    /// from acpmux `machine load` first, then `total_bytes`), else in MiB (`total_mb`, the relay's
    /// unit). None when the value is not an object or names none of the six.
    pub fn from_health(value: &serde_json::Value) -> Option<Self> {
        use serde_json::{Map, Value};
        let object = value.as_object()?;
        let bytes = |object: &Map<String, Value>, snake: &str, camel: &str| {
            object.get(camel).or_else(|| object.get(snake)).and_then(Value::as_u64)
        };
        let field = |name: &str| {
            let mut chars = name.chars();
            let first = chars.next()?;
            let camel = format!("root{}{}Bytes", first.to_uppercase(), chars.as_str());
            bytes(object, &format!("root_{name}_bytes"), &camel)
                .or_else(|| object.get(&format!("{name}_bytes")).and_then(Value::as_u64))
                .or_else(|| mib(object.get(&format!("{name}_mb")).and_then(Value::as_f64)))
        };
        let split =
            object.get("diskSplit").or_else(|| object.get("disk_split")).and_then(Value::as_object);
        let part = |name: &str| {
            split
                .and_then(|split| bytes(split, &format!("{name}_bytes"), &format!("{name}Bytes")))
                .or_else(|| field(name))
        };
        let report = Self {
            total_bytes: field("total"),
            used_bytes: field("used"),
            free_bytes: field("free"),
            system_bytes: part("system"),
            project_bytes: part("project"),
            caches_bytes: part("caches"),
        };
        (report != Self::default()).then_some(report)
    }
}

/// The chats in a `disk_health` (the guest's `diskSplit.chats`), largest first; empty when the
/// guest does not report them.
pub fn chats_from_health(value: &serde_json::Value) -> Vec<ChatDisk> {
    let split = value.get("diskSplit").or_else(|| value.get("disk_split"));
    let mut chats: Vec<ChatDisk> = split
        .and_then(|s| s.get("chats"))
        .and_then(|c| serde_json::from_value(c.clone()).ok())
        .unwrap_or_default();
    chats.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.id.cmp(&b.id)));
    chats
}

/// The guest's last eviction in a `disk_health` (`diskSplit.evicted`), if it reports one.
pub fn eviction_from_health(value: &serde_json::Value) -> Option<DiskEviction> {
    let split = value.get("diskSplit").or_else(|| value.get("disk_split"))?;
    let e = split.get("evicted")?;
    Some(DiskEviction {
        at: e.get("at")?.as_u64()?,
        freed_bytes: e.get("freedBytes").or_else(|| e.get("freed_bytes"))?.as_u64()?,
        paths: e
            .get("paths")
            .and_then(|p| serde_json::from_value(p.clone()).ok())
            .unwrap_or_default(),
    })
}

/// MiB as bytes; none for a value that is not a finite, non-negative number.
pub fn mib(value: Option<f64>) -> Option<u64> {
    value.filter(|v| v.is_finite() && *v >= 0.0).map(|v| (v * MIB as f64).round() as u64)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiskState {
    /// No use reported: the allocation alone.
    Allocated,
    /// Use reported, at least [`almost_full_under`] free.
    Ok,
    /// Under [`almost_full_under`] free: cmux Cloud is growing the disk.
    AlmostFull,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SegmentKind {
    System,
    Project,
    Caches,
    /// Used, with no split reported: the one coloured segment.
    Used,
    Free,
}

/// One part of the bar, left to right: system, project, caches (or used), free.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    pub kind: SegmentKind,
    pub bytes: u64,
    /// GB to one place.
    pub gb: f64,
    /// Its width in [`BAR_PARTS`]; the bar's widths sum to [`BAR_PARTS`].
    pub width: u32,
}

/// The disk bar as the card and the CLI draw it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiskView {
    pub state: DiskState,
    /// The disk's size in GB to one place.
    pub total_gb: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_gb: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub free_gb: Option<f64>,
    /// Empty when no use is reported.
    pub segments: Vec<Segment>,
    /// "13.2 / 20 GB", or "20 GB" with no use reported.
    pub label: String,
    /// "13.2 of 20 GB, 6.8 free", or "20 GB" with no use reported.
    pub text: String,
}

/// The view of a disk of `allocated_bytes` (the machine's size) and the
/// guest's `report`. The report's total wins over the allocation: a grown disk
/// shows its new size before the record catches up. None when neither says
/// how big the disk is.
pub fn view(allocated_bytes: Option<u64>, report: &DiskReport) -> Option<DiskView> {
    let total = report.total_bytes.filter(|t| *t > 0).or(allocated_bytes.filter(|t| *t > 0))?;
    let total_gb = gb(total);
    let used =
        report.used_bytes.or_else(|| report.free_bytes.map(|free| total.saturating_sub(free)));
    let Some(used) = used else {
        return Some(allocated_only(total_gb));
    };
    let used = used.min(total);
    // The guest's free is what a write can use (it leaves out the reserved
    // blocks); without it, the rest of the disk.
    let free = report.free_bytes.map_or(total - used, |free| free.min(total - used));
    let state = if free < almost_full_under(total) { DiskState::AlmostFull } else { DiskState::Ok };
    let segments = segments(total, used, report);
    let (used_gb, free_gb) = (gb(used), gb(free));
    Some(DiskView {
        state,
        total_gb,
        used_gb: Some(used_gb),
        free_gb: Some(free_gb),
        segments,
        label: format!("{} / {} GB", number(used_gb), number(total_gb)),
        text: format!("{} of {} GB, {} free", number(used_gb), number(total_gb), number(free_gb)),
    })
}

fn allocated_only(total_gb: f64) -> DiskView {
    let label = format!("{} GB", number(total_gb));
    DiskView {
        state: DiskState::Allocated,
        total_gb,
        used_gb: None,
        free_gb: None,
        segments: Vec::new(),
        text: label.clone(),
        label,
    }
}

/// System, project and caches when the guest split its use, else one used
/// segment; then the free rest. Used bytes the split leaves out count as
/// system (everything outside the project and the caches is), and a split that
/// adds up past the used total is scaled down to it.
fn segments(total: u64, used: u64, report: &DiskReport) -> Vec<Segment> {
    let mut parts: Vec<(SegmentKind, u64)> = match (report.project_bytes, report.caches_bytes) {
        (None, None) => vec![(SegmentKind::Used, used)],
        (project, caches) => {
            let (project, caches) = (project.unwrap_or(0), caches.unwrap_or(0));
            let named = project + caches + report.system_bytes.unwrap_or(0);
            let scale = |b: u64| {
                if named > used { (b as u128 * used as u128 / named as u128) as u64 } else { b }
            };
            let (project, caches) = (scale(project), scale(caches));
            let system = used.saturating_sub(project).saturating_sub(caches);
            vec![
                (SegmentKind::System, system),
                (SegmentKind::Project, project),
                (SegmentKind::Caches, caches),
            ]
        }
    };
    parts.push((SegmentKind::Free, total - used));
    let widths = widths(total, &parts.iter().map(|(_, b)| *b).collect::<Vec<_>>());
    parts
        .into_iter()
        .zip(widths)
        .map(|((kind, bytes), width)| Segment { kind, bytes, gb: gb(bytes), width })
        .collect()
}

/// Each part's share of [`BAR_PARTS`] by largest remainder, every part with
/// bytes at least [`MIN_SEGMENT_PARTS`] (taken from the widest), summing to
/// [`BAR_PARTS`] exactly.
fn widths(total: u64, bytes: &[u64]) -> Vec<u32> {
    let exact: Vec<u128> = bytes.iter().map(|b| *b as u128 * BAR_PARTS as u128).collect();
    let mut widths: Vec<u32> = exact.iter().map(|e| (e / total as u128) as u32).collect();
    let mut short = BAR_PARTS - widths.iter().sum::<u32>();
    let mut order: Vec<usize> = (0..bytes.len()).collect();
    order.sort_by_key(|i| {
        std::cmp::Reverse(exact.get(*i).copied().unwrap_or_default() % total as u128)
    });
    for i in order.into_iter().cycle().take(short as usize) {
        if let Some(width) = widths.get_mut(i) {
            *width += 1;
        }
        short -= 1;
    }
    debug_assert_eq!(short, 0);
    for i in 0..bytes.len() {
        let Some(byte_count) = bytes.get(i).copied() else { continue };
        while byte_count > 0 && widths.get(i).copied().unwrap_or_default() < MIN_SEGMENT_PARTS {
            let Some(widest) = (0..bytes.len())
                .filter(|j| *j != i)
                .max_by_key(|j| widths.get(*j).copied().unwrap_or_default())
            else {
                break;
            };
            if widths.get(widest).copied().unwrap_or_default() <= MIN_SEGMENT_PARTS {
                break;
            }
            let Some(widest_width) = widths.get_mut(widest) else { break };
            *widest_width -= 1;
            let Some(width) = widths.get_mut(i) else { break };
            *width += 1;
        }
    }
    widths
}

/// Bytes as GB to one place.
pub fn gb(bytes: u64) -> f64 {
    (bytes as f64 / GIB as f64 * 10.0).round() / 10.0
}

/// GB as the label writes it: one place, without a trailing ".0" (20, 13.2, 0.4).
pub fn number(gb: f64) -> String {
    if gb.fract() == 0.0 { format!("{gb:.0}") } else { format!("{gb:.1}") }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
