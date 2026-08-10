use std::collections::BTreeMap;
#[cfg(target_os = "linux")]
use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use serde::Serialize;
use sha2::{Digest, Sha256};
use wait_timeout::ChildExt;

use super::{Evidence, Scenario, Target, TargetKind};

const METADATA_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Serialize)]
pub struct ComparisonReport {
    pub schema_version: u32,
    pub generated_at_unix_ms: u128,
    pub platform_label: String,
    pub warmups: usize,
    pub paired_samples: usize,
    pub order: &'static str,
    pub host: HostMetadata,
    pub baseline: TargetMetadata,
    pub candidate: TargetMetadata,
    pub scenarios: Vec<ScenarioReport>,
}

#[derive(Debug, Serialize)]
pub struct ProfileReport {
    pub schema_version: u32,
    pub generated_at_unix_ms: u128,
    pub platform_label: String,
    pub target: TargetKind,
    pub scenario: Scenario,
    pub duration_ns: u64,
    pub evidence: Evidence,
    pub host: HostMetadata,
    pub binary: TargetMetadata,
}

#[derive(Debug, Serialize)]
pub struct ScenarioReport {
    pub scenario: Scenario,
    pub event: &'static str,
    pub baseline: SampleSet,
    pub candidate: SampleSet,
    pub pairs: Vec<Pair>,
    pub paired_delta_summary_ns: SignedSummary,
}

#[derive(Debug, Serialize)]
pub struct SampleSet {
    pub ordered_ns: Vec<u64>,
    pub sorted_ns: Vec<u64>,
    pub summary_ns: Summary,
    pub evidence: Evidence,
}

impl SampleSet {
    pub fn new(ordered_ns: Vec<u64>, evidence: Evidence) -> Result<Self> {
        let mut sorted_ns = ordered_ns.clone();
        sorted_ns.sort_unstable();
        let summary_ns = Summary::from_sorted(&sorted_ns)?;
        Ok(Self { ordered_ns, sorted_ns, summary_ns, evidence })
    }
}

