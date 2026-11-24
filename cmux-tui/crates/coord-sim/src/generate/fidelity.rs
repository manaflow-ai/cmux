//! Does a generated home look like its shape? The same measures `coord_shape_probe.py` takes (kind
//! of a line: the first `"kind":"..."` in its first 512 bytes; sizes as log2 histograms; gaps and 50 ms
//! bursts per session; each session's busiest second), compared with the shape the run drew from.
//!
//! `probe` reads a generated `.acpmux` in-process (the test); `compare` takes either that or the
//! python probe's JSON (`coord-sim gen --check PROBE.json --out DIR`), with the run's `manifest.json`.

use super::plan::{Family, KindTable};
use crate::shape::{Hist, Shape};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::BufRead;
use std::path::Path;

/// What one generated coordinator was asked to be (the run's `manifest.json` lists them).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Planned {
    pub index: u32,
    pub id: String,
    pub name: String,
    pub harness: String,
    pub events: u64,
    pub peak_events_1s: u64,
    pub lines: u64,
    pub bytes: u64,
    pub segments: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub schema: String,
    pub seed: u64,
    pub scale: f64,
    pub coordinators: Vec<Planned>,
}

pub const MANIFEST_SCHEMA: &str = "coord-sim-gen.v1";

/// The bounds a generated home must stay inside.
pub struct Tolerance {
    /// Total variation distance of the kind mix.
    pub kind_tvd: f64,
    /// TVD of the log2 histogram of all line sizes.
    pub size_tvd: f64,
    /// TVD of each common kind's size histogram (kinds with at least 2% of the lines).
    pub kind_size_tvd: f64,
    pub gap_tvd: f64,
    pub burst_tvd: f64,
    /// Observed busiest second over the drawn peak, summed over coordinators.
    pub peak_ratio: (f64, f64),
    /// Mean line size over the shape's.
    pub mean_ratio: (f64, f64),
}

pub const TOLERANCE: Tolerance = Tolerance {
    kind_tvd: 0.05,
    size_tvd: 0.10,
    kind_size_tvd: 0.20,
    gap_tvd: 0.10,
    burst_tvd: 0.15,
    peak_ratio: (0.8, 1.6),
    mean_ratio: (0.7, 1.4),
};

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub lines: u64,
    pub bytes: u64,
    pub kind_tvd: f64,
    pub size_tvd: f64,
    pub worst_kind_size_tvd: f64,
    pub worst_kind: String,
    pub gap_tvd: f64,
    pub burst_tvd: f64,
    pub peak_ratio: f64,
    pub mean_ratio: f64,
    pub failures: Vec<String>,
}

#[derive(Default)]
struct Acc {
    b: BTreeMap<u32, u64>,
    n: u64,
    sum: u64,
    max: u64,
}

impl Acc {
    fn add(&mut self, v: u64) {
        let b = if v == 0 { 0 } else { 64 - v.leading_zeros() };
        *self.b.entry(b).or_default() += 1;
        self.n += 1;
        self.sum += v;
        self.max = self.max.max(v);
    }
    fn hist(&self) -> Hist {
        Hist {
            n: self.n,
            sum: self.sum,
            max: self.max,
            log2: self.b.iter().map(|(k, v)| (k.to_string(), *v)).collect(),
        }
    }
}

fn safe(kind: &str) -> &str {
    let mut chars = kind.chars();
    let ok = kind.len() <= 64
        && chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || "_./-".contains(c));
    if ok { kind } else { "other" }
}

fn field<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    let pat = format!("\"{name}\":\"");
    let start = head.find(&pat)? + pat.len();
    let rest = head.get(start..)?;
    rest.find('"').and_then(|e| rest.get(..e))
}

fn number(head: &str, name: &str) -> Option<u64> {
    let pat = format!("\"{name}\":");
    let start = head.find(&pat)? + pat.len();
    let rest = head.get(start..)?;
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest.get(..end)?.parse().ok()
}