#[derive(Debug, Serialize)]
pub struct Pair {
    pub index: usize,
    pub first: TargetKind,
    pub baseline_ns: u64,
    pub candidate_ns: u64,
    pub candidate_minus_baseline_ns: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Summary {
    pub count: usize,
    pub min: u64,
    pub mean: f64,
    pub stddev_population: f64,
    pub mad: f64,
    pub p50: u64,
    pub p90: u64,
    pub p95: u64,
    pub p99: u64,
    pub max: u64,
}

impl Summary {
    fn from_sorted(values: &[u64]) -> Result<Self> {
        if values.is_empty() {
            bail!("cannot summarize an empty sample set");
        }
        let mean = values.iter().map(|value| *value as f64).sum::<f64>() / values.len() as f64;
        let variance = values
            .iter()
            .map(|value| {
                let delta = *value as f64 - mean;
                delta * delta
            })
            .sum::<f64>()
            / values.len() as f64;
        let values_f64 = values.iter().map(|value| *value as f64).collect::<Vec<_>>();
        let median = median_f64(&values_f64);
        let mut deviations =
            values.iter().map(|value| (*value as f64 - median).abs()).collect::<Vec<_>>();
        deviations.sort_by(f64::total_cmp);
        let mad = median_f64(&deviations);
        Ok(Self {
            count: values.len(),
            min: values[0],
            mean,
            stddev_population: variance.sqrt(),
            mad,
            p50: percentile(values, 50),
            p90: percentile(values, 90),
            p95: percentile(values, 95),
            p99: percentile(values, 99),
            max: values[values.len() - 1],
        })
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SignedSummary {
    pub count: usize,
    pub min: i64,
    pub mean: f64,
    pub stddev_population: f64,
    pub mad: f64,
    pub p50: i64,
    pub p90: i64,
    pub p95: i64,
    pub p99: i64,
    pub max: i64,
}

impl SignedSummary {
    pub fn new(values: &[i64]) -> Result<Self> {
        if values.is_empty() {
            bail!("cannot summarize empty paired deltas");
        }
        let mut sorted = values.to_vec();
        sorted.sort_unstable();
        let mean = sorted.iter().map(|value| *value as f64).sum::<f64>() / sorted.len() as f64;
        let variance = sorted
            .iter()
            .map(|value| {
                let delta = *value as f64 - mean;
                delta * delta
            })
            .sum::<f64>()
            / sorted.len() as f64;
        let sorted_f64 = sorted.iter().map(|value| *value as f64).collect::<Vec<_>>();
        let median = median_f64(&sorted_f64);
        let mut deviations =
            sorted.iter().map(|value| (*value as f64 - median).abs()).collect::<Vec<_>>();
        deviations.sort_by(f64::total_cmp);
        Ok(Self {
            count: sorted.len(),
            min: sorted[0],
            mean,
            stddev_population: variance.sqrt(),
            mad: median_f64(&deviations),
            p50: percentile_signed(&sorted, 50),
            p90: percentile_signed(&sorted, 90),
            p95: percentile_signed(&sorted, 95),
            p99: percentile_signed(&sorted, 99),
            max: sorted[sorted.len() - 1],
        })
    }
}

fn percentile(values: &[u64], percentile: usize) -> u64 {
    values[nearest_rank(values.len(), percentile)]
}

fn percentile_signed(values: &[i64], percentile: usize) -> i64 {
    values[nearest_rank(values.len(), percentile)]
}

fn nearest_rank(count: usize, percentile: usize) -> usize {
    (count * percentile).div_ceil(100).saturating_sub(1).min(count - 1)
}

fn median_f64(values: &[f64]) -> f64 {
    let midpoint = values.len() / 2;
    if values.len() % 2 == 0 {
        (values[midpoint - 1] + values[midpoint]) / 2.0
    } else {
        values[midpoint]
    }
}

#[derive(Debug, Serialize)]
pub struct TargetMetadata {
    pub kind: TargetKind,
    pub requested_sha: String,
    pub observed_sha: String,
    pub ghostty_sha: String,
    pub zig_version: String,
    pub rust_toolchain: String,
    pub source: String,
    pub binary: String,
    pub binary_sha256: String,
    pub binary_bytes: u64,
}

impl TargetMetadata {
    pub fn collect(target: &Target) -> Result<Self> {
        let bytes = fs::read(&target.binary)
            .with_context(|| format!("read {}", target.binary.display()))?;
        let binary_sha256 = format!("{:x}", Sha256::digest(&bytes));
        Ok(Self {
            kind: target.kind,
            requested_sha: target.sha.clone(),
            observed_sha: target.observed_sha.clone(),
            ghostty_sha: target.ghostty_sha.clone(),
            zig_version: target.zig_version.clone(),
            rust_toolchain: target.rust_toolchain.clone(),
            source: target.source.display().to_string(),
            binary: target.binary.display().to_string(),
            binary_sha256,
            binary_bytes: bytes.len() as u64,
        })
    }
}

#[derive(Debug, Serialize)]
pub struct HostMetadata {
    pub os: &'static str,
    pub arch: &'static str,
    pub family: &'static str,
    pub cpu: String,
    pub logical_processors: usize,
    pub physical_cores: Option<usize>,
    pub memory_bytes: Option<u64>,
    pub kernel: String,
    pub rustc: String,
    pub cargo: String,
    pub zig: String,
    pub ci: BTreeMap<String, String>,
}

impl HostMetadata {
    pub fn collect() -> Self {
        let logical_processors =
            std::thread::available_parallelism().map_or(1, std::num::NonZeroUsize::get);
        let (cpu, memory_bytes, kernel) = platform_metadata();
        let ci = [
            "CMUX_BENCHMARK_RUN_ID",
            "CMUX_BENCHMARK_RUN_ATTEMPT",
            "CMUX_BENCHMARK_RUNNER_NAME",
            "CMUX_BENCHMARK_RUNNER_OS",
            "CMUX_BENCHMARK_RUNNER_ARCH",
            "CMUX_BENCHMARK_IMAGE_OS",
            "CMUX_BENCHMARK_IMAGE_VERSION",
            "CMUX_BENCHMARK_WORKFLOW_REF",
        ]
        .into_iter()
        .filter_map(|key| env::var(key).ok().map(|value| (key.to_string(), value)))
        .collect();
        Self {
            os: env::consts::OS,
            arch: env::consts::ARCH,
            family: env::consts::FAMILY,
            cpu,
            logical_processors,
            physical_cores: physical_core_count(),
            memory_bytes,
            kernel,
            rustc: command_text("rustc", &["--version", "--verbose"]),
            cargo: command_text("cargo", &["--version", "--verbose"]),
            zig: command_text("zig", &["version"]),
            ci,
        }
    }
}

#[cfg(target_os = "macos")]
fn platform_metadata() -> (String, Option<u64>, String) {
    let mut cpu = command_text("sysctl", &["-n", "machdep.cpu.brand_string"]);
    if cpu == "unavailable" {
        cpu = command_text("sysctl", &["-n", "hw.model"]);
    }
    let memory = command_text("sysctl", &["-n", "hw.memsize"]).trim().parse().ok();
    (cpu, memory, command_text("uname", &["-a"]))
}

#[cfg(target_os = "linux")]
fn platform_metadata() -> (String, Option<u64>, String) {
    let cpu = fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| {
                    line.strip_prefix("model name").and_then(|line| line.split_once(':'))
                })
                .map(|(_, value)| value.trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());
    let memory = fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                line.strip_prefix("MemTotal:")?.split_whitespace().next()?.parse::<u64>().ok()
            })
        })
        .and_then(|kilobytes| kilobytes.checked_mul(1024));
    (cpu, memory, command_text("uname", &["-a"]))
}

#[cfg(target_os = "windows")]
fn platform_metadata() -> (String, Option<u64>, String) {
    let cpu = command_text(
        "powershell.exe",
        &[
            "-NoProfile",
            "-Command",
            "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)",
        ],
    );
    let memory = command_text(
        "powershell.exe",
        &["-NoProfile", "-Command", "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"],
    )
    .trim()
    .parse()
    .ok();
    let kernel = command_text(
        "powershell.exe",
        &["-NoProfile", "-Command", "[System.Environment]::OSVersion.VersionString"],
    );
    (cpu, memory, kernel)
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn platform_metadata() -> (String, Option<u64>, String) {
    ("unknown".to_string(), None, "unknown".to_string())
}

fn command_text(program: &str, args: &[&str]) -> String {
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let Ok(mut child) = command.spawn() else {
        return "unavailable".to_string();
    };
    let status = match child.wait_timeout(METADATA_COMMAND_TIMEOUT) {
        Ok(Some(status)) => status,
        Ok(None) | Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return "unavailable".to_string();
        }
    };
    if !status.success() {
        return "unavailable".to_string();
    }
    let mut output = Vec::new();
    child
        .stdout
        .take()
        .and_then(|mut stdout| stdout.read_to_end(&mut output).ok())
        .and_then(|_| String::from_utf8(output).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unavailable".to_string())
}

#[cfg(target_os = "macos")]
fn physical_core_count() -> Option<usize> {
    command_text("sysctl", &["-n", "hw.physicalcpu"]).trim().parse().ok()
}

#[cfg(target_os = "linux")]
fn physical_core_count() -> Option<usize> {
    let output = command_text("lscpu", &["-p=CORE,SOCKET"]);
    let cores = output
        .lines()
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| line.split_once(','))
        .map(|(core, socket)| (core.to_string(), socket.to_string()))
        .collect::<BTreeSet<_>>();
    (!cores.is_empty()).then_some(cores.len())
}

#[cfg(target_os = "windows")]
fn physical_core_count() -> Option<usize> {
    command_text(
        "powershell.exe",
        &[
            "-NoProfile",
            "-Command",
            "(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum",
        ],
    )
    .trim()
    .parse()
    .ok()
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn physical_core_count() -> Option<usize> {
    None
}

pub fn now_unix_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_uses_nearest_rank_percentiles_and_population_spread() {
        let summary = Summary::from_sorted(&[1, 2, 3, 4, 100]).unwrap();
        assert_eq!(summary.count, 5);
        assert_eq!(summary.p50, 3);
        assert_eq!(summary.p90, 100);
        assert_eq!(summary.p99, 100);
        assert_eq!(summary.min, 1);
        assert_eq!(summary.max, 100);
        assert!(summary.stddev_population > 38.0);
    }

    #[test]
    fn signed_summary_preserves_candidate_minus_baseline_direction() {
        let summary = SignedSummary::new(&[-10, -2, 3, 8]).unwrap();
        assert_eq!(summary.min, -10);
        assert_eq!(summary.p50, -2);
        assert_eq!(summary.max, 8);
    }

    #[test]
    fn even_sized_mad_uses_the_arithmetic_median_as_its_center() {
        let unsigned = Summary::from_sorted(&[0, 0, 1, 2, 2, 2]).unwrap();
        let signed = SignedSummary::new(&[-2, -2, -1, 0, 0, 0]).unwrap();

        assert_eq!(unsigned.mad, 0.5);
        assert_eq!(signed.mad, 0.5);
    }
}