/// Measures a generated `.acpmux` home the way the python probe does, into a shape.
pub fn probe(acpmux_home: &Path) -> Result<Shape, String> {
    let sessions = acpmux_home.join("sessions");
    let mut names: Vec<_> = std::fs::read_dir(&sessions)
        .map_err(|e| format!("{}: {e}", sessions.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .collect();
    names.sort();
    let (mut kinds, mut lines, mut gaps, mut bursts) =
        (BTreeMap::<String, Acc>::new(), Acc::default(), Acc::default(), Acc::default());
    let (mut events, mut peaks) = (Acc::default(), Acc::default());
    let mut buf = Vec::new();
    for dir in names {
        let mut segs: Vec<_> = match std::fs::read_dir(dir.join("events")) {
            Ok(rd) => rd.filter_map(|e| e.ok().map(|e| e.path())).collect(),
            Err(_) => continue,
        };
        segs.sort();
        let (mut ev, mut prev, mut run) = (0u64, None::<u64>, 0u64);
        let mut per_s = BTreeMap::<u64, u64>::new();
        for seg in segs {
            let f = std::fs::File::open(&seg).map_err(|e| format!("{}: {e}", seg.display()))?;
            let mut r = std::io::BufReader::with_capacity(1 << 20, f);
            loop {
                buf.clear();
                let n = r.read_until(b'\n', &mut buf).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                ev += 1;
                let len = n as u64;
                lines.add(len);
                let head = String::from_utf8_lossy(buf.get(..512.min(buf.len())).unwrap_or(&[]));
                let dir = field(&head, "dir").unwrap_or("?").to_owned();
                let kind = field(&head, "kind").map_or("none", safe).to_owned();
                kinds.entry(format!("{dir}:{kind}")).or_default().add(len);
                if let Some(t) = number(&head, "at") {
                    if let Some(p) = prev
                        && t >= p
                    {
                        let g = t - p;
                        gaps.add(g);
                        if g <= 50 {
                            run += 1;
                        } else if run > 0 {
                            bursts.add(run + 1);
                            run = 0;
                        }
                    }
                    prev = Some(t);
                    *per_s.entry(t / 1000).or_default() += 1;
                }
            }
        }
        if run > 0 {
            bursts.add(run + 1);
        }
        events.add(ev);
        peaks.add(per_s.values().copied().max().unwrap_or(0));
    }
    let mut shape = Shape { schema: "coord-shape.v1".into(), ..Shape::default() };
    let a = &mut shape.acpmux;
    a.kind_bytes = kinds.iter().map(|(k, v)| (k.clone(), v.hist())).collect();
    a.event_bytes = lines.hist();
    a.gap_ms = gaps.hist();
    a.burst_len_50ms = bursts.hist();
    a.per_session.events = events.hist();
    a.per_session.peak_events_1s = peaks.hist();
    a.sessions = events.n;
    Ok(shape)
}

fn tvd(a: &BTreeMap<String, f64>, b: &BTreeMap<String, f64>) -> f64 {
    let (sa, sb) = (a.values().sum::<f64>().max(1e-12), b.values().sum::<f64>().max(1e-12));
    let mut keys: Vec<&String> = a.keys().chain(b.keys()).collect();
    keys.sort();
    keys.dedup();
    keys.iter()
        .map(|k| (a.get(*k).unwrap_or(&0.0) / sa - b.get(*k).unwrap_or(&0.0) / sb).abs())
        .sum::<f64>()
        / 2.0
}

fn buckets(h: &Hist) -> BTreeMap<String, f64> {
    h.log2.iter().map(|(k, v)| (k.clone(), *v as f64)).collect()
}

/// The shape's histogram of kind `key` with every bucket below the line the template can write at
/// least cut away: a line is never smaller than its record, so the comparison is with what can be.
fn reachable(want: &Hist, got: &Hist) -> BTreeMap<String, f64> {
    let floor = got.log2.keys().filter_map(|k| k.parse::<u32>().ok()).min().unwrap_or(0);
    let mut out = BTreeMap::new();
    for (k, v) in &want.log2 {
        let b = k.parse::<u32>().unwrap_or(0).max(floor);
        *out.entry(b.to_string()).or_default() += *v as f64;
    }
    out
}

/// Compares a measured home (`got`) with the shape it was drawn from, for the coordinators in `m`.
pub fn compare(want: &Shape, got: &Shape, m: &Manifest) -> Result<Report, String> {
    let t = TOLERANCE;
    let ga = &got.acpmux;
    let wa = &want.acpmux;
    // The expected mix: each coordinator's family table, weighted by its events.
    let mut expect = BTreeMap::<String, f64>::new();
    for c in &m.coordinators {
        let fam =
            Family::parse(&c.harness).ok_or_else(|| format!("manifest: harness {}", c.harness))?;
        for (k, share) in KindTable::new(want, fam)?.shares() {
            *expect.entry(k).or_default() += share * c.events as f64;
        }
    }
    let observed: BTreeMap<String, f64> =
        ga.kind_bytes.iter().map(|(k, h)| (k.clone(), h.n as f64)).collect();
    let kind_tvd = tvd(&expect, &observed);
    let size_tvd = tvd(&buckets(&wa.event_bytes), &buckets(&ga.event_bytes));
    let total = ga.event_bytes.n.max(1) as f64;
    let (mut worst, mut worst_kind) = (0.0f64, String::new());
    for (k, h) in &ga.kind_bytes {
        if (h.n as f64) < 0.02 * total || h.n < 200 {
            continue;
        }
        let Some(w) = wa.kind_bytes.get(k) else { continue };
        let d = tvd(&reachable(w, h), &buckets(h));
        if d > worst {
            worst = d;
            worst_kind = k.clone();
        }
    }
    let gap_tvd = tvd(&buckets(&wa.gap_ms), &buckets(&ga.gap_ms));
    let burst_tvd = tvd(&buckets(&wa.burst_len_50ms), &buckets(&ga.burst_len_50ms));
    let planned_peak: u64 = m.coordinators.iter().map(|c| c.peak_events_1s).sum();
    let peak_ratio = ga.per_session.peak_events_1s.sum as f64 / planned_peak.max(1) as f64;
    let mean_ratio = ga.event_bytes.mean() / (wa.event_bytes.mean() * m.scale).max(1e-9);
    // Scaled sizes move every histogram by log2(scale) buckets: only an unscaled run is held to them.
    let unscaled = (m.scale - 1.0).abs() < 1e-9;
    let mut failures = Vec::new();
    let mut check = |name: &str, v: f64, ok: bool| {
        if !ok {
            failures.push(format!("{name} {v:.4}"));
        }
    };
    check("kind_tvd", kind_tvd, kind_tvd <= t.kind_tvd);
    check("size_tvd", size_tvd, !unscaled || size_tvd <= t.size_tvd);
    check("kind_size_tvd", worst, !unscaled || worst <= t.kind_size_tvd);
    check("gap_tvd", gap_tvd, gap_tvd <= t.gap_tvd);
    check("burst_tvd", burst_tvd, burst_tvd <= t.burst_tvd);
    check("peak_ratio", peak_ratio, (t.peak_ratio.0..=t.peak_ratio.1).contains(&peak_ratio));
    check("mean_ratio", mean_ratio, (t.mean_ratio.0..=t.mean_ratio.1).contains(&mean_ratio));
    Ok(Report {
        lines: ga.event_bytes.n,
        bytes: ga.event_bytes.sum,
        kind_tvd,
        size_tvd,
        worst_kind_size_tvd: worst,
        worst_kind,
        gap_tvd,
        burst_tvd,
        peak_ratio,
        mean_ratio,
        failures,
    })
}
